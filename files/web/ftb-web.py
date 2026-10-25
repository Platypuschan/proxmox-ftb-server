#!/usr/bin/env python3
"""Web GUI for the FTB Minecraft server in this container.

Plain HTTP without login, meant for the local network. Runs as root and uses
the Python standard library only. Backups go through ftb_backup, which keeps
them compatible with the pack's FTB Backups mod.
"""

import http.server
import json
import os
import re
import secrets
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import ftb_backup  # noqa: E402

PORT = int(os.environ.get("FTB_WEB_PORT", "8080"))
FTB_API = "https://api.feed-the-beast.com/v1/modpacks/public/modpack"
MODPACK_CACHE_SECONDS = 600
PACK_ENV = Path("/opt/minecraft/ftb-pack.env")
SERVER_DIR = ftb_backup.SERVER_DIR
UPLOAD_DIR = ftb_backup.UPLOAD_DIR
STATIC_DIR = Path(__file__).resolve().parent / "static"
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
}
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# The FTB installer runs the modloader installer (Forge, NeoForge, Fabric),
# which prints thousands of lines and also writes them to <loader>-*.log in
# the server directory. In job output that block is folded: it starts at
# "INFO: Running <loader> installer" and ends at the FTB installer's next
# tagged line. Lines that look like errors stay visible.
LOADER_BLOCK_START_RE = re.compile(r"^INFO: Running \S+ installer")
LOADER_BLOCK_END_RE = re.compile(r"^(SUCCESS|ERROR|WARN|FATAL):")
# Only the shape of real errors counts: class and library names such as
# "DataResult$Error" or "failureaccess" appear all over the normal output.
LOADER_ERROR_RE = re.compile(
    r"^(\[?(ERROR|FATAL|SEVERE)\b|Exception in thread|Caused by:|[\w.$]+(Exception|Error)(:|$))|\b[Ff]ailed\b")
FORMAT_RE = re.compile(r"§.")


# --------------------------------------------------------------------------
# Server information
# --------------------------------------------------------------------------
def read_pack_env():
    values = {}
    try:
        for line in PACK_ENV.read_text().splitlines():
            key, sep, raw = line.partition("=")
            if sep and key.startswith("FTB_"):
                parts = shlex.split(raw)
                values[key] = parts[0] if parts else ""
    except (OSError, ValueError):
        pass
    return values


def read_properties():
    props = {}
    try:
        for line in (SERVER_DIR / "server.properties").read_text(errors="replace").splitlines():
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                props[key.strip()] = value.strip()
    except OSError:
        pass
    return props


def service_state():
    props = {}
    try:
        out = subprocess.run(
            ["systemctl", "show", "minecraft", "-p", "ActiveState", "-p", "SubState", "-p", "Result",
             "-p", "ActiveEnterTimestampMonotonic", "-p", "MemoryCurrent", "-p", "CPUUsageNSec"],
            capture_output=True, text=True, timeout=10,
        ).stdout
        for line in out.splitlines():
            key, _, value = line.partition("=")
            props[key] = value
    except (OSError, subprocess.SubprocessError):
        pass
    state = {
        "active": props.get("ActiveState", "unknown"),
        "sub": props.get("SubState", ""),
        "result": props.get("Result", ""),
        "uptime": None,
        "memory": None,
        "cpu_ns": None,
    }
    if state["active"] == "active":
        try:
            entered = int(props.get("ActiveEnterTimestampMonotonic", "0"))
            if entered:
                state["uptime"] = max(0, int(time.monotonic() - entered / 1e6))
        except ValueError:
            pass
    for key, name in (("MemoryCurrent", "memory"), ("CPUUsageNSec", "cpu_ns")):
        if props.get(key, "").isdigit():
            state[name] = int(props[key])
    return state


def _varint(value):
    value &= 0xFFFFFFFF
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _read_varint(stream):
    value = shift = 0
    while True:
        byte = stream.read(1)
        if not byte:
            raise ConnectionError("connection closed")
        value |= (byte[0] & 0x7F) << shift
        if not byte[0] & 0x80:
            return value
        shift += 7
        if shift > 35:
            raise ValueError("varint too long")


