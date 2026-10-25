"""Unit checks for the index reader in files/lib/ftb_backup.py (no server needed)."""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "files" / "lib"))
import ftb_backup  # noqa: E402

CASES = {
    "plain JSON array (FTB Backups 3, quoted keys)":
        ('[{"time": 1, "file": "2026-10-25-09-30-00.zip", "success": true}]', 1),
    "JSON5: unquoted keys, single quotes, comments, trailing commas":
        ("// index\n[\n  {time: 1, file: '2026-10-25-09-30-00_a.zip', world_name: 'it\\'s: x', success: true,},\n"
         "  /* second */ {time: 2, file: \"b:c.zip\", success: false},\n]", 2),
    "FTB Backups 2 object": ('{"backups": [{"backupLocation": "/s/backups/2026-1-2_3-4-5.zip"}]}', 1),
    "FTB Backups 2 empty list": ("[]", 0),
    "empty file": ("", 0),
}

failed = False
with tempfile.TemporaryDirectory() as tmp:
    index = Path(tmp) / "backups.json5"
    provider = ftb_backup.Provider("v3", "test", Path(tmp), index, False)
    for name, (text, count) in CASES.items():
        index.write_text(text)
        entries = ftb_backup.read_index(provider)
        ok = len(entries) == count
        failed |= not ok
        print("%s  %s -> %d entries" % ("ok  " if ok else "FAIL", name, len(entries)))
    index.write_text('[{"time": 1, file: "x.zip"')  # truncated
    try:
        ftb_backup.read_index(provider)
        print("FAIL  broken index must raise")
        failed = True
    except ftb_backup.BackupError:
        print("ok    broken index raises instead of reading as empty")
    entries = json.loads(ftb_backup._json5_to_json("[{world_name: 'it\\'s: x'}]"))
    ok = entries == [{"world_name": "it's: x"}]
    failed |= not ok
    print("%s  string content stays intact: %s" % ("ok  " if ok else "FAIL", entries))
sys.exit(1 if failed else 0)
