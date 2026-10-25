#!/usr/bin/env bash
# Exercises the web GUI API from inside the container (run as root there).
# EXPECT_PROVIDER: v2 | v3 | own - the backup system the pack should use.
set -Eeuo pipefail
base="http://127.0.0.1:${FTB_WEB_PORT:-8080}"
expect_provider="${EXPECT_PROVIDER:?v2, v3 or own}"
server=/opt/minecraft/server
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

api() { curl -s "$@"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
ok() { echo "ok    $*"; }
fail() {
  echo "FAIL  $*"
  exit 1
}
expect() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
check() {
  local what="$1"
  shift
  if "$@"; then ok "$what"; else fail "$what"; fi
}
backups() { api "$base/api/backups"; }
index_has() { grep -F "$1" "$index" >/dev/null; }
index_lacks() { ! grep -F "$1" "$index" >/dev/null; }
log_has() { journalctl -u minecraft -o cat --no-pager | grep -E "$1" >/dev/null; }
has_label() { backups | jq -e --arg l "$1" '.backups[] | select(.label == $l)' >/dev/null; }

# Waits for the job with id $2 and checks its final state.
wait_job() {
  local what="$1" id="$2" want="${3:-done}" job state i
  for ((i = 0; i < 600; i++)); do
    job="$(api "$base/api/job")"
    state="$(jq -r 'select(.id == "'"$id"'") | .state' <<<"$job")"
    [[ -n "$state" && "$state" != "running" ]] && break
    sleep 2
  done
  jq -r '.output[]' <<<"$job" | tail -n 4 | sed 's/^/        /'
  expect "$what" "$state" "$want"
}

wait_ping() {
  local i
  for ((i = 0; i < 120; i++)); do
    [[ "$(api "$base/api/status" | jq -r '.ping != null')" == "true" ]] && return 0
    sleep 5
  done
  fail "server did not answer the status ping"
}

start_job() {
  local response
  response="$(api "$@")"
  jq -r '.id // empty' <<<"$response" | grep . || fail "no job started: ${response}"
}

# Triggers a backup through the mod itself and waits until it is listed as complete.
mod_backup() {
  local before i
  before="$(backups | jq '.backups | length')"
  if [[ "$expect_provider" == v3 ]]; then mc-cmd ftbbackups3 start >/dev/null; else mc-cmd backup start >/dev/null; fi
  for ((i = 0; i < 150; i++)); do
    if [[ "$(backups | jq '.backups | length')" -gt "$before" && "$(backups | jq -r '.backups[0].complete')" == true ]]; then
      return 0
    fi
    sleep 2
  done
  fail "the mod did not finish a backup"
}

echo "--- basics"
expect "static page" "$(code "$base/")" 200
expect "no login needed" "$(code "$base/api/status")" 200
expect "unknown API path" "$(code "$base/api/nope")" 404

echo "--- status"
wait_ping
status="$(api "$base/api/status")"
jq -c '{state: .service.active, version: .ping.version, players: "\(.ping.online)/\(.ping.max)", memory: .service.memory, pack: .pack.name}' <<<"$status"
expect "service active" "$(jq -r .service.active <<<"$status")" active
check "ping reports max players" test "$(jq -r '.ping.max' <<<"$status")" -gt 0

echo "--- console"
expect "console command" "$(code -X POST "$base/api/console" -d '{"command":"say web-gui-test"}')" 200
sleep 2
check "command visible in log" log_has 'web-gui-test'

echo "--- backup system"
info="$(backups)"
jq -c '.provider' <<<"$info"
expect "provider" "$(jq -r .provider.kind <<<"$info")" "$expect_provider"
folder="$(jq -r .provider.folder <<<"$info")"
index="$(jq -r .provider.index <<<"$info")"

echo "--- backup while running"
id="$(start_job -X POST "$base/api/backups" -d '{"label":"API Test!"}')"
wait_job "backup created" "$id"
name="$(backups | jq -r '.backups[] | select(.label == "api-test") | .name' | head -n 1)"
[[ -n "$name" ]] || fail "backup with label api-test not listed"
ok "listed as ${name}"
check "archive in the mod's folder ${folder}" test -f "$folder/$name"
check "entry in the mod's index $(basename "$index")" index_has "$name"
python3 - "$folder/$name" <<'EOF' || fail "archive does not hold world/ like FTB Backups"
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
assert names and all(n.startswith("world/") for n in names), names[:5]
assert "world/level.dat" in names
EOF
ok "archive holds world/ like FTB Backups"
if [[ "$expect_provider" != "own" ]]; then
  check "backup was made by the mod" log_has 'Created archive|New backup created'
fi
expect "archive owner (mod can rotate it)" "$(stat -c %U "$folder/$name")" minecraft
expect "busy while job runs" "$(
  id2="$(start_job -X POST "$base/api/backups" -d '{}')"
  code -X POST "$base/api/backups" -d '{}'
  wait_job "second backup" "$id2" >/dev/null
)" 409

