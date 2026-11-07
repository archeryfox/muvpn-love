# 2026-10-29_1335_opencode-muvpn-love.md

**Агент:** opencode (big-pickle)
**Проект:** `anbernics/muvpn_love` (LÖVE-пилот UI muVPN) + `anbernics/tgmuos/muvpn`
**Статус:** working
**Последнее обновление:** 2026-10-29 13:40 MSK

## Контекст и порядок работ

Пользователь задал порядок: **сначала LÖVE-пилот UI muVPN, затем standalone
`muvpn` + рабочий TUN (сначала пересборка sing-box, Xray — запасной вариант)**.
Пилот живёт вне git, в `anbernics/muvpn_love/`; C-приложение в
`tgmuos/muvpn/` пока не менялось.

Устройство: Anbernic RG35XX SP, muOS, aarch64, adb
`bc001080a5104871f12` (IP динамический). Экран 640×480, две страницы
framebuffer. LÖVE 11.5 ставится PortMaster-рантаймом:
`/mnt/mmc/MUOS/PortMaster/runtimes/love_11.5/love.aarch64`.
Приложение: `/mnt/mmc/MUOS/application/muvpn_love/`.
Приватный конфиг: `/root/.config/muvpn_love/` (700/600).

## Сделано

### LÖVE-пилот

- `conf.lua` — 640×480, fullscreen, identity `muvpn_love`.
- `main.lua` — экран muVPN: статус-пилюля (подключено/отключено/работа/ошибка),
  список узлов из `servers.tsv` (пинг, имя, маркер выбора), строка
  «Автоматически (urltest)», скролл, русские подписи как в C-scaffold.
- Ввод: D-pad/стрелки — курсор, A/Enter — сохранить выбор, X — подключить/
  отключить, **R1 (rightshoulder) / R** — обновить подписку, B/START/Esc — выход.
  Пользователь отдельно уточнил: обновление на геймпаде — **R1, не Y**.
- `service_worker.lua` — `love.thread`, вызывает
  `python3 tools/muvpn.py status|start|stop|refresh|select <id>` с приватными
  путями через env (`MUVPN_CONFIG_DIR`, `TGMUOS_*`, `TGMUOS_SINGBOX_MODE=tun`).
  UI не блокируется.
- Пилот использует **свою копию** `subscription.conf` (600) в
  `/root/.config/muvpn_love/`, поэтому `select` не трогает общий
  `/root/.config/tgmuos/subscription.conf`.
- `MUVPN_LOVE_MOCK=1` **или** маркер `/tmp/muvpn_love_mock` — демо-режим
  (4 узла, переходы connected/disconnected) без движка. Маркер нужен потому,
  что muOS frontend может перезапустить приложение со своим окружением.
- `mux_launch.sh` (LÖVE-рантайм, экспорт путей), `gameinfo.xml`, шрифт
  AdwaitaSans, копии `tools/muvpn.py` и `tools/import_vless_subscription.py`.
- `flock` в launcher: второй экземпляр не запускается (`/tmp/muvpn_love.lock`).

### Логирование

- `log.lua` — общий append-логгер в `debug.log` рядом с приложением,
  ротация при >256 KiB в `debug.log.1`.
- Пишутся: старт (пути, mock, число узлов, выбранный id), ввод, начало и
  результат действий, код возврата и вывод сервиса, смены состояний,
  ошибки воркера/необработанные ошибки, старт/выход launcher’а.
- `debug.log` не содержит URL подписки, UUID, ключей и содержимого узлов.
- Штатный `log.txt` остаётся для stderr LÖVE/launcher’а; раньше он был пуст,
  потому что LÖVE ничего не печатал.

### Проверено на устройстве

- `python3 tools/muvpn.py status` → `disconnected`, rc=0.
- `python3 tools/muvpn.py start` → `muVPN: bundled sing-box engine is missing`,
  rc=1 — ожидаемый путь ошибки: `libexec/sing-box` в пилоте нет.
- `select <id>` обновил только приватную копию; md5 общего
  `tgmuos/subscription.conf` **не изменился**. Права копии — 600.
- В `debug.log` зафиксированы реальные события с устройства: `mock=true`,
  13 узлов из `servers.tsv`, `gamepad: rightshoulder` → `action begin:
  refresh` → `result: kind=refresh ok=true`, `gamepad: x` →
  `action begin: start/stop` → `result: kind=action ok=true`.
