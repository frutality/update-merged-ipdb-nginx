# update-merged-ipdb

Автоматическая сборка списка "подозрительных" IPv4-сетей (proxy/VPN/hosting/Tor/anonymous)
для жёсткого общего rate-limit на чувствительных эндпоинтах nginx (например, password reset).

Появилось после разбора атаки на один из маршрутов бэкенда веб-приложения — 72 000 уникальных IP, ~50% из
известных proxy-сетей, ~28% hosting/datacenter. Per-IP rate limit не работает при такой
диверсификации источников — нужен отдельный, куда более жёсткий общий лимит именно для
подозрительных адресов, при этом не трогающий обычных пользователей (включая тех, кто сидит
под VPN сам по себе).

## Как это работает

```
┌──────────────────────┐   раз в сутки, 02:00 UTC
│  GitHub Actions      │   (build.yml, cron + workflow_dispatch)
│                      │
│  build.sh:           │
│  1. скачать          │──── https://github.com/NetworkCats/Merged-IP-Data
│     Merged-IP.mmdb   │      (94 МБ, сам обновляется ежедневно в 01:00 UTC)
│  2. валидировать     │      (размер файла + smoke-test через mmdblookup)
│  3. mmdbctl export   │──── mmdb → CSV (range, asn, city, country, ..., proxy)
│  4. python-фильтр    │      IPv4-only, is_proxy/is_vpn/is_hosting/is_tor/is_anonymous
│  5. sha256sum        │
└──────────┬───────────┘
           │ публикация в Release (тег latest-build, обновляется, не плодится)
           ▼
  releases/download/latest-build/suspicious_ranges.conf
  releases/download/latest-build/suspicious_ranges.conf.sha256
           │
           │ раз в сутки, 03:00 UTC (со сдвигом от сборки)
           ▼
┌──────────────────────┐
│  nginx edge #1, #2   │   fetch-latest.sh (независимо на каждом сервере):
│  (два независимых    │   1. curl conf + sha256
│   сервера, разные IP)│   2. проверка checksum
│                      │   3. sanity-check формата/объёма файла
│                      │   4. атомарная замена + backup предыдущей версии
│                      │   5. nginx -t → reload, при ошибке - автооткат
└──────────────────────┘
```

Продовые nginx-серверы **не знают про mmdb/mmdbctl вообще** — вся тяжёлая сборка изолирована
в CI, на проде только `curl` и `nginx`.

## Файлы

| Файл | Где выполняется | Что делает |
|---|---|---|
| `build.sh` | GitHub Actions | Скачивает mmdb, валидирует, экспортирует, фильтрует в CIDR-список под nginx `geo` |
| `.github/workflows/build.yml` | GitHub Actions | Расписание + установка зависимостей (mmdb-bin, mmdbctl) + публикация Release |
| `fetch-latest.sh` | nginx edge-серверы (крон) | Скачивает готовый файл из Release, проверяет, безопасно подменяет, reload |

## Формат итогового файла

`suspicious_ranges.conf` — готовый `include` для nginx `geo`-директивы:
```
1.0.0.0/24 1;
1.0.4.0/22 1;
...
```
Только IPv4 (IPv6 сознательно исключён), только сети с хотя бы одним из флагов
`is_proxy` / `is_vpn` / `is_hosting` / `is_tor` / `is_anonymous`. `is_cdn` и `is_school`
намеренно не учитываются — не источники подозрительного трафика для наших целей.
Ожидаемый объём — порядка 400-550 тысяч строк (см. sanity-bounds в `build.sh`).

Подключение в nginx:
```nginx
# http
geo $suspicious_ip {
    default 0;
    include /etc/nginx/suspicious_ranges.conf;
}

# http
map $suspicious_ip $susp_key {
    0 "";
    1 "susp_ip";
}

# http
limit_req_zone $susp_key zone=suspicious_shared:1m rate=5r/s;

# server
limit_req zone=suspicious_shared burst=5 nodelay;
```

## Первичная настройка

1. Запустить workflow вручную (`workflow_dispatch` во вкладке Actions) и убедиться, что
   релиз `latest-build` создался с обоими файлами.
2. Внести правки конфига `nginx`, описанные выше
3. Прогнать `fetch-latest.sh` руками на каждом edge-сервере, проверить `nginx -t` и лог
   (`journalctl -t fetch-merged-ipdb`).
4. Добавить в крон на обоих edge-серверах (от root):
   ```cron
   13 3 * * * /bin/bash /home/web/fetch-latest-ipdb.sh
   ```

## Эксплуатация / диагностика

- Логи сборки — вкладка Actions в GitHub (или `gh run list` / `gh run view`).
- Логи на edge — `journalctl -t fetch-merged-ipdb` (дублируется в stderr при ручном запуске).
- Ручной повторный запуск сборки: вкладка Actions → Run workflow, либо `gh workflow run build.yml`.
- Проверить, что nginx реально видит новый список:
  ```bash
  wc -l /etc/nginx/suspicious_ranges.conf
  ```

## Что делать, если сломалось

- **`fetch-latest.sh` падает на checksum/sanity-check** — значит сборка в CI выдала что-то
  подозрительное (или сеть повредила файл при скачивании). Edge-сервер в этом случае
  **не трогает прод** — продолжает работать со старым файлом. Смотреть логи сборки в Actions.
- **`nginx -t` падает после подмены файла** — `fetch-latest.sh` автоматически откатывается
  на `/etc/nginx/suspicious_ranges.conf.prev` и делает reload с ним. Если бэкапа не было
  (первый запуск) — требуется ручное вмешательство, скрипт явно об этом пишет в лог.
- **`build.sh` падает на "Колонки не найдены"** — апстрим (`mmdbctl` или сам
  `Merged-IP-Data`) поменял схему CSV. Смотреть реальные колонки в тексте ошибки, поправить
  `NET_COL`/`JSON_COL` в `build.sh`.

## Замер RAM и latency перед боевым включением

Используется core-модуль `geo` (не `geoip2`) — весь список парсится **синхронно при
`nginx -t`/reload** в память конфиг-пула мастер-процесса, а не лениво по mmap. Отсюда два
специфичных для `geo` момента, которые стоит замерить перед тем, как полагаться на это в проде:

1. **Стоимость парсинга при reload**:
   ```bash
   time nginx -t
   time nginx -s reload
   ```
   `fetch-latest.sh` дёргает reload раз в сутки — если цифра большая, это ежедневная пауза
   мастер-процесса, о которой нужно знать заранее.

2. **RAM через `Pss`**:
   ```bash
   for pid in $(pgrep -f 'nginx: worker'); do
       grep -E '^(Rss|Pss):' /proc/$pid/smaps_rollup
   done
   ```

3. **Latency** — A/B сравнение двух почти идентичных `location`, один с обращением к
   `$suspicious_ip` (или тестовой копии geo-блока на `$http_x_test_ip`, чтобы варьировать
   источник без реальных разных IP), другой без:
   ```bash
   wrk -t4 -c100 -d30s --latency http://localhost/bench/without-geo
   wrk -t4 -c100 -d30s --latency http://localhost/bench/with-geo -H "X-Test-IP: 1.0.0.0"
   ```

Результаты замера:
- `nginx -t` / `nginx -s reload`: 0.25s → 0.47s
- ΔPss (baseline → после reload → после 10 мин трафика): 72mb → 50mb → 55mb
- Δlatency p50/p99 (without-geo vs with-geo): p50 (72.15ms → 71.98ms), p99 (100.24ms → 85.13ms)

## Известные ограничения / что не сделано

- Нет автоочистки старых версий backup/prev-файлов на edge.
