#!/bin/bash
# Daily backup of the pilgrim-prod stack: pg_dump + the photo volume → restic → Cloudflare R2,
# then retention (7 days) and prune. Runs on the Mac mini, by hand (`make backup`) or daily at
# 04:00 from launchd (`make backup-schedule`). docs/group-server.md "백업 사본 위치".
#
#   scripts/backup.sh           back up now
#   scripts/backup.sh --init    create the restic repository (no-op when it exists)
#   scripts/backup.sh --list    list snapshots
#
# Environment: BACKUP_DIR (local dumps and staging, default ~/backups/pilgrim), BACKUP_ENV_FILE
# (restic/R2 settings, default ~/.config/pilgrim-backup/env), KEEP_LOCAL (local dumps, default 7).
# restic encrypts before upload; the repository password must also be kept outside the Mac mini.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/pilgrim}"
KEEP_LOCAL="${KEEP_LOCAL:-7}"
RETENTION="${RETENTION:-7d}"
TAG=pilgrim

need restic restic
need docker 'Docker Desktop'
load_backup_env

repo_exists() { restic cat config >/dev/null 2>&1; }

case "${1:-}" in
  --init)
    if repo_exists; then
      log "restic repository already exists at $RESTIC_REPOSITORY"
    else
      restic init
    fi
    exit 0
    ;;
  --list)
    restic snapshots --tag "$TAG"
    exit 0
    ;;
  "") ;;
  *) die "usage: $0 [--init|--list]" ;;
esac

mkdir -p "$BACKUP_DIR/db" "$BACKUP_DIR/staging"
chmod 700 "$BACKUP_DIR"

# One run at a time (launchd catching up after sleep + a manual run). The trap comes first so a
# refused run still pings <url>/fail; it only cleans up a lock this run owns.
LOCK="$BACKUP_DIR/.lock"
own_lock=0
finish() {
  local status=$?
  if ((own_lock)); then
    rm -rf "$LOCK" "$BACKUP_DIR/staging/media.new"
    rm -f "$BACKUP_DIR/db/"*.tmp
  fi
  # Optional dead-man switch (healthchecks.io style): <url> on success, <url>/fail on failure.
  if [[ -n "${BACKUP_HEALTHCHECK_URL:-}" ]]; then
    local url="$BACKUP_HEALTHCHECK_URL"
    ((status == 0)) || url="$url/fail"
    curl -fsS -m 10 --retry 3 "$url" >/dev/null || log "warning: health check ping failed"
  fi
  ((status == 0)) || log "backup FAILED (exit $status)"
}
trap finish EXIT

take_lock() { mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid"; }
# A run killed without its trap (power cut, a macOS update restart) leaves the lock behind.
if ! take_lock; then
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  # Between another run's mkdir and its pid write.
  [[ -n "$holder" ]] || { sleep 1 && holder="$(cat "$LOCK/pid" 2>/dev/null || true)"; }
  # A pid reused after a reboot (even by this run) is not that backup, so check the command too.
  if [[ -n "$holder" && "$holder" != "$$" ]] &&
    [[ "$(ps -p "$holder" -o command= 2>/dev/null || true)" == *backup.sh* ]]; then
    die "another backup is running (pid $holder)"
  fi
  log "taking over stale lock $LOCK (pid ${holder:-unknown} is not a running backup)"
  rm -rf "$LOCK"
  take_lock || die "could not take $LOCK"
fi
own_lock=1

# Keeps the launchd log from growing forever.
if [[ -f "$BACKUP_DIR/backup.log" ]] && (($(wc -c <"$BACKUP_DIR/backup.log") > 5000000)); then
  mv "$BACKUP_DIR/backup.log" "$BACKUP_DIR/backup.log.1"
fi

repo_exists || die "no restic repository at $RESTIC_REPOSITORY (run make backup-init)"
compose prod ps --status running --services | grep -qx postgres || die "pilgrim-prod postgres is not running"

# 1. Database: custom-format dump (compressed, restorable with pg_restore).
stamp="$(date +%Y%m%d-%H%M%S)"
dump="$BACKUP_DIR/db/pilgrim-$stamp.dump"
log "dumping database"
compose prod exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner' >"$dump.tmp"
[[ -s "$dump.tmp" ]] || die "pg_dump wrote nothing"
mv "$dump.tmp" "$dump"
chmod 600 "$dump"
ln -f "$dump" "$BACKUP_DIR/staging/pilgrim.dump"

# 2. Photos: copy the media volume out through a one-off container of the server image (works
# while api is stopped too; Docker Desktop volumes are not visible on the host filesystem).
log "copying photo volume"
rm -rf "$BACKUP_DIR/staging/media.new"
mkdir -p "$BACKUP_DIR/staging/media.new"
compose prod run --rm --no-deps -T --entrypoint tar api -C /data/media -cf - . |
  tar -C "$BACKUP_DIR/staging/media.new" -xf -
rm -rf "$BACKUP_DIR/staging/media"
mv "$BACKUP_DIR/staging/media.new" "$BACKUP_DIR/staging/media"

# 3. Upload. Both go into one snapshot so a restore gets a matching database and photo set.
log "uploading to $RESTIC_REPOSITORY"
cd "$BACKUP_DIR/staging"
restic backup --host "$BACKUP_HOST_TAG" --tag "$TAG" pilgrim.dump media

# 4. Retention: nothing older than 7 days stays in R2 (privacy policy: "최대 7일").
log "applying retention ($RETENTION)"
restic forget --host "$BACKUP_HOST_TAG" --tag "$TAG" --keep-within "$RETENTION" --prune

# Weekly (Sundays) structure check of the repository.
if [[ "$(date +%u)" == 7 ]]; then
  log "checking repository"
  restic check
fi

# 5. Local dumps: newest KEEP_LOCAL.
find "$BACKUP_DIR/db" -name 'pilgrim-*.dump' -type f | sort -r | tail -n +$((KEEP_LOCAL + 1)) |
  while IFS= read -r old; do rm -f "$old"; done

log "backup done: $(du -h "$dump" | cut -f1) dump, $(du -sh "$BACKUP_DIR/staging/media" | cut -f1) photos"