- Пиксельная проверка кадров: `fb_shot.py` (page 0/1) + подсчёт цветов PIL;
  в mock-режиме подтверждены список из 6 видимых строк, статус-пилюля и
  красное состояние ошибки в реальном режиме.
- Ввод: uinput-хелпер `/tmp/hello_key.py` расширен (стрелки, X, R, B, Enter);
  устройства `/dev/input` и `/dev/uinput` доступны.

## Ошибки и фиксы

1. **Пустой `log.txt`** — LÖVE не писал stderr; добавлен `debug.log` и
   структурное логирование в main + worker.
2. **Два экземпляра love.aarch64** (ручной запуск + frontend) — добавлен
   `flock`-guard в `mux_launch.sh`; старые экземпляры нужно убивать
   точечно (`pkill -x love.aarch64`).
3. **Mock-переменная теряется** при перезапуске приложения muOS frontend’ом —
   добавлен файловый маркер `/tmp/muvpn_love_mock` как fallback.
4. **`select` писал в общий `tgmuos/subscription.conf`** — в пилоте вызовы
   идут только с приватной копией; проверено, что общий файл не меняется.
   В Step 2 это нужно исправить в самом `tgmuos/muvpn/tools/muvpn.py`.
5. **Tooling-ловушка:** `pkill -f mux_launch.sh` убивает собственный shell,
   потому что шаблон есть в его командной строке. Использовать
   `pkill -x love.aarch64` или `pkill -f '[m]ux_launch.sh'`.
6. **R1 вместо Y** — обновление подписки на геймпаде перенесено на
   `rightshoulder`; клавиатурный `R` оставлен.

## Текущее состояние устройства

- Telegram/TGMUOS и sing-box сейчас **не запущены** (последняя проверка:
  13:33 MSK).
- `muvpn_love` остановлен; маркер `/tmp/muvpn_love_mock` присутствует.
- `debug.log` на устройстве содержит историю mock-сессии и реального
  error-path.
- Секреты не выводились: проверялись только коды возврата, счётчики и
  md5-сравнение файлов.

## Блокеры

- **Движок:** в пилоте нет `libexec/sing-box`; установленный в
  `tgmuos/application/Telegram/libexec/sing-box` падает с SIGSEGV даже на
  `version` (ADR 0007). Поэтому `start` в реальном режиме ожидаемо
  возвращает «engine is missing».
- **TUN не проверялся:** маршруты, DNS, сохранение SSH при `auto_route` —
  только в Step 2.
- **Frontend-владелец:** muOS frontend запускает приложение сам, окружение
  ручного запуска при этом может не сохраняться; для тестов использовать
  маркер и один экземпляр.

## Следующие шаги

1. Визуально подтвердить connected-состояние (акцентная пилюля) и выбор узла
   на устройстве после остановки Telegram; сверить `debug.log`.
2. Step 2: standalone `muvpn`:
   - отдельный файл выбранного узла (импортёр), `select` не пишет в tgmuos;
   - `TGMUOS_SINGBOX_MODE=tun` в `mux_launch.sh`;
   - пересборка aarch64 sing-box (`with_gvisor,with_quic,with_wireguard,
     with_utls,with_clash_api`, CGO=1, GLIBC ≤ устройства), проверка
     `version` → `check` → `run`;
   - TUN: `default_interface`, исключение LAN/SSH, DNS hijack, очистка
     маршрутов при падении/reboot, pid+lock;
   - упаковка `.muxzip`, `muvpn.png`, лицензия GPL, обновление ADR 0004.

## Полезные команды (без секретов)

```sh
# запуск пилота (mock)
adb -s bc001080a5104871f12 shell \
  'touch /tmp/muvpn_love_mock; cd /mnt/mmc/MUOS/application/muvpn_love &&
   nohup sh ./mux_launch.sh "$PWD" >/dev/null 2>&1 &'

# лог
adb -s bc001080a5104871f12 shell \
  'tail -40 /mnt/mmc/MUOS/application/muvpn_love/debug.log'

# остановить только LÖVE
adb -s bc001080a5104871f12 shell 'pkill -x love.aarch64'
```

Конфиги и `servers.tsv` не печатать; для проверки изменений использовать
`md5sum`/`ls -l` без вывода содержимого.
