#!/usr/bin/env python3

import base64
import concurrent.futures
import copy
import hashlib
import json
import os
import re
import socket
import sys
import time
import urllib.parse
import urllib.request

CONFIG_DIR = os.environ.get("TGMUOS_CONFIG_DIR", "/root/.config/tgmuos")
SUBSCRIPTION_FILE = os.environ.get(
    "TGMUOS_SUBSCRIPTION_CONFIG",
    os.path.join(CONFIG_DIR, "subscription.conf"),
)
SUBSCRIPTION_SOURCES_FILE = os.environ.get(
    "TGMUOS_SUBSCRIPTION_SOURCES",
    os.path.join(CONFIG_DIR, "subscription-sources.txt"),
)
MANUAL_PROFILE = os.environ.get(
    "TGMUOS_MANUAL_PROFILE",
    os.path.join(CONFIG_DIR, "manual-sing-box.json"),
)
SINGBOX_CONFIG = os.path.join(CONFIG_DIR, "sing-box.json")
SERVER_LIST = os.environ.get(
    "TGMUOS_SERVERS_FILE",
    os.path.join(CONFIG_DIR, "servers.tsv"),
)
MAX_RESPONSE_SIZE = 1024 * 1024
PING_TIMEOUT = 2.0


class HTTPSOnlyRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        if urllib.parse.urlsplit(new_url).scheme.lower() != "https":
            raise urllib.error.URLError("subscription redirect must use HTTPS")
        return super().redirect_request(
            request, file_pointer, code, message, headers, new_url
        )


def read_subscription_urls():
    urls = []

    def add_url(value):
        url = value.strip()
        if not url or url.startswith("#"):
            return
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme.lower() != "https" or not parsed.hostname:
            raise ValueError("subscription URL must use HTTPS")
        if url not in urls:
            urls.append(url)

    try:
        with open(SUBSCRIPTION_FILE, encoding="utf-8") as config:
            for line in config:
                key, separator, value = line.rstrip("\r\n").partition("=")
                if separator and key == "url":
                    add_url(value)
    except FileNotFoundError:
        pass

    try:
        with open(SUBSCRIPTION_SOURCES_FILE, encoding="utf-8") as sources:
            for line in sources:
                add_url(line.rstrip("\r\n"))
    except FileNotFoundError:
        pass
    return urls


def read_subscription_url():
    with open(SUBSCRIPTION_FILE, encoding="utf-8") as config:
        for line in config:
            key, separator, value = line.rstrip("\r\n").partition("=")
            if separator and key == "url":
                url = value.strip()
                parsed = urllib.parse.urlsplit(url)
                if parsed.scheme.lower() != "https" or not parsed.hostname:
                    raise ValueError("subscription URL must use HTTPS")
                return url
    return ""


def read_manual_profile():
    try:
        with open(MANUAL_PROFILE, encoding="utf-8") as profile:
            return json.load(profile)
    except FileNotFoundError:
        return {}


def read_manual_nodes(profile):
    nodes = []
    for source in profile.get("outbounds", []):
        if source.get("type") != "vless":
            continue
        node = copy.deepcopy({
            key: value for key, value in source.items()
            if key not in ("_id", "_name")
        })
        if (not node.get("server") or not node.get("server_port") or
                not node.get("uuid")):
            continue
        stable_data = json.dumps(
            {key: value for key, value in node.items() if key != "tag"},
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        server_id = hashlib.sha256(stable_data).hexdigest()[:16]
        node["tag"] = "node-" + server_id
        node["_id"] = server_id
        node["_name"] = "🇫🇲 Для Telegram"
        nodes.append(node)
    return nodes


def read_subscription(url):
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "TGMUOS/1.0 sing-box subscription importer"},
    )
    opener = urllib.request.build_opener(HTTPSOnlyRedirectHandler())
    for attempt in range(3):
        try:
            with opener.open(request, timeout=20) as response:
                body = response.read(MAX_RESPONSE_SIZE + 1)
            break
        except urllib.error.HTTPError:
            raise
        except urllib.error.URLError:
            if attempt == 2:
                raise
            time.sleep(1 << attempt)
    if len(body) > MAX_RESPONSE_SIZE:
        raise ValueError("subscription response exceeds 1 MiB")
    text = body.decode("utf-8").strip()
    if "://" not in text:
        text = base64.b64decode(text, validate=True).decode("utf-8").strip()
    return [line.strip() for line in text.splitlines() if line.strip()]


