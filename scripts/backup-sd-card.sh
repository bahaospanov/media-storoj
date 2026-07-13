#!/usr/bin/env bash
# Bulk-import photos/videos from a camera SD card into Immich.
#
# Usage:
#   scripts/backup-sd-card.sh                       # auto-detect card by label
#   scripts/backup-sd-card.sh /path/to/card          # explicit path
#   scripts/backup-sd-card.sh /path/to/card --include-extensions .ARW,.jpg
#                                                     # extra args pass straight
#                                                     # through to immich-go, so
#                                                     # you can override/extend
#                                                     # the defaults below without
#                                                     # editing this file
#
# Config (env vars, all optional):
#   IMMICH_SERVER    default: http://localhost:2283
#   SD_CARD_LABEL    default: Sony   -- used to auto-detect the mount point
#                    (/run/media/$USER/$SD_CARD_LABEL) when no path is given.
#                    Set this to your own card's label, e.g.:
#                      SD_CARD_LABEL=Canon5D scripts/backup-sd-card.sh
#   CONCURRENT_TASKS default: 4      -- see docs/server-tuning.md for why this
#                    is lower than immich-go's own default of 8 (memory
#                    pressure on small/shared servers)
#
# Requires ~/.local/bin/immich-go and API_key set in .env (repo root,
# gitignored; generate one in Immich: profile icon -> Account Settings ->
# API Keys).
#
# Default behavior skips RAW (.ARW) files and Sony's internal video-thumbnail
# junk (THMBNL/) -- a Sony-specific default that happens to match this
# project's own camera. See docs/immich-concepts.md for why (and the
# --exclude-extensions bug that --ban-file works around instead). For a
# different camera/brand or to keep RAW files, pass your own --ban-file /
# --include-extensions as extra args -- they're appended after (and so
# override) the ones below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=/dev/null
source "$REPO_ROOT/.env"

IMMICH_SERVER="${IMMICH_SERVER:-http://localhost:2283}"
SD_CARD_LABEL="${SD_CARD_LABEL:-Sony}"
CONCURRENT_TASKS="${CONCURRENT_TASKS:-4}"
DEFAULT_MOUNT="/run/media/$USER/$SD_CARD_LABEL"

if [ $# -ge 1 ] && [ -d "$1" ]; then
  SOURCE_DIR="$1"
  shift
else
  SOURCE_DIR="$DEFAULT_MOUNT"
  if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: no path given and '$SOURCE_DIR' doesn't exist." >&2
    echo "Currently mounted removable media:" >&2
    ls "/run/media/$USER/" 2>/dev/null >&2 || echo "  (none found)" >&2
    echo "Pass the card path explicitly, or set SD_CARD_LABEL to match." >&2
    exit 1
  fi
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$REPO_ROOT/sd-card-upload-$TIMESTAMP.log"

~/.local/bin/immich-go upload from-folder \
  --server "$IMMICH_SERVER" \
  --api-key "$API_key" \
  --no-ui \
  --ban-file '*.ARW' \
  --ban-file 'THMBNL/' \
  --on-errors continue \
  --concurrent-tasks "$CONCURRENT_TASKS" \
  --log-file "$LOG_FILE" \
  "$SOURCE_DIR" \
  "$@"