def _flatten_text(component):
    if isinstance(component, str):
        return component
    if isinstance(component, list):
        return "".join(_flatten_text(c) for c in component)
    if isinstance(component, dict):
        return _flatten_text(component.get("text", "")) + "".join(_flatten_text(c) for c in component.get("extra", []))
    return ""


def server_list_ping(port, timeout=3.0):
    """Minecraft Server List Ping (the status query a client's server list uses)."""
    host = "127.0.0.1"
    started = time.monotonic()
    with socket.create_connection((host, port), timeout=timeout) as sock:
        handshake = _varint(0) + _varint(-1) + _varint(len(host)) + host.encode() + struct.pack(">H", port) + _varint(1)
        sock.sendall(_varint(len(handshake)) + handshake + _varint(1) + _varint(0))
        stream = sock.makefile("rb")
        _read_varint(stream)
        if _read_varint(stream) != 0:
            raise ValueError("unexpected packet")
        raw = stream.read(_read_varint(stream))
    latency = int((time.monotonic() - started) * 1000)
    status = json.loads(raw.decode("utf-8", "replace"))
    players = status.get("players") or {}
    return {
        "version": (status.get("version") or {}).get("name", ""),
        "motd": FORMAT_RE.sub("", _flatten_text(status.get("description", ""))).strip(),
        "online": int(players.get("online", 0)),
        "max": int(players.get("max", 0)),
        "players": sorted(FORMAT_RE.sub("", p.get("name", "")) for p in players.get("sample") or [] if p.get("name")),
        "latency_ms": latency,
    }


LIST_RE = re.compile(r"There are (\d+) (?:of a max of|/) ?(\d+) players online:?(.*)$")


def full_player_list():
    """Runs the console command `list` (the ping only carries up to 12 names)."""
    cursor = ftb_backup.journal_cursor()
    if cursor is None:
        return None
    ftb_backup.console("list")
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        lines = subprocess.run(
            ["journalctl", "-u", "minecraft", "--after-cursor", cursor, "-o", "cat", "--no-pager"],
            capture_output=True, text=True, timeout=10,
        ).stdout.splitlines()
        for index, line in enumerate(lines):
            match = LIST_RE.search(ANSI_RE.sub("", line))
            if match:
                names = match.group(3).strip()
                # Up to 1.12 the names follow on the next log line.
                if not names and index + 1 < len(lines):
                    names = re.sub(r"^\[[^\]]*\]( \[[^\]]*\])*: ", "", ANSI_RE.sub("", lines[index + 1])).strip()
                    if LIST_RE.search(names):
                        names = ""
                return sorted(n.strip() for n in names.split(",") if n.strip())
        time.sleep(0.3)
    return None