def parse_vless(uri, index):
    parsed = urllib.parse.urlsplit(uri)
    if parsed.scheme != "vless" or not parsed.hostname or not parsed.port:
        raise ValueError("invalid VLESS URI")
    if not parsed.username:
        raise ValueError("VLESS UUID is missing")
    options = urllib.parse.parse_qs(parsed.query, strict_parsing=False)

    def option(name, default=""):
        return options.get(name, [default])[0]

    if option("type", "tcp") != "tcp":
        raise ValueError("only TCP VLESS transports are supported")
    if option("encryption", "none") != "none":
        raise ValueError("unsupported VLESS encryption")

    outbound = {
        "type": "vless",
        "server": parsed.hostname,
        "server_port": parsed.port,
        "uuid": urllib.parse.unquote(parsed.username),
    }
    flow = option("flow")
    if flow:
        outbound["flow"] = flow

    security = option("security")
    if security in ("tls", "reality"):
        tls = {"enabled": True}
        server_name = option("sni")
        if server_name:
            tls["server_name"] = server_name
        fingerprint = option("fp")
        if fingerprint:
            tls["utls"] = {"enabled": True, "fingerprint": fingerprint}
        alpn = option("alpn")
        if alpn:
            tls["alpn"] = [item for item in alpn.split(",") if item]
        if security == "reality":
            public_key = option("pbk")
            if not public_key:
                raise ValueError("Reality public key is missing")
            tls["reality"] = {
                "enabled": True,
                "public_key": public_key,
                "short_id": option("sid"),
            }
        outbound["tls"] = tls
    elif security:
        raise ValueError("unsupported VLESS security mode")
    stable_data = json.dumps(
        {key: value for key, value in outbound.items() if key != "tag"},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    server_id = hashlib.sha256(stable_data).hexdigest()[:16]
    outbound["tag"] = "node-" + server_id
    name = urllib.parse.unquote(parsed.fragment).strip() or parsed.hostname
    name = re.sub(r"[\x00-\x1f\x7f\t|]", " ", name)
    outbound["_id"] = server_id
    outbound["_name"] = name[:96]
    return outbound


def probe_server(node):
    started = time.monotonic()
    try:
        with socket.create_connection(
            (node["server"], node["server_port"]), timeout=PING_TIMEOUT
        ):
            return int((time.monotonic() - started) * 1000 + 0.5)
    except OSError:
        return None


def sort_servers_by_ping(nodes):
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        pings = list(executor.map(probe_server, nodes))
    servers = []
    for node, ping in zip(nodes, pings):
        servers.append({
            "id": node["_id"],
            "name": node["_name"],
            "ping": ping,
            "tag": node["tag"],
            "host": node["server"],
            "port": node["server_port"],
        })
    return sorted(servers, key=lambda server: (
        server["ping"] is None,
        server["ping"] if server["ping"] is not None else 0,
        server["name"].casefold(),
    ))


def read_selected_server():
    try:
        with open(SUBSCRIPTION_FILE, encoding="utf-8") as config:
            for line in config:
                key, separator, value = line.rstrip("\r\n").partition("=")
                if separator and key == "selected":
                    return value.strip()
    except OSError:
        return ""
    return ""


def write_server_list(servers):
    os.makedirs(os.path.dirname(SERVER_LIST), mode=0o700, exist_ok=True)
    temporary = SERVER_LIST + ".tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        for server in servers:
            ping = str(server["ping"]) if server["ping"] is not None else "-1"
            output.write("{}\t{}\t{}\t{}\t{}\n".format(
                server["id"], ping, server["name"],
                server.get("host") or "", server.get("port") or "",
            ))
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, SERVER_LIST)
    os.chmod(SERVER_LIST, 0o600)
    os.chmod(SERVER_LIST, 0o600)


