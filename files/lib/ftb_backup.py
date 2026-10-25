"""Backups compatible with the FTB Backups mods.

The pack's own backup mod decides the format, so backups made here show up in
the mod (and its rotation), and the mod's automatic backups show up here:

  FTB Backups 3  <server>/ftbbackups3/, index backups.json5 (JSON array),
                 files yyyy-MM-dd-HH-mm-ss[_label].zip, command `ftbbackups3 start`
  FTB Backups 2  <server>/backups/, index backups.json ({"backups": [...]}),
                 files yyyy-M-d_H-m-s.zip, command `backup snapshot` (protected)
  anything else  FTB Backups 3 layout, written by this module (so a later pack
                 version with FTB Backups 3 picks the backups up)

All formats hold the world folder only (entries "world/..."); mods and
configs come from the modpack version. Runs as root.
"""

import fcntl
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import time
import zipfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

SERVER_DIR = Path("/opt/minecraft/server")
UPLOAD_DIR = Path("/opt/minecraft/.upload")
CONSOLE = Path("/run/minecraft.stdin")
LOCK_FILE = Path("/run/ftb-backup.lock")
SERVER_USER = "minecraft"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,120}$")
V3_AUTO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}$")
# Backups made automatically before an update or restore; only these are pruned here.
AUTO_LABELS = ("pre-update", "pre-restore")
AUTO_KEEP = 3
MOD_TIMEOUT = 3600


class BackupError(Exception):
    pass


# --------------------------------------------------------------------------
# Provider detection
# --------------------------------------------------------------------------
@dataclass
class Provider:
    kind: str  # "v3", "v2" or "own"
    name: str
    folder: Path
    index: Path
    mod_command: bool  # the mod can create backups via console command

    def describe(self):
        return {"kind": self.kind, "name": self.name, "folder": str(self.folder), "index": str(self.index)}


def _read(path):
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def _config_string(text, key):
    match = re.search(r'["\']?%s["\']?\s*[:=]\s*"([^"]*)"' % re.escape(key), text)
    return match.group(1) if match else None


def _config_bool(text, key, default):
    match = re.search(r'["\']?%s["\']?\s*[:=]\s*(true|false)' % re.escape(key), text)
    return default if not match else match.group(1) == "true"


def _v3_index(jars):
    """FTB Backups 3 keeps its index in <server>/ftbbackups3/ even when "folder"
    moves the archives: backups.json up to MC 1.21 (mod 21.x), backups.json5 after."""
    folder = SERVER_DIR / "ftbbackups3"
    for name in ("backups.json5", "backups.json"):
        if (folder / name).exists():
            return folder / name
    majors = [int(m.group(1)) for jar in jars for m in [re.match(r"ftb-backups-3-(\d+)\.", jar.name)] if m]
    return folder / ("backups.json" if majors and max(majors) <= 21 else "backups.json5")


def detect():
    mods = SERVER_DIR / "mods"
    v3_jars = list(mods.glob("ftb-backups-3-*.jar"))
    if v3_jars:
        text = ""
        for candidate in ("config/ftbbackups3-server.snbt", "config/ftbbackups3-server.json5"):
            text = _read(SERVER_DIR / candidate) or text
        level = level_name()
        for candidate in ("serverconfig/ftbbackups3-server.snbt", "serverconfig/ftbbackups3-server.json5"):
            text = _read(SERVER_DIR / level / candidate) or text
        folder = (_config_string(text, "folder") or "").strip()
        folder = Path(folder) if folder else SERVER_DIR / "ftbbackups3"
        return Provider("v3", "FTB Backups 3", folder, _v3_index(v3_jars), True)
    if any(mods.glob("ftbbackups2-*.jar")):
        text = _read(SERVER_DIR / "config" / "ftbbackups2.json")
        location = (_config_string(text, "backup_location") or ".").strip()
        folder = SERVER_DIR / "backups" if location in (".", "") else Path(location)
        return Provider("v2", "FTB Backups 2", folder, SERVER_DIR / "backups" / "backups.json",
                        _config_bool(text, "enabled", True))
    folder = SERVER_DIR / "ftbbackups3"
    return Provider("own", "eigene Backups (Format FTB Backups 3)", folder, folder / "backups.json5", False)


