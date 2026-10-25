"""Checks the folding of modloader installer output in files/web/ftb-web.py job output."""
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("ftb_web", Path(__file__).resolve().parent.parent / "files" / "web" / "ftb-web.py")
ftb_web = importlib.util.module_from_spec(spec)
sys.modules["ftb_backup"] = type(sys)("ftb_backup")  # the web module only needs it at runtime
sys.modules["ftb_backup"].SERVER_DIR = Path("/nonexistent")
sys.modules["ftb_backup"].UPLOAD_DIR = Path("/nonexistent")
spec.loader.exec_module(ftb_web)

ERRORS = [
    "java.lang.RuntimeException: boom",
    "Exception in thread \"main\" java.io.IOException: disk full",
    "Caused by: java.net.UnknownHostException: maven.neoforged.net",
    "ERROR: could not patch",
    "Download failed: libraries/x.jar",
]
NOISE = [
    "Can't Find Class: com/mojang/serialization/DataResult$Error",
    "Can't Find Class: org/apache/commons/lang3/exception/ExceptionUtils",
    "Considering library com.google.guava:failureaccess:1.0.1",
    "Considering library com.google.errorprone:error_prone_annotations:2.18.0",
    "File ./libraries/com/machinezoo/noexception/noexception/1.7.1/noexception-1.7.1.jar exists. Checksum valid.",
    "  net/minecraft/ReportedException.class",
    "Processing entries",
]
failed = False
for line in ERRORS:
    ok = bool(ftb_web.LOADER_ERROR_RE.search(line))
    failed |= not ok
    print("%s  error shown:  %s" % ("ok  " if ok else "FAIL", line))
for line in NOISE:
    ok = not ftb_web.LOADER_ERROR_RE.search(line)
    failed |= not ok
    print("%s  noise hidden: %s" % ("ok  " if ok else "FAIL", line))
for start in ("INFO: Running NeoForge installer", "INFO: Running Forge installer", "INFO: Running Fabric installer"):
    ok = bool(ftb_web.LOADER_BLOCK_START_RE.match(start))
    failed |= not ok
    print("%s  block start:  %s" % ("ok  " if ok else "FAIL", start))
sys.exit(1 if failed else 0)
