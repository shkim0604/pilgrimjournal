#!/bin/bash
# Restores a backup made by backup.sh (database + photos) into the dev or prod stack.
#
#   scripts/restore.sh --into dev [--snapshot ID] [--yes] [--start-worker]
#   scripts/restore.sh --into prod --confirm pilgrim-prod [--snapshot ID]
#   scripts/restore.sh --into dev --dump FILE [--media DIR]     (local files, no restic)
#
# --into dev   the local stack on the dev Mac (monthly restore drill, docs/group-server.md).
#              The worker is left stopped unless --start-worker: a restored push outbox or Apple
#              token revocation queue must not reach real users from a development machine.
# --into prod  the Mac mini stack. Replaces the live database and photos; needs
#              --confirm pilgrim-prod.
# --snapshot   restic snapshot ID (default: latest of host BACKUP_HOST_TAG, tag pilgrim).
#
# Steps: fetch the snapshot into a temporary folder, stop api and worker, drop and recreate the
# database, pg_restore, replace the media volume's contents, start api (and worker), which apply
# any newer migrations. The temporary folder holds personal data and is deleted at exit.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

into="" snapshot="latest" confirm="" assume_yes=0 start_worker=0 dump="" media=""
while (($#)); do
  case "$1" in
    --into) into="${2:?}"; shift 2 ;;
    --snapshot) snapshot="${2:?}"; shift 2 ;;
    --confirm) confirm="${2:?}"; shift 2 ;;
    --dump) dump="${2:?}"; shift 2 ;;
    --media) media="${2:?}"; shift 2 ;;
    --yes) assume_yes=1; shift ;;
    --start-worker) start_worker=1; shift ;;
    -h | --help) usage 0 ;;
    *) log "unknown option: $1" >&2; usage 2 ;;
  esac
done

case "$into" in
  dev) ;;
  prod)
    [[ "$confirm" == pilgrim-prod ]] ||
      die "restoring into prod replaces the live data; pass --confirm pilgrim-prod"
    start_worker=1
    ;;
  *) usage 2 ;;
esac
need docker 'Docker Desktop'

work="$(mktemp -d "${TMPDIR:-/tmp}/pilgrim-restore.XXXXXX")"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

if [[ -n "$dump" ]]; then
  [[ -s "$dump" ]] || die "dump file $dump is missing or empty"
  [[ -z "$media" || -d "$media" ]] || die "media folder $media does not exist"
else
  need restic restic
  load_backup_env
  log "fetching snapshot $snapshot"
  # The host/tag filters pick what `latest` means; an explicit ID must match them too.
  restic restore "$snapshot" --host "$BACKUP_HOST_TAG" --tag pilgrim --target "$work/snapshot"
  dump="$(find "$work/snapshot" -type f -name pilgrim.dump | head -n 1)"
  [[ -n "$dump" ]] || die "snapshot $snapshot has no pilgrim.dump"
  media="$(dirname "$dump")/media"
  [[ -d "$media" ]] || media=""
fi

log "restoring into pilgrim-$into: database from $dump, photos from ${media:-<none, left as is>}"
if ((!assume_yes)) && [[ "$into" == dev ]]; then
  read -r -p "This replaces the pilgrim-dev database${media:+ and photos}. Continue? [y/N] " answer
  [[ "$answer" == [yY]* ]] || die "cancelled"
fi

# api/worker off while the data underneath them changes.
compose "$into" stop api worker
compose "$into" up -d --wait postgres

log "recreating database"
compose "$into" exec -T postgres sh -c '
  set -e
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
    -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE)" \
    -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\""'
log "pg_restore"
compose "$into" exec -T postgres sh -c \
  'pg_restore --exit-on-error --no-owner -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <"$dump"

if [[ -n "$media" ]]; then
  log "replacing photo volume"
  # Runs as root to own the files for the server user; restic restores them as the host user.
  tar -C "$media" -cf - . |
    compose "$into" run --rm --no-deps -T --user root --entrypoint sh api -c '
      set -e
      find /data/media -mindepth 1 -delete
      tar -C /data/media -xf -
      chown -R pilgrim:pilgrim /data/media'
fi

log "starting api (migrations first)"
compose "$into" run --rm --no-deps migrate
compose "$into" up -d --no-deps api
if ((start_worker)); then
  compose "$into" up -d --no-deps worker
else
  log "worker left stopped (start it with: make dev, or --start-worker)"
fi
log "restore done; check http://127.0.0.1:3100/api/health"
