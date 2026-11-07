#!/usr/bin/env python3

import fcntl
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


APP_DIR = Path(__file__).resolve().parent.parent
CONFIG_DIR = Path(os.environ.get("MUVPN_CONFIG_DIR", "/root/.config/muvpn"))
SUBSCRIPTION_CONFIG = Path(
    os.environ.get(
        "TGMUOS_SUBSCRIPTION_CONFIG",
        "/root/.config/tgmuos/subscription.conf",
    )
)
SERVER_LIST = CONFIG_DIR / "servers.tsv"
SINGBOX_CONFIG = CONFIG_DIR / "sing-box.json"
PID_FILE = CONFIG_DIR / "sing-box.pid"
LOCK_FILE = CONFIG_DIR / "service.lock"
LOG_FILE = CONFIG_DIR / "sing-box.log"
SINGBOX = APP_DIR / "libexec" / "sing-box"
IMPORTER = APP_DIR / "tools" / "import_vless_subscription.py"


def ensure_config_dir():
    CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)


def private_environment():
    environment = os.environ.copy()
    environment["TGMUOS_CONFIG_DIR"] = str(CONFIG_DIR)
    environment["TGMUOS_SUBSCRIPTION_CONFIG"] = str(SUBSCRIPTION_CONFIG)
    environment["TGMUOS_SERVERS_FILE"] = str(SERVER_LIST)
    environment["TGMUOS_SINGBOX_MODE"] = os.environ.get(
        "TGMUOS_SINGBOX_MODE", "tun"
    )
    return environment