def build_config(uris, selected_id="", tun_mode=False,
                 manual_profile=None):
    outbounds = []
    errors = 0
    seen_tags = set()
    for line in uris:
        try:
            outbound = parse_vless(line, len(outbounds) + 1)
        except (ValueError, UnicodeError):
            errors += 1
            continue
        if outbound["tag"] in seen_tags:
            errors += 1
            continue
        seen_tags.add(outbound["tag"])
        outbounds.append(outbound)
    manual_profile = manual_profile or {}
    for outbound in read_manual_nodes(manual_profile):
        if outbound["tag"] in seen_tags:
            continue
        seen_tags.add(outbound["tag"])
        outbounds.append(outbound)
    if not outbounds:
        raise ValueError("no supported VLESS nodes or manual profile")
    selected_tag = next(
        (item["tag"] for item in outbounds if item["_id"] == selected_id), None
    )
    nodes = [dict(item) for item in outbounds]
    for item in outbounds:
        item.pop("_id", None)
        item.pop("_name", None)
    tags = [item["tag"] for item in outbounds]
    outbounds.append({
        "type": "urltest",
        "tag": "proxy",
        "outbounds": tags,
        "url": "https://core.telegram.org/",
        "interval": "3m",
        "tolerance": 50,
        "interrupt_exist_connections": True,
    })
    outbounds.append({"type": "direct", "tag": "direct"})
    manual_route = manual_profile.get("route", {})
    direct_rules = [
        copy.deepcopy(rule)
        for rule in manual_route.get("rules", [])
        if rule.get("outbound") == "direct"
    ]
    if tun_mode:
        inbound = {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "muvpn0",
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "auto_route": True,
            "strict_route": True,
            "stack": "system",
        }
        dns = {
            "servers": [
                {"type": "local", "tag": "bootstrap"},
                {
                    "type": "https",
                    "tag": "remote",
                    "server": "1.1.1.1",
                    "server_port": 443,
                    "path": "/dns-query",
                    "detour": "proxy",
                },
            ],
            "final": "remote",
        }
        route_rules = direct_rules + [{"protocol": "dns", "action": "hijack-dns"}]
    else:
        inbound = {
            "type": "socks",
            "tag": "local-socks",
            "listen": "127.0.0.1",
            "listen_port": 10808,
        }
        dns = copy.deepcopy(manual_profile.get("dns"))
        route_rules = direct_rules

    config = {
        "log": {"level": "warn", "timestamp": True},
        "inbounds": [inbound],
        "outbounds": outbounds,
        "route": {
            "rules": route_rules,
            "final": selected_tag or "proxy",
            "auto_detect_interface": bool(tun_mode),
        },
    }
    if tun_mode:
        config["route"]["default_domain_resolver"] = "bootstrap"
    elif manual_route.get("default_domain_resolver"):
        config["route"]["default_domain_resolver"] = manual_route[
            "default_domain_resolver"
        ]
    if dns:
        config["dns"] = dns
    return config, len(tags), errors, nodes


def main():
    os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)
    urls = read_subscription_urls()
    manual_profile = read_manual_profile()
    uris = []
    failed_sources = 0
    for index, url in enumerate(urls, start=1):
        try:
            uris.extend(read_subscription(url))
        except (OSError, ValueError, urllib.error.URLError) as error:
            failed_sources += 1
            print("Subscription source {} failed: {}".format(
                index, type(error).__name__
            ), file=sys.stderr)
    config, supported, skipped, nodes = build_config(
        uris,
        read_selected_server(),
        tun_mode=os.environ.get("TGMUOS_SINGBOX_MODE") == "tun",
        manual_profile=manual_profile,
    )
    servers = sort_servers_by_ping(nodes)
    write_server_list(servers)
    temporary = SINGBOX_CONFIG + ".tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(config, output, separators=(",", ":"))
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, SINGBOX_CONFIG)
    os.chmod(SINGBOX_CONFIG, 0o600)
    print("Imported {} VLESS nodes ({} unsupported entries, {} failed sources)".format(
        supported, skipped, failed_sources
    ))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, urllib.error.URLError) as error:
        print("Subscription import failed: {}".format(type(error).__name__), file=sys.stderr)
        sys.exit(1)
