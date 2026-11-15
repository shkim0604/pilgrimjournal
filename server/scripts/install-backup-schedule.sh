#!/bin/bash
# Installs (or reinstalls) the daily 04:00 backup LaunchAgent from com.dhouse.pilgrim.backup.plist.
# Idempotent: an existing job is unloaded first. `--uninstall` removes it.
# Run on the Mac mini from the deploy folder (`make backup-schedule` / `make backup-unschedule`).
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

LABEL=com.dhouse.pilgrim.backup
TEMPLATE="$SERVER_DIR/scripts/$LABEL.plist"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/pilgrim}"
BACKUP_ENV_FILE="${BACKUP_ENV_FILE:-$HOME/.config/pilgrim-backup/env}"

unload() { launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; }

if [[ "${1:-}" == --uninstall ]]; then
  unload
  rm -f "$TARGET"
  log "removed $LABEL"
  exit 0
fi

[[ -f "$BACKUP_ENV_FILE" ]] ||
  die "missing $BACKUP_ENV_FILE (copy scripts/backup.env.example there and fill it in first)"
mkdir -p "$BACKUP_DIR" "$(dirname "$TARGET")"
chmod 700 "$BACKUP_DIR"

escape() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
tmp="$(mktemp "$TARGET.XXXXXX")"
sed -e "s|__SERVER_DIR__|$(escape "$SERVER_DIR")|g" \
  -e "s|__BACKUP_DIR__|$(escape "$BACKUP_DIR")|g" \
  -e "s|__BACKUP_ENV_FILE__|$(escape "$BACKUP_ENV_FILE")|g" \
  "$TEMPLATE" >"$tmp"
plutil -lint -s "$tmp" || die "generated plist is invalid"
mv "$tmp" "$TARGET"

unload
launchctl bootstrap "$DOMAIN" "$TARGET"
log "daily backup at 04:00 → $BACKUP_DIR (log: $BACKUP_DIR/backup.log)"
log "run once now with: launchctl kickstart $DOMAIN/$LABEL"
