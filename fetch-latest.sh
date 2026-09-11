#!/usr/bin/env bash
# Запускается на nginx edge-серверах (крон). Единственная зависимость - curl + nginx.
set -euo pipefail

REPO="frutality/update-merged-ipdb"
BASE_URL="https://github.com/$REPO/releases/download/latest-build"
DEST="/etc/nginx/suspicious_ranges.conf"
TMP="${DEST}.new"
SHA_TMP="${TMP}.sha256"
LOG_TAG="fetch-merged-ipdb"

log() {
    logger -t "$LOG_TAG" "$1" 2>/dev/null || true
    echo "[$LOG_TAG] $1" >&2
}

if ! curl -fsSL --retry 3 --retry-delay 5 -o "$TMP" "$BASE_URL/suspicious_ranges.conf"; then
    log "download of conf failed, keeping current file"
    exit 1
fi

if ! curl -fsSL --retry 3 --retry-delay 5 -o "$SHA_TMP" "$BASE_URL/suspicious_ranges.conf.sha256"; then
    log "download of checksum failed, keeping current file"
    rm -f "$TMP"
    exit 1
fi

EXPECTED=$(awk '{print $1}' "$SHA_TMP")
ACTUAL=$(sha256sum "$TMP" | awk '{print $1}')
if [ "$EXPECTED" != "$ACTUAL" ]; then
    log "checksum mismatch (expected=$EXPECTED actual=$ACTUAL), aborting"
    rm -f "$TMP" "$SHA_TMP"
    exit 1
fi

# Sanity-check по форме и объёму файла - если апстрим/пайплайн сломался, не применяем мусор
LINES=$(wc -l < "$TMP")
if [ "$LINES" -lt 100000 ] || [ "$LINES" -gt 5000000 ]; then
    log "suspicious line count ($LINES), aborting"
    rm -f "$TMP" "$SHA_TMP"
    exit 1
fi

if ! head -5 "$TMP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+ 1;$'; then
    log "file doesn't look like expected geo format, aborting"
    rm -f "$TMP" "$SHA_TMP"
    exit 1
fi

BACKUP="${DEST}.prev"
[ -f "$DEST" ] && cp -f "$DEST" "$BACKUP"

mv -f "$TMP" "$DEST"
rm -f "$SHA_TMP"

if ! nginx -t; then
    log "nginx -t failed after swap - rolling back to previous known-good file"
    if [ -f "$BACKUP" ]; then
        mv -f "$BACKUP" "$DEST"
        nginx -t && nginx -s reload
        log "rollback complete, still serving previous suspicious_ranges.conf"
    else
        log "no backup available to roll back to - manual intervention needed!"
    fi
    exit 1
fi
nginx -s reload
log "updated successfully: $LINES lines"
