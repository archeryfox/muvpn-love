# muVPN LÖVE pilot

LÖVE 11.5 pilot of the muVPN server picker and connection status screen for
the Anbernic RG35XX SP / muOS. This is a UI prototype that runs against the
real `muvpn.py` service manager; it is separate from the C application in
`../tgmuos/muvpn/`.

- 640×480 fullscreen, framebuffer-friendly, vsync enabled.
- Server list from `servers.tsv` (ping, name, selection marker), plus an
  `Автоматически (urltest)` row.
- Status pill: connected / disconnected / working / error.
- All service calls run in `love.thread`; the UI never blocks.
- Russian labels match the C scaffold in `../tgmuos/muvpn/src/main.c`.

## Controls

| Action | Gamepad | Keyboard |
| --- | --- | --- |
| Move cursor | D-pad up/down | arrows |
| Save selection | A | Enter / Space |
| Connect / disconnect | X | X / C |
| Refresh subscription | R1 | R |
| Exit | B / START | Esc / S |

## Service wiring

`service_worker.lua` runs:

```sh
python3 tools/muvpn.py status|start|stop|refresh|select <id>
```

with private paths rooted at `MUVPN_CONFIG_DIR` (default
`/root/.config/muvpn_love`):

- `TGMUOS_CONFIG_DIR` — generated profile and logs;
- `TGMUOS_SUBSCRIPTION_CONFIG` — private copy of the subscription file used for
  selection (never the shared `tgmuos` file);
- `TGMUOS_SERVERS_FILE` — `servers.tsv` for this app;
- `TGMUOS_SINGBOX_MODE=tun`.

There is intentionally no `libexec/sing-box` in this pilot, so a real
`start` reports `движок sing-box не найден`. That is the expected error path
until the engine is fixed in the standalone app.

### Mock mode

```sh
MUVPN_LOVE_MOCK=1 ...
```

simulates connected/disconnected transitions and a four-node list, so the UI
can be exercised on the host or on the device without the engine. On the
device the muOS frontend may relaunch the app with its own environment, so a
marker file is also accepted: `touch /tmp/muvpn_love_mock`.

## Layout

```text
conf.lua                 window and module configuration
main.lua                 UI, input, status polling
service_worker.lua       love.thread wrapper around tools/muvpn.py
log.lua                  append-only debug logger
tools/muvpn.py           temporary copy of the service manager
tools/import_vless_subscription.py  subscription importer copy
AdwaitaSans-Regular.ttf  Cyrillic-capable UI font
mux_launch.sh            muOS launcher (HELP/GRID header)
gameinfo.xml             muOS menu metadata
```

The copies under `tools/` are a snapshot for piloting. Once selection state is
separated from `tgmuos` in the standalone app, the pilot should call the
installed service instead of keeping local copies.

## Run on the device

```sh
adb -s bc001080a5104871f12 shell \
  'sh /mnt/mmc/MUOS/application/muvpn_love/mux_launch.sh /mnt/mmc/MUOS/application/muvpn_love'
```

Mock run:

```sh
adb -s bc001080a5104871f12 shell \
  'cd /mnt/mmc/MUOS/application/muvpn_love && MUVPN_LOVE_MOCK=1 sh ./mux_launch.sh "$PWD"'
```

Launcher output goes to `log.txt`; the app and its worker append structured
lines to `debug.log` beside the app (startup paths, actions, service exit
codes and output, state transitions, unhandled errors). Neither log contains
subscription contents, URLs, UUIDs or node secrets.

## Device configuration (private)

Create `/root/.config/muvpn_love/` with mode 700 and copy the subscription and
server list there with mode 600. Never print or commit these files.

```sh
adb shell 'mkdir -p /root/.config/muvpn_love && chmod 700 /root/.config/muvpn_love &&
  cp /root/.config/tgmuos/subscription.conf /root/.config/muvpn_love/subscription.conf &&
  cp /root/.config/tgmuos/servers.tsv /root/.config/muvpn_love/servers.tsv &&
  chmod 600 /root/.config/muvpn_love/*.conf /root/.config/muvpn_love/*.tsv'
```

## Docs

- `docs/aichat/README.md` — правила координации агентов для этого каталога.
- `docs/aichat/2026-10-29_1335_opencode-muvpn-love.md` — журнал пилота:
  решения, ошибки, результаты проверок на устройстве, следующие шаги.
- Краткая копия для агентов TGMUOS:
  `../tgmuos/docs/aichat/2026-10-29_1335_opencode-muvpn-love.md`.

## Package for the muOS Archive Manager

The `.muxzip` is a ZIP whose root contains `application/muvpn_love/`.

```sh
cd muvpn_love
zip -0 -r ../muvpn_love.muxzip application
```

The package should not contain `subscription.conf` or `servers.tsv`.


## Related projects

- [Telegram for muOS/Knulli](https://github.com/archeryfox/TGmuOS-LOVE) — Telegram client for the same devices.

## Keywords

VPN for muOS, VPN for Knulli, VPN for Anbernic, muVPN, muVPN muOS, muVPN Knulli,
sing-box muOS, sing-box Knulli, sing-box Anbernic, VLESS muOS, VLESS Anbernic,
PortMaster VPN, muOS VPN client, Knulli VPN client, Anbernic VPN client,
RG35XX VPN, RG35XX SP VPN, portable VPN, handheld VPN, VPN for retro console,
muOS sing-box, Knulli sing-box, Anbernic VPN app, VPN on Anbernic.

