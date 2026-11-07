#!/bin/sh
# HELP: muVPN LÖVE pilot
# GRID: muvpn_love

. /opt/muos/script/var/func.sh

echo app >/tmp/act_go

BASE_DIR="$1"
[ -z "$BASE_DIR" ] && BASE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$BASE_DIR" || exit 1

SETUP_SDL_ENVIRONMENT
SET_VAR "system" "foreground_process" "muvpn_love"

if command -v flock >/dev/null 2>&1; then
    exec 9>/tmp/muvpn_love.lock
    if ! flock -n 9; then
        printf '%s\n' "muVPN pilot is already running" >"$BASE_DIR/log.txt"
        exit 0
    fi
fi

printf '[%s] launcher start pid=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" >>"$BASE_DIR/debug.log"

export MUVPN_CONFIG_DIR=/root/.config/muvpn_love
export TGMUOS_CONFIG_DIR="$MUVPN_CONFIG_DIR"
export TGMUOS_SUBSCRIPTION_CONFIG="$MUVPN_CONFIG_DIR/subscription.conf"
export TGMUOS_SERVERS_FILE="$MUVPN_CONFIG_DIR/servers.tsv"
export TGMUOS_SINGBOX_MODE=tun

RUNTIME=/mnt/mmc/MUOS/PortMaster/runtimes/love_11.5
if [ ! -x "$RUNTIME/love.aarch64" ]; then
    printf '%s\n' "LÖVE runtime not found: $RUNTIME/love.aarch64" >"$BASE_DIR/log.txt"
    exit 1
fi

export LD_LIBRARY_PATH="$RUNTIME/libs.aarch64:$LD_LIBRARY_PATH"
exec >"$BASE_DIR/log.txt" 2>&1

"$RUNTIME/love.aarch64" "$BASE_DIR"
status=$?
printf '[%s] launcher exit status=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$status" >>"$BASE_DIR/debug.log"
exit "$status"