def system_usage():
    meminfo = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, _, value = line.partition(":")
            meminfo[key] = int(value.split()[0]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    disk = shutil.disk_usage("/opt/minecraft")
    return {
        "load": os.getloadavg(),
        "cpus": os.cpu_count(),
        "mem_total": meminfo.get("MemTotal"),
        "mem_available": meminfo.get("MemAvailable"),
        "disk_total": disk.total,
        "disk_used": disk.used,
        "disk_free": disk.free,
    }


def read_log(lines):
    out = subprocess.run(
        # -o cat: the server prints its own timestamps.
        ["journalctl", "-u", "minecraft", "-n", str(lines), "-o", "cat", "--no-pager"],
        capture_output=True, text=True, timeout=15,
    ).stdout
    return [ANSI_RE.sub("", line) for line in out.splitlines()]


def _targets(version):
    targets = {t.get("type"): t for t in version.get("targets") or []}
    loader = targets.get("modloader") or {}
    return (targets.get("game") or {}).get("version", ""), " ".join(x for x in (loader.get("name"), loader.get("version")) if x)


def modpack_info(refresh=False):
    """Installed and available versions of the pack, from the FTB API (cached)."""
    pack = read_pack_env()
    pack_id = pack.get("FTB_PACK_ID", "")
    cached_at, cached_id, data = STATE["modpack"]
    if refresh or data is None or cached_id != pack_id or time.time() - cached_at > MODPACK_CACHE_SECONDS:
        # The API rejects Python's default user agent.
        request = urllib.request.Request("%s/%s" % (FTB_API, pack_id), headers={"User-Agent": "ftb-web/1.0"})
        with urllib.request.urlopen(request, timeout=20) as response:
            data = json.load(response)
        STATE["modpack"] = (time.time(), pack_id, data)
    versions = []
    for v in sorted(data.get("versions") or [], key=lambda v: v.get("id", 0), reverse=True):
        mc, loader = _targets(v)
        versions.append({"id": v["id"], "name": v.get("name", ""), "type": v.get("type", ""),
                         "released": v.get("released") or v.get("updated") or 0, "mc": mc, "loader": loader})
    current_id = int(pack.get("FTB_VERSION_ID") or 0)
    current = next((v for v in versions if v["id"] == current_id), {"id": current_id, "name": str(current_id), "released": 0})
    latest = next((v for v in versions if v["type"] == "release"), versions[0] if versions else None)
    return {
        "pack_id": pack_id,
        "name": data.get("name") or pack.get("FTB_PACK_NAME"),
        "current": current,
        "latest": latest,
        "update_available": bool(latest and latest["id"] != current["id"] and latest["released"] > current["released"]),
        "versions": versions,
    }


# --------------------------------------------------------------------------
# Background jobs (start/stop, backups); one at a time
# --------------------------------------------------------------------------
class Busy(Exception):
    pass


class Jobs:
    MAX_LINES = 400
    # The start of a job (what it does, backup made) always stays visible;
    # long output is cut after it.
    HEAD_LINES = 40

    def __init__(self):
        self.lock = threading.Lock()
        self.current = None

    def start(self, kind, title, command):
        with self.lock:
            if self.current and self.current["state"] == "running":
                raise Busy(self.current["title"])
            job = {
                "id": secrets.token_hex(4), "kind": kind, "title": title, "state": "running",
                "started": time.time(), "finished": None, "rc": None, "output": [], "cut": 0,
            }
            self.current = job
        threading.Thread(target=self._run, args=(job, command), daemon=True).start()
        return self.snapshot()

    def _run(self, job, command):
        rc = -1
        hidden, in_loader_block, summary_at = 0, False, 0
        try:
            proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
                                    env={**os.environ, "PYTHONUNBUFFERED": "1"})
            for line in proc.stdout:
                line = ANSI_RE.sub("", line.rstrip("\n")).replace("\x1b[?25l", "").replace("\x1b[?25h", "")
                with self.lock:
                    if in_loader_block and LOADER_BLOCK_END_RE.match(line):
                        in_loader_block = False
                    if in_loader_block and not LOADER_ERROR_RE.search(line):
                        hidden += 1
                        out = job["output"]
                        if summary_at >= len(out) or not out[summary_at].startswith("  …"):
                            out.append("  …")  # trimming moved the summary line
                            summary_at = len(out) - 1
                        out[summary_at] = "  … %d Zeilen des Modloader-Installers ausgeblendet " \
                                          "(vollständig in der .log-Datei im Serververzeichnis)" % hidden
                        continue
                    if LOADER_BLOCK_START_RE.match(line):
                        in_loader_block, hidden = True, 0
                        job["output"].append(line)
                        job["output"].append("  …")
                        summary_at = len(job["output"]) - 1
                    elif not line.strip() and job["output"] and job["output"][-1].startswith("Downloading"):
                        continue  # blank line inside the progress bar redraw
                    elif line.startswith("Downloading") and job["output"] and job["output"][-1].startswith("Downloading"):
                        # The FTB installer redraws a progress bar; keep only its latest state.
                        job["output"][-1] = line
                    else:
                        job["output"].append(line)
                    self._trim(job)
            rc = proc.wait()
        except OSError as exc:
            with self.lock:
                job["output"].append(str(exc))
        with self.lock:
            job.update(state="done" if rc == 0 else "failed", rc=rc, finished=time.time())

    def _trim(self, job):
        out = job["output"]
        excess = len(out) - self.MAX_LINES
        if excess <= 0:
            return
        start = self.HEAD_LINES + (1 if job["cut"] else 0)
        del out[start:start + excess]
        marker = "… %d Zeilen gekürzt …" % (job["cut"] + excess)
        if job["cut"]:
            out[self.HEAD_LINES] = marker
        else:
            out.insert(self.HEAD_LINES, marker)
        job["cut"] += excess

    def snapshot(self):
        with self.lock:
            return json.loads(json.dumps(self.current)) if self.current else None