if [[ "$expect_provider" != "own" ]]; then
  echo "--- automatic backup of the mod shows up"
  mod_backup
  expect "mod backup listed as automatic" "$(backups | jq -r '.backups[0].auto')" true
fi

echo "--- download / delete / upload"
size="$(backups | jq -r --arg n "$name" '.backups[] | select(.name == $n) | .size')"
api -o "$work/$name" "$base/api/backups/$name/download"
expect "download size" "$(stat -c %s "$work/$name")" "$size"
id="$(start_job -X DELETE "$base/api/backups/$name")"
wait_job "backup deleted" "$id"
expect "deleted backup gone" "$(code "$base/api/backups/$name/download")" 404
check "removed from index" index_lacks "$name"
id="$(start_job -X PUT -H "X-Filename: $name" --data-binary "@$work/$name" "$base/api/backups/upload")"
wait_job "backup uploaded" "$id"
expect "uploaded backup keeps its name" "$(code "$base/api/backups/$name/download")" 200
check "upload added to index" index_has "$name"

python3 - "$work/evil.zip" "$work/noworld.zip" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("world/level.dat", b"x")
    z.writestr("world/../../evil", b"pwned")
with zipfile.ZipFile(sys.argv[2], "w") as z:
    z.writestr("readme.txt", b"no world here")
EOF
id="$(start_job -X PUT -H "X-Filename: evil.zip" --data-binary "@$work/evil.zip" "$base/api/backups/upload")"
wait_job "archive with ../ rejected" "$id" failed
id="$(start_job -X PUT -H "X-Filename: noworld.zip" --data-binary "@$work/noworld.zip" "$base/api/backups/upload")"
wait_job "archive without world rejected" "$id" failed

echo "--- restore"
touch "$server/world/after-backup.marker"
id="$(start_job -X POST "$base/api/backups/$name/restore")"
wait_job "backup restored" "$id"
check "world from before the backup is back" test ! -e "$server/world/after-backup.marker"
check "pre-restore backup created" has_label pre-restore
expect "owner after restore" "$(stat -c %U "$server/world/level.dat")" minecraft
wait_ping
ok "server running again after restore"

echo "--- stop, backup while stopped, start"
id="$(start_job -X POST "$base/api/server/stop")"
wait_job "server stopped" "$id"
expect "service inactive" "$(api "$base/api/status" | jq -r .service.active)" inactive
expect "console refused while stopped" "$(code -X POST "$base/api/console" -d '{"command":"list"}')" 400
check "no stray file in place of the console FIFO" test ! -f /run/minecraft.stdin
id="$(start_job -X POST "$base/api/backups" -d '{"label":"offline"}')"
wait_job "backup while stopped" "$id"
offline="$(backups | jq -r '.backups[] | select(.label == "offline") | .name')"
check "offline backup ${offline} in index" index_has "$offline"
id="$(start_job -X POST "$base/api/server/start")"
wait_job "server started" "$id"
wait_ping
if [[ "$expect_provider" != "own" ]]; then
  # The mod rewrites its index from what it loaded at start: our entry must survive that.
  mod_backup
  check "mod kept the offline backup in its index after its own backup" index_has "$offline"
fi

if [[ -n "${EXPECT_OLDER:-}" && -n "${EXPECT_LATEST:-}" && "$EXPECT_OLDER" != "$EXPECT_LATEST" ]]; then
  echo "--- modpack update via the GUI"
  info="$(api "$base/api/modpack")"
  jq -c '{current: .current.name, latest: .latest.name, update_available}' <<<"$info"
  expect "installed version" "$(jq -r .current.id <<<"$info")" "$EXPECT_OLDER"
  expect "latest release offered" "$(jq -r .latest.id <<<"$info")" "$EXPECT_LATEST"
  expect "update available" "$(jq -r .update_available <<<"$info")" true
  expect "unknown version rejected" "$(code -X POST "$base/api/modpack/update" -d '{"version_id": 1}')" 400
  id="$(start_job -X POST "$base/api/modpack/update" -d "{\"version_id\": $EXPECT_LATEST}")"
  wait_job "modpack updated" "$id"
  info="$(api "$base/api/modpack")"
  expect "installed version after update" "$(jq -r .current.id <<<"$info")" "$EXPECT_LATEST"
  expect "no update offered any more" "$(jq -r .update_available <<<"$info")" false
  check "pre-update backup of the world" has_label pre-update
  progress_lines="$(api "$base/api/job" | jq '[.output[] | select(startswith("Downloading"))] | length')"
  check "installer progress collapsed to one line (${progress_lines})" test "$progress_lines" -le 1
  wait_ping
  ok "server running after the modpack update"
fi

echo "web API check passed"
