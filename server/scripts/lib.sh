# shellcheck shell=bash
# Shared helpers for backup.sh, restore.sh and install-backup-schedule.sh. Sourced, not run.

# launchd and non-interactive ssh start with a bare PATH that has no Homebrew or Docker.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SERVER_DIR

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
die() {
  log "error: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found (brew install $2)"
}

# compose <dev|prod> <args…>: the same project, env file and overrides as the Makefile.
compose() {
  local env="$1"
  shift
  case "$env" in
    dev | prod) ;;
    *) die "unknown stack: $env (dev or prod)" ;;
  esac
  [[ -f "$SERVER_DIR/.env.$env" ]] || die "missing $SERVER_DIR/.env.$env"
  docker compose -p "pilgrim-$env" --env-file "$SERVER_DIR/.env.$env" \
    -f "$SERVER_DIR/docker-compose.yml" -f "$SERVER_DIR/docker-compose.$env.yml" "$@"
}

# Loads restic settings (RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE or RESTIC_PASSWORD_COMMAND, and
# AWS_* for an s3: repository) from BACKUP_ENV_FILE, outside the repo so the backup secrets never
# reach .env.prod or the containers. Template: scripts/backup.env.example.
load_backup_env() {
  BACKUP_ENV_FILE="${BACKUP_ENV_FILE:-$HOME/.config/pilgrim-backup/env}"
  [[ -f "$BACKUP_ENV_FILE" ]] ||
    die "missing $BACKUP_ENV_FILE (copy scripts/backup.env.example there, chmod 600)"
  local mode
  mode="$(stat -f '%Lp' "$BACKUP_ENV_FILE" 2>/dev/null || stat -c '%a' "$BACKUP_ENV_FILE")"
  [[ "$mode" == 600 || "$mode" == 400 ]] || die "$BACKUP_ENV_FILE must be chmod 600 (is $mode)"
  set -a
  # shellcheck source=/dev/null
  . "$BACKUP_ENV_FILE"
  set +a
  : "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY in $BACKUP_ENV_FILE}"
  if [[ "$RESTIC_REPOSITORY" == s3:* ]]; then
    : "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID in $BACKUP_ENV_FILE}"
    : "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY in $BACKUP_ENV_FILE}"
    # R2 speaks S3 but has a single region.
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
  fi
  if [[ -z "${RESTIC_PASSWORD_FILE:-}" && -z "${RESTIC_PASSWORD_COMMAND:-}" ]]; then
    die "set RESTIC_PASSWORD_FILE or RESTIC_PASSWORD_COMMAND in $BACKUP_ENV_FILE"
  fi
  if [[ -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
    RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE/#\~/$HOME}"
    export RESTIC_PASSWORD_FILE
    [[ -s "$RESTIC_PASSWORD_FILE" ]] || die "restic password file $RESTIC_PASSWORD_FILE is missing or empty"
  fi
  # Snapshots are grouped by this host name, so retention never touches another machine's.
  BACKUP_HOST_TAG="${BACKUP_HOST_TAG:-pilgrim-prod}"
}