def level_name():
    try:
        for line in (SERVER_DIR / "server.properties").read_text(errors="replace").splitlines():
            if line.startswith("level-name="):
                return line.split("=", 1)[1].strip() or "world"
    except OSError:
        pass
    return "world"


# --------------------------------------------------------------------------
# Index files
# --------------------------------------------------------------------------
_JSON5_TOKEN = re.compile(r'''"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|//[^\n]*|/\*.*?\*/|[A-Za-z_$][\w$]*(?=\s*:)|,(?=\s*[\]}])''', re.S)


def _json5_to_json(text):
    """The JSON5 subset the index files can contain: comments, trailing commas,
    unquoted keys and single-quoted strings. Strings are matched as whole
    tokens, so their content is never rewritten."""
    def convert(match):
        token = match.group(0)
        if token.startswith('"'):
            return token
        if token.startswith("'"):
            return json.dumps(token[1:-1].replace("\\'", "'"))
        if token.startswith(("//", "/*")) or token == ",":
            return ""
        return '"%s"' % token  # unquoted key
    return _JSON5_TOKEN.sub(convert, text)


def read_index(provider):
    """Entries of the mod's index. An index that exists but cannot be parsed
    raises instead of reading as empty: writing it back would wipe the mod's list."""
    text = _read(provider.index).strip()
    if not text:
        return []
    try:
        data = json.loads(_json5_to_json(text))
    except ValueError as exc:
        raise BackupError("Cannot parse %s (%s); not touching it" % (provider.index, exc))
    if isinstance(data, dict):  # FTB Backups 2 writes {"backups": [...]} (or [] when empty)
        data = data.get("backups", [])
    return [entry for entry in data if isinstance(entry, dict)]


def write_index(provider, entries):
    provider.index.parent.mkdir(parents=True, exist_ok=True)
    payload = {"backups": entries} if provider.kind == "v2" else entries
    tmp = provider.index.with_name(provider.index.name + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2) + "\n")
    _chown(tmp)
    tmp.replace(provider.index)


def _entry_file(provider, entry):
    if provider.kind == "v2":
        return Path(entry.get("backupLocation", "")).name
    return entry.get("file", "")


# --------------------------------------------------------------------------
# Listing
# --------------------------------------------------------------------------
def _label_from_file(provider, filename, entry):
    if provider.kind == "v2":
        name = (entry or {}).get("backupName", "")
        return "" if name == "automated" else name
    stem = filename[:-4] if filename.endswith(".zip") else filename
    if V3_AUTO_RE.match(stem):
        return ""
    if V3_AUTO_RE.match(stem[:19]) and stem[19:20] == "_":
        return stem[20:]
    return stem


def list_backups(provider=None):
    provider = provider or detect()
    try:
        entries = {_entry_file(provider, e): e for e in read_index(provider)}
    except BackupError as exc:
        print("Warning: %s" % exc, file=sys.stderr)
        entries = {}
    backups = []
    if not provider.folder.is_dir():
        return backups
    for path in provider.folder.iterdir():
        name = path.name
        if name.startswith(".") or name.endswith((".json", ".json5", ".tmp")) or not NAME_RE.match(name):
            continue
        if not (name.endswith((".zip", ".tar.zst")) or (path.is_dir() and provider.kind == "v2")):
            continue
        entry = entries.get(name)
        st = path.stat()
        if entry:
            created = (entry.get("createTime") if provider.kind == "v2" else entry.get("time")) or st.st_mtime * 1000
            ok = entry.get("complete", True) if provider.kind == "v2" else entry.get("success", True)
        else:
            created, ok = st.st_mtime * 1000, True
        label = _label_from_file(provider, name, entry)
        backups.append({
            "name": name,
            "created": created / 1000,
            "size": st.st_size if path.is_file() else (entry or {}).get("size", 0),
            "label": label,
            "auto": not label,
            "protected": bool((entry or {}).get("snapshot")) if provider.kind == "v2" else False,
            "in_index": entry is not None,
            "complete": bool(ok),
            "format": "dir" if path.is_dir() else ("zst" if name.endswith(".tar.zst") else "zip"),
        })
    return sorted(backups, key=lambda b: b["created"], reverse=True)


def find(provider, name):
    if not NAME_RE.match(name or ""):
        raise BackupError("Unknown backup: %s" % name)
    for backup in list_backups(provider):
        if backup["name"] == name:
            return backup, provider.folder / name
    raise BackupError("Unknown backup: %s" % name)