def run_importer():
    ensure_config_dir()
    if not SUBSCRIPTION_CONFIG.is_file():
        raise RuntimeError("VLESS subscription is not installed")
    result = subprocess.run(
        [sys.executable, str(IMPORTER)],
        env=private_environment(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("VLESS subscription refresh failed")


def config_is_valid():
    result = subprocess.run(
        [str(SINGBOX), "check", "-c", str(SINGBOX_CONFIG)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("sing-box rejected the VPN configuration")


def read_pid():
    try:
        pid = int(PID_FILE.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return None
    return pid if pid > 1 else None


def process_matches(pid):
    try:
        executable = Path(f"/proc/{pid}/exe").resolve()
        command = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
    except (OSError, RuntimeError):
        return False
    return (
        executable == SINGBOX.resolve()
        and b"run" in command
        and str(SINGBOX_CONFIG).encode() in command
    )


def is_connected():
    pid = read_pid()
    if pid is not None and process_matches(pid):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            pass
    elif pid is not None:
        try:
            PID_FILE.unlink()
        except FileNotFoundError:
            pass

    return find_running_pid() is not None


def find_running_pid():
    try:
        process_entries = os.scandir("/proc")
    except OSError:
        return None

    with process_entries:
        for entry in process_entries:
            if not entry.name.isdigit():
                continue
            pid = int(entry.name)
            if process_matches(pid):
                return pid
    return None


def vpn_health():
    if not is_connected():
        return {
            "connected": False,
            "latency_ms": None,
            "probe_error": None,
        }

    request = urllib.request.Request(
        "https://connectivitycheck.gstatic.com/generate_204",
        method="GET",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    started = time.monotonic()
    try:
        with opener.open(request, timeout=5) as response:
            if response.status < 200 or response.status >= 400:
                raise RuntimeError(f"HTTP {response.status}")
        latency_ms = round((time.monotonic() - started) * 1000)
    except (OSError, RuntimeError, urllib.error.URLError) as error:
        return {
            "connected": is_connected(),
            "latency_ms": None,
            "probe_error": str(error)[:100],
            "selected": read_selected_server(),
        }

    connected = is_connected()
    return {
        "connected": connected,
        "latency_ms": latency_ms if connected else None,
        "probe_error": None if connected else "VPN disconnected during probe",
        "selected": read_selected_server(),
    }


def write_pid(pid):
    ensure_config_dir()
    fd, temporary = tempfile.mkstemp(prefix=".sing-box.pid.", dir=CONFIG_DIR)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as output:
            output.write(f"{pid}\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, PID_FILE)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def start(import_subscription=True):
    ensure_config_dir()
    with open(LOCK_FILE, "a", encoding="ascii") as lock:
        os.chmod(LOCK_FILE, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        if is_connected():
            print("VPN is already connected")
            return
        if not SINGBOX.is_file() or not os.access(SINGBOX, os.X_OK):
            raise RuntimeError("bundled sing-box engine is missing")
        if import_subscription:
            run_importer()
        config_is_valid()
        log_fd = os.open(
            LOG_FILE,
            os.O_WRONLY | os.O_CREAT | os.O_APPEND,
            0o600,
        )
        try:
            os.fchmod(log_fd, 0o600)
            with os.fdopen(log_fd, "ab", buffering=0) as log:
                process = subprocess.Popen(
                    [str(SINGBOX), "run", "-c", str(SINGBOX_CONFIG)],
                    stdin=subprocess.DEVNULL,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    close_fds=True,
                    start_new_session=True,
                )
        except BaseException:
            try:
                os.close(log_fd)
            except OSError:
                pass
            raise
        write_pid(process.pid)
        time.sleep(0.3)
        if not process_matches(process.pid):
            try:
                PID_FILE.unlink()
            except FileNotFoundError:
                pass
            raise RuntimeError("VPN engine failed to start; see private log")
        print("VPN connection started")


def stop():
    pid = read_pid()
    if pid is None or not process_matches(pid):
        pid = find_running_pid()
    if pid is None or not process_matches(pid):
        try:
            PID_FILE.unlink()
        except FileNotFoundError:
            pass
        print("VPN is already disconnected")
        return

    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if not process_matches(pid):
            break
        time.sleep(0.1)
    if process_matches(pid):
        os.kill(pid, signal.SIGKILL)
        for _ in range(20):
            if not process_matches(pid):
                break
            time.sleep(0.1)
    try:
        PID_FILE.unlink()
    except FileNotFoundError:
        pass
    print("VPN disconnected")


def read_selected_server():
    try:
        for line in SUBSCRIPTION_CONFIG.read_text(encoding="utf-8").splitlines():
            if line.startswith("selected="):
                value = line[len("selected="):].strip()
                return value if value else None
    except FileNotFoundError:
        return None
    return None


def read_servers():
    rows = []
    with open(SERVER_LIST, encoding="utf-8") as source:
        for line in source:
            fields = line.rstrip("\r\n").split("\t")
            if len(fields) >= 3 and len(fields[0]) == 16:
                rows.append(fields[0])
    return set(rows)



def list_servers():
    selected = read_selected_server()
    servers = []
    try:
        with open(SERVER_LIST, encoding="utf-8") as source:
            for line in source:
                fields = line.rstrip("\r\n").split("\t")
                if len(fields) < 3 or len(fields[0]) != 16:
                    continue
                try:
                    ping = int(fields[1])
                except ValueError:
                    ping = -1
                servers.append({
                    "id": fields[0],
                    "ping_ms": ping if ping >= 0 else None,
                    "name": fields[2][:96],
                    "selected": fields[0] == selected,
                })
    except FileNotFoundError:
        pass
    print(json.dumps({"servers": servers, "selected": selected}, ensure_ascii=False))


def apply_selection(server_id):
    select(server_id)
    if is_connected():
        stop()
    start()


def refresh():
    was_connected = is_connected()
    run_importer()
    config_is_valid()
    if was_connected:
        stop()
        start(import_subscription=False)
    print("Subscription refreshed")


def select(server_id):
    ensure_config_dir()
    if server_id != "auto":
        if len(server_id) != 16 or any(c not in "0123456789abcdef" for c in server_id):
            raise ValueError("invalid server identifier")
        if server_id not in read_servers():
            raise ValueError("server is not in the current subscription")
    if not SUBSCRIPTION_CONFIG.is_file():
        raise RuntimeError("VLESS subscription is not installed")

    lines = SUBSCRIPTION_CONFIG.read_text(encoding="utf-8").splitlines()
    lines = [line for line in lines if not line.startswith("selected=")]
    if server_id != "auto":
        lines.append(f"selected={server_id}")
    fd, temporary = tempfile.mkstemp(
        prefix=".subscription.",
        dir=SUBSCRIPTION_CONFIG.parent,
    )
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write("\n".join(lines) + "\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, SUBSCRIPTION_CONFIG)
        os.chmod(SUBSCRIPTION_CONFIG, 0o600)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    print("Server selection saved")


def main(arguments):
    if len(arguments) != 1 and not (
        len(arguments) == 2 and arguments[0] in ("select", "apply")
    ):
        raise ValueError("usage: muvpn.py start|stop|status|health|servers|refresh|select|apply ID")
    action = arguments[0]
    if action == "start" and len(arguments) == 1:
        start()
    elif action == "stop" and len(arguments) == 1:
        stop()
    elif action == "status" and len(arguments) == 1:
        print("connected" if is_connected() else "disconnected")
    elif action == "health" and len(arguments) == 1:
        print(json.dumps(vpn_health(), separators=(",", ":")))
    elif action == "servers" and len(arguments) == 1:
        list_servers()
    elif action == "refresh" and len(arguments) == 1:
        refresh()
    elif action == "select" and len(arguments) == 2:
        select(arguments[1])
    elif action == "apply" and len(arguments) == 2:
        apply_selection(arguments[1])
    else:
        raise ValueError("unknown muVPN action")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"muVPN: {error}", file=sys.stderr)
        sys.exit(1)