JOBS = Jobs()
STATE = {"cpu_sample": None, "player_cache": (0.0, None), "modpack": (0.0, None, None)}
BACKUP_CMD = ["/usr/local/bin/ftb-backup"]


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ftb-web"
    sys_version = ""
    timeout = 120

    def log_message(self, fmt, *args):
        if self.command != "GET" or not self.path.startswith("/api/"):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _headers(self, status, content_type, length, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self._headers(status, "application/json", len(body))
        self.wfile.write(body)

    def error(self, status, message):
        self.send_json(status, {"error": message})

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length)) if length else {}

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def do_PUT(self):
        self.dispatch("PUT")

    def do_DELETE(self):
        self.dispatch("DELETE")

    def dispatch(self, method):
        path = self.path.split("?", 1)[0]
        try:
            if method == "GET" and path in STATIC_FILES:
                return self.static(*STATIC_FILES[path])
            if path.startswith("/api/"):
                return self.route(method, path.strip("/").split("/")[1:])
            return self.error(404, "not found")
        except Busy as exc:
            return self.error(409, "Es läuft bereits: %s" % exc)
        except ftb_backup.BackupError as exc:
            return self.error(404 if str(exc).startswith("Unknown") else 400, str(exc))
        except (ValueError, KeyError) as exc:
            return self.error(400, str(exc))
        except (ConnectionError, TimeoutError):
            self.close_connection = True
            return None

    def route(self, method, parts):
        if method == "GET" and parts == ["status"]:
            return self.send_json(200, self.status())
        if method == "POST" and len(parts) == 2 and parts[0] == "server" and parts[1] in ("start", "stop", "restart"):
            titles = {"start": "Server starten", "stop": "Server stoppen", "restart": "Server neu starten"}
            return self.send_json(202, JOBS.start(parts[1], titles[parts[1]], ["systemctl", parts[1], "minecraft"]))
        if method == "GET" and parts == ["job"]:
            return self.send_json(200, JOBS.snapshot())
        if method == "GET" and parts == ["log"]:
            return self.send_json(200, {"lines": read_log(300)})
        if method == "POST" and parts == ["console"]:
            command = str(self.read_json().get("command", "")).strip().lstrip("/")
            if not command or "\n" in command:
                raise ValueError("Ungültiger Befehl")
            if service_state()["active"] != "active":
                raise ValueError("Der Server läuft nicht")
            ftb_backup.console(command)
            return self.send_json(200, {"ok": True})
        if parts and parts[0] == "backups":
            return self.backups(method, parts[1:])
        if parts and parts[0] == "modpack":
            return self.modpack(method, parts[1:])
        return self.error(404, "not found")

    def static(self, name, content_type):
        body = (STATIC_DIR / name).read_bytes()
        self._headers(200, content_type, len(body))
        self.wfile.write(body)

    def status(self):
        pack = read_pack_env()
        props = read_properties()
        service = service_state()
        port = int(props.get("server-port") or 25565)
        ping = None
        if service["active"] == "active":
            try:
                ping = server_list_ping(port)
            except (OSError, ValueError):
                ping = None  # still starting
        if ping and ping["online"] > len(ping["players"]):
            cached_at, names = STATE["player_cache"]
            if time.time() - cached_at > 30:
                names = full_player_list()
                STATE["player_cache"] = (time.time(), names)
            if names is not None:
                ping["players"] = names
        cpu_percent = None
        now = time.monotonic()
        if service["cpu_ns"] is not None:
            previous = STATE["cpu_sample"]
            STATE["cpu_sample"] = (now, service["cpu_ns"])
            if previous and now > previous[0] and service["cpu_ns"] >= previous[1]:
                cpu_percent = round((service["cpu_ns"] - previous[1]) / 1e9 / (now - previous[0]) * 100, 1)
        service["cpu_percent"] = cpu_percent
        return {
            "pack": {"id": pack.get("FTB_PACK_ID"), "name": pack.get("FTB_PACK_NAME"), "version_id": pack.get("FTB_VERSION_ID")},
            "service": service,
            "ping": ping,
            "port": port,
            "level": props.get("level-name") or "world",
            "system": system_usage(),
            "job": JOBS.snapshot(),
        }

    def backups(self, method, parts):
        provider = ftb_backup.detect()
        if method == "GET" and not parts:
            folder = provider.folder if provider.folder.exists() else SERVER_DIR
            return self.send_json(200, {
                "provider": provider.describe(),
                "backups": ftb_backup.list_backups(provider),
                "free": shutil.disk_usage(folder).free,
            })
        if method == "POST" and not parts:
            label = ftb_backup.clean_label(str(self.read_json().get("label", "")))
            return self.send_json(202, JOBS.start("backup", "Backup erstellen", BACKUP_CMD + ["create", label]))
        if method == "PUT" and parts == ["upload"]:
            return self.upload()
        if parts:
            backup, path = ftb_backup.find(provider, parts[0])
            name = backup["name"]
            if method == "GET" and parts[1:] == ["download"]:
                return self.download(path)
            if method == "POST" and parts[1:] == ["restore"]:
                return self.send_json(202, JOBS.start("restore", "Backup einspielen: %s" % name, BACKUP_CMD + ["restore", name]))
            if method == "DELETE" and len(parts) == 1:
                return self.send_json(202, JOBS.start("delete", "Backup löschen: %s" % name, BACKUP_CMD + ["delete", name]))
        return self.error(404, "not found")

    def modpack(self, method, parts):
        try:
            info = modpack_info(refresh="refresh=1" in self.path)
        except (OSError, ValueError) as exc:
            return self.error(502, "FTB-API nicht erreichbar: %s" % exc)
        if method == "GET" and not parts:
            return self.send_json(200, info)
        if method == "POST" and parts == ["update"]:
            wanted = int(self.read_json().get("version_id", 0))
            version = next((v for v in info["versions"] if v["id"] == wanted), None)
            if not version:
                raise ValueError("Unbekannte Version: %s" % wanted)
            title = "Modpack auf %s (%s) umstellen" % (version["name"], version["id"])
            job = JOBS.start("modpack", title, ["/usr/local/bin/ftb-update", str(version["id"])])
            STATE["modpack"] = (0.0, None, None)  # re-read after the switch
            return self.send_json(202, job)
        return self.error(404, "not found")

    def download(self, path):
        if not path.is_file():
            raise ValueError("Ordner-Backups lassen sich nicht herunterladen")
        size = path.stat().st_size
        self._headers(200, "application/octet-stream", size, {"Content-Disposition": 'attachment; filename="%s"' % path.name})
        with path.open("rb") as source:
            shutil.copyfileobj(source, self.wfile, 1024 * 1024)

    def upload(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            raise ValueError("Leere Datei")
        UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
        if length + 512 * 1024 * 1024 > shutil.disk_usage(UPLOAD_DIR).free:
            return self.error(507, "Nicht genug Speicherplatz für den Upload")
        original = os.path.basename(self.headers.get("X-Filename", ""))
        staged = original if ftb_backup.NAME_RE.match(original) and original.endswith(".zip") else "upload-%s.zip" % secrets.token_hex(6)
        target = UPLOAD_DIR / staged
        partial = UPLOAD_DIR / (".%s.partial" % staged)
        remaining = length
        try:
            with partial.open("wb") as out:
                while remaining:
                    chunk = self.rfile.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        raise ConnectionError("upload aborted")
                    out.write(chunk)
                    remaining -= len(chunk)
            partial.replace(target)
        finally:
            partial.unlink(missing_ok=True)
        return self.send_json(202, JOBS.start("import", "Backup hochladen: %s" % (original or staged), BACKUP_CMD + ["import", staged]))


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()


def main():
    try:
        httpd = Server(("::", PORT), Handler)
    except OSError:
        Server.address_family = socket.AF_INET
        httpd = Server(("0.0.0.0", PORT), Handler)
    sys.stderr.write("ftb-web listening on http://[::]:%d\n" % PORT)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