# --------------------------------------------------------------------------
# Server helpers
# --------------------------------------------------------------------------
def server_active():
    return subprocess.run(["systemctl", "is-active", "-q", "minecraft"]).returncode == 0


def console(command):
    # Only ever write to the FIFO systemd provides while the server runs: a
    # plain open() would create a regular file, a blocking one could hang.
    try:
        if not stat.S_ISFIFO(os.stat(CONSOLE).st_mode):
            raise BackupError("%s is not the server console" % CONSOLE)
        fd = os.open(CONSOLE, os.O_WRONLY | os.O_NONBLOCK)
    except (FileNotFoundError, OSError) as exc:
        raise BackupError("Server console not available (is the server running?): %s" % exc)
    try:
        os.write(fd, (command + "\n").encode())
    finally:
        os.close(fd)


def journal_cursor():
    out = subprocess.run(["journalctl", "-u", "minecraft", "-n", "1", "--show-cursor", "-o", "cat", "--no-pager"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("-- cursor: "):
            return line[len("-- cursor: "):]
    return None


def wait_log(cursor, patterns, timeout):
    """Returns (index of the matching pattern, match) for the first server log line matching one of patterns."""
    deadline = time.monotonic() + timeout
    compiled = [re.compile(p) for p in patterns]
    while time.monotonic() < deadline:
        args = ["journalctl", "-u", "minecraft", "-o", "cat", "--no-pager"]
        args += ["--after-cursor", cursor] if cursor else ["-n", "200"]
        for line in subprocess.run(args, capture_output=True, text=True).stdout.splitlines():
            for index, pattern in enumerate(compiled):
                match = pattern.search(line)
                if match:
                    return index, match
        time.sleep(1)
    return None, None


def _chown(path):
    shutil.chown(path, SERVER_USER, SERVER_USER)


def _chown_tree(path):
    _chown(path)
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            os.lchown(os.path.join(root, name), *_server_ids())


def _server_ids():
    entry = pwd.getpwnam(SERVER_USER)
    return entry.pw_uid, entry.pw_gid


def lock():
    if os.environ.get("FTB_LOCK_HELD"):
        return None
    handle = LOCK_FILE.open("w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise BackupError("Another backup, restore or update is running")
    os.environ["FTB_LOCK_HELD"] = "1"
    return handle


# --------------------------------------------------------------------------
# Create
# --------------------------------------------------------------------------
def clean_label(label):
    label = re.sub(r"[^a-z0-9-]+", "-", (label or "").lower()).strip("-")
    return re.sub(r"-+", "-", label)[:32].strip("-")


def _file_name(provider, label, now):
    if provider.kind == "v2":
        # Same pattern as FTB Backups 2 (BackupHandler.genBackupFileName).
        return "%d-%d-%d_%d-%d-%d.zip" % (now.year, now.month, now.day, now.hour, now.minute, now.second)
    stem = now.strftime("%Y-%m-%d-%H-%M-%S")
    return "%s_%s.zip" % (stem, label) if label else stem + ".zip"


def _write_zip(provider, target):
    level = level_name()
    world = SERVER_DIR / level
    if not world.is_dir():
        raise BackupError("World folder %s does not exist (has the server been started yet?)" % world)
    tmp = target.with_name("." + target.name + ".partial")
    count = 0
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=5) as archive:
            for root, _, files in os.walk(world):
                for name in sorted(files):
                    if name == "session.lock" or name.endswith(".neoforge-tmp"):
                        continue
                    path = Path(root) / name
                    try:
                        archive.write(path, path.relative_to(SERVER_DIR).as_posix())
                        count += 1
                    except (FileNotFoundError, PermissionError) as exc:
                        print("skipped %s: %s" % (path, exc))
        tmp.replace(target)
    finally:
        tmp.unlink(missing_ok=True)
    _chown(target)
    return count


def _add_index_entry(provider, filename, label, count, protected, now):
    entries = read_index(provider)
    path = provider.folder / filename
    size = path.stat().st_size
    epoch_ms = int(now.timestamp() * 1000)
    if provider.kind == "v2":
        entries.append({
            "worldName": level_name(), "createTime": epoch_ms, "backupLocation": str(path),
            "size": size, "ratio": 1.0, "sha1": _sha1(path), "preview": "", "snapshot": protected,
            "backupName": label, "backupFormat": "ZIP", "complete": True,
        })
    else:
        index = max([e.get("index", 0) for e in entries] + [0]) + 1
        entries.append({
            "time": epoch_ms, "archival_plugin": "ftbbackups:zip", "file": filename, "world_name": level_name(),
            "index": index, "success": True, "size": size, "file_count": count,
        })
    write_index(provider, entries)


def _sha1(path):
    import hashlib
    digest = hashlib.sha1()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _create_via_mod(provider, label):
    cursor = journal_cursor()
    now = datetime.now()
    if provider.kind == "v3":
        name = now.strftime("%Y-%m-%d-%H-%M-%S") + ("_" + label if label else "")
        command = "ftbbackups3 start " + name
        patterns = [r"Created archive (\S+) from", r"Backup to (\S+) failed: (.*)", r"backup creation failed: (.*)",
                    r"already_running|already running"]
    else:
        command = "backup snapshot " + (label or "manual")
        patterns = [r"New backup created at (\S+) size", r"Unable to create backup, Reason: (.*)",
                    r"Failed to create backup(.*)", r"Skipping backup, (.*)"]
    print("Sending to %s: %s" % (provider.name, command))
    console(command)
    index, match = wait_log(cursor, patterns, MOD_TIMEOUT)
    if index is None:
        raise BackupError("%s did not report a finished backup within %d minutes" % (provider.name, MOD_TIMEOUT // 60))
    if index != 0:
        raise BackupError("%s: %s" % (provider.name, match.group(0)))
    name = Path(match.group(1)).name
    print("Backup created by %s: %s" % (provider.name, name))
    return name


def _create_direct(provider, label, protected):
    """Writes the archive and index entry in the provider's format ourselves."""
    provider.folder.mkdir(parents=True, exist_ok=True)
    _chown(provider.folder)
    now = datetime.now()
    filename = _file_name(provider, label, now)
    running = server_active()
    cursor = None
    if running:
        # Stop autosaving and flush everything, so the world on disk is consistent.
        cursor = journal_cursor()
        console("save-off")
        console("save-all flush")
        index, _ = wait_log(cursor, [r"Saved the (game|world)"], 180)
        if index is None:
            print("Warning: the server did not confirm the save, backing up anyway")
    try:
        print("Creating %s" % filename)
        count = _write_zip(provider, provider.folder / filename)
    finally:
        if running:
            console("save-on")
    _add_index_entry(provider, filename, label, count, protected, now)
    return filename


def create(label="", provider=None):
    provider = provider or detect()
    label = clean_label(label)
    if provider.mod_command and server_active():
        name = _create_via_mod(provider, label)
    else:
        # v2 marks our manual backups as snapshots, so the mod's rotation keeps them.
        name = _create_direct(provider, label, protected=provider.kind == "v2" and label not in AUTO_LABELS)
    prune(provider)
    path = provider.folder / name
    size = path.stat().st_size if path.is_file() else 0
    print("Backup created: %s (%.1f MB) in %s" % (name, size / 1048576, provider.folder))
    return name


def prune(provider):
    for label in AUTO_LABELS:
        old = [b for b in list_backups(provider) if b["label"] == label][AUTO_KEEP:]
        for backup in old:
            _delete(provider, backup["name"])


# --------------------------------------------------------------------------
# Restore / delete / import
# --------------------------------------------------------------------------
def _check_members(names):
    for name in names:
        parts = Path(name).parts
        if name.startswith("/") or ".." in parts or (parts and ":" in parts[0]):
            raise BackupError("Archive contains an unsafe path: %s" % name)


def _world_root(names):
    """Folder inside the archive that holds the world (the shallowest level.dat)."""
    candidates = sorted((n for n in names if n == "level.dat" or n.endswith("/level.dat")), key=lambda n: n.count("/"))
    if not candidates:
        raise BackupError("Archive contains no world (level.dat missing)")
    return candidates[0][: -len("level.dat")]


def restore(name, provider=None):
    provider = provider or detect()
    backup, path = find(provider, name)
    if backup["format"] == "zst":
        raise BackupError("tar.zst backups cannot be restored here; switch FTB Backups 2 to ZIP")
    if backup["format"] == "zip":
        with zipfile.ZipFile(path) as archive:
            names = [n for n in archive.namelist() if not n.endswith("/")]
    else:
        names = [p.relative_to(path).as_posix() for p in path.rglob("*") if p.is_file()]
    _check_members(names)
    root = _world_root(names)

    was_active = server_active()
    if was_active:
        print("Stopping server")
        subprocess.run(["systemctl", "stop", "minecraft"], check=True)
    print("Safety backup of the current world")
    try:
        create("pre-restore", provider)
    except BackupError as exc:
        print("Warning: no pre-restore backup: %s" % exc)

    level = level_name()
    world = SERVER_DIR / level
    staging = SERVER_DIR / (".restore-" + level)
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir()
    print("Restoring %s" % name)
    archive = zipfile.ZipFile(path) if backup["format"] == "zip" else None
    try:
        for member in names:
            if not member.startswith(root):
                continue  # extra files of the backup stay in the archive
            target = staging / member[len(root):]
            target.parent.mkdir(parents=True, exist_ok=True)
            if archive:
                with archive.open(member) as source, target.open("wb") as out:
                    shutil.copyfileobj(source, out, 1024 * 1024)
            else:
                shutil.copy2(path / member, target)
        _chown_tree(staging)
        old = SERVER_DIR / (".old-" + level)
        shutil.rmtree(old, ignore_errors=True)
        if world.exists():
            world.rename(old)
        staging.rename(world)
        shutil.rmtree(old, ignore_errors=True)
    finally:
        if archive:
            archive.close()
        shutil.rmtree(staging, ignore_errors=True)
    if was_active:
        print("Starting server")
        subprocess.run(["systemctl", "start", "minecraft"], check=True)
    print("Restored %s into %s" % (name, world))


def _delete(provider, name):
    path = provider.folder / name
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)
    entries = [e for e in read_index(provider) if _entry_file(provider, e) != name]
    write_index(provider, entries)
    print("Deleted %s" % name)


def delete(name, provider=None):
    provider = provider or detect()
    find(provider, name)
    _delete(provider, name)


def import_upload(staged, provider=None):
    provider = provider or detect()
    source = UPLOAD_DIR / staged
    if not NAME_RE.match(staged) or not source.is_file():
        raise BackupError("Unknown upload: %s" % staged)
    try:
        with zipfile.ZipFile(source) as archive:
            names = [n for n in archive.namelist() if not n.endswith("/")]
    except zipfile.BadZipFile:
        raise BackupError("Not a ZIP archive")
    _check_members(names)
    _world_root(names)
    provider.folder.mkdir(parents=True, exist_ok=True)
    _chown(provider.folder)
    now = datetime.now()
    name = staged if staged.endswith(".zip") and not (provider.folder / staged).exists() else _file_name(provider, "upload", now)
    shutil.move(str(source), provider.folder / name)
    _chown(provider.folder / name)
    _add_index_entry(provider, name, "upload" if provider.kind == "v2" else "", len(names), provider.kind == "v2", now)
    print("Imported as %s" % name)
    return name


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
USAGE = """Usage: ftb-backup <command>
  create [label]   back up the world (via the pack's FTB Backups mod when it runs)
  list             list backups
  restore <name>   restore a backup (after an automatic pre-restore backup)
  delete <name>    delete a backup
  import <file>    take over an upload from /opt/minecraft/.upload
  info             show which backup system the pack uses"""


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(USAGE)
        return 0 if argv else 1
    command, args = argv[0], argv[1:]
    try:
        provider = detect()
        if command == "info":
            print("%s: %s (index %s)" % (provider.name, provider.folder, provider.index))
        elif command == "list":
            for b in list_backups(provider):
                print("%s  %8.1f MB  %-12s %s" % (datetime.fromtimestamp(b["created"]).strftime("%Y-%m-%d %H:%M"),
                                                  b["size"] / 1048576, b["label"] or "(auto)", b["name"]))
        elif command in ("create", "restore", "delete", "import"):
            handle = lock()
            try:
                if command == "create":
                    create(args[0] if args else "", provider)
                elif not args:
                    raise BackupError("missing backup name")
                elif command == "restore":
                    restore(args[0], provider)
                elif command == "delete":
                    delete(args[0], provider)
                else:
                    import_upload(args[0], provider)
            finally:
                if handle:
                    handle.close()
        else:
            print(USAGE, file=sys.stderr)
            return 1
    except BackupError as exc:
        print("Error: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
