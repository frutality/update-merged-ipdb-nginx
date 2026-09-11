#!/usr/bin/env bash
# Запускается только в GitHub Actions (или вручную для отладки).
# Собирает suspicious_ranges.conf из Merged-IP.mmdb.
set -euo pipefail

URL="https://github.com/NetworkCats/Merged-IP-Data/releases/latest/download/Merged-IP.mmdb"
WORKDIR="$(mktemp -d)"
MMDB="$WORKDIR/Merged-IP.mmdb"
CSV="$WORKDIR/merged-ip-export.csv"
OUT="${1:-suspicious_ranges.conf}"

log() { echo "[build] $1" >&2; }
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

log "downloading $URL"
curl -fsSL --retry 3 --retry-delay 5 -o "$MMDB" "$URL"

SIZE=$(stat -c%s "$MMDB")
if [ "$SIZE" -lt $((50*1024*1024)) ] || [ "$SIZE" -gt $((200*1024*1024)) ]; then
    log "suspicious file size ($SIZE bytes), aborting"
    exit 1
fi

if ! command -v mmdblookup >/dev/null 2>&1; then
    log "mmdblookup not found"
    exit 1
fi
if ! mmdblookup --file "$MMDB" --ip 8.8.8.8 country iso_code >/dev/null 2>&1; then
    log "smoke-test lookup failed, mmdb looks corrupt"
    exit 1
fi

if ! command -v mmdbctl >/dev/null 2>&1; then
    log "mmdbctl not found"
    exit 1
fi
log "exporting to csv"
mmdbctl export "$MMDB" "$CSV" --format csv

log "filtering into $OUT"
python3 - "$CSV" "$OUT" <<'PYEOF'
import csv, sys, json

src, dst = sys.argv[1], sys.argv[2]

# Схема mmdbctl export: сеть - в "range", флаги - вложенным JSON в "proxy"
# (sparse: в JSON присутствуют только true-флаги, false-ключи просто отсутствуют)
NET_COL = "range"
JSON_COL = "proxy"
FLAG_KEYS = {"is_proxy", "is_vpn", "is_hosting", "is_tor", "is_anonymous"}
# is_cdn / is_school сознательно НЕ включены - это не источники подозрительного трафика

MIN_EXPECTED = 100_000    # по опыту ~500 тыс IPv4-сетей после фильтрации, меньше на порядок = баг
MAX_EXPECTED = 5_000_000  # на порядок больше = тоже баг (например, схема снова поменялась)

with open(src, newline='') as f, open(dst, 'w') as out:
    r = csv.DictReader(f)
    missing = [c for c in [NET_COL, JSON_COL] if c not in r.fieldnames]
    if missing:
        sys.exit(f"Колонки не найдены: {missing}. Реальные колонки в CSV: {r.fieldnames}")
    n = 0
    bad_json = 0
    skipped_v6 = 0
    for row in r:
        net = row[NET_COL]
        if ':' in net:  # IPv6 CIDR (IPv4 записи содержат только точки)
            skipped_v6 += 1
            continue
        raw = row.get(JSON_COL, "")
        if not raw:
            continue
        try:
            flags = json.loads(raw)
        except json.JSONDecodeError:
            bad_json += 1
            continue
        if any(flags.get(k) for k in FLAG_KEYS):
            out.write(f"{net} 1;\n")
            n += 1

    if bad_json:
        print(f"warning: {bad_json} строк с невалидным JSON пропущено", file=sys.stderr)
    print(f"skipped {skipped_v6} IPv6 ranges", file=sys.stderr)

    if n < MIN_EXPECTED or n > MAX_EXPECTED:
        sys.exit(f"n={n} вне ожидаемого диапазона [{MIN_EXPECTED}, {MAX_EXPECTED}] - похоже на баг")
    print(f"written {n} suspicious networks", file=sys.stderr)
PYEOF

log "done: $(wc -l < "$OUT") lines in $OUT"
