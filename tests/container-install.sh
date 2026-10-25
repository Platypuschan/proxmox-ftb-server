#!/usr/bin/env bash
# End-to-end test of install/ftb-minecraft-install.sh in a Debian 13 systemd
# container (podman), standing in for the LXC the framework would create.
# Installs an older version of a pack, waits for the server to come up, sends
# a console command, runs the web GUI API checks, updates to the latest
# release and stops the server.
#
# Usage: tests/container-install.sh [pack-id] [v2|v3|own]   (default 128 = FTB OceanBlock 2, v2)
#   The second argument is the backup system the pack should use (FTB Backups 2/3 or own).
#   KEEP=1  leave the container running afterwards (web GUI on http://localhost:18080)
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pack="${1:-128}"
provider="${2:-v2}"
name="ftb-install-test-$$"
image="localhost/ftb-install-test:trixie"
api="https://api.feed-the-beast.com/v1/modpacks/public/modpack"


cleanup() {
  if [[ -n "${KEEP:-}" ]]; then
    echo "Container ${name} kept: http://localhost:18080"
  else
    podman rm -f "$name" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step() { printf '\n=== %s\n' "$*"; }
wait_done() {
  local since="$1" i
  for i in $(seq 1 120); do
    if podman exec "$name" journalctl -u minecraft --since "$since" -o cat --no-pager | grep 'Done (' >/dev/null; then
      podman exec "$name" journalctl -u minecraft --since "$since" -o cat --no-pager | grep 'Done ('
      return 0
    fi
    sleep 5
  done
  podman exec "$name" journalctl -u minecraft -n 60 -o cat --no-pager
  return 1
}

step "Versions of pack ${pack}"
mapfile -t releases < <(curl -fsSL "${api}/${pack}" | jq -r '[.versions[] | select(.type == "release")] | sort_by(.id) | reverse | .[0:2][] | .id')
latest="${releases[0]}"
older="${releases[1]:-${releases[0]}}"
echo "install ${older}, then update to ${latest}"

step "Build systemd test image"
podman build -q -t "$image" - <<'EOF'
FROM docker.io/library/debian:trixie
# Rootless podman with a short subuid range cannot map apt's _apt user (65534).
RUN echo 'APT::Sandbox::User "root";' >/etc/apt/apt.conf.d/99-test-sandbox \
 && apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
CMD ["/sbin/init"]
EOF
podman run -d --name "$name" --systemd=always -p 18080:8080 "$image" >/dev/null
sleep 3

# Minimal stand-in for the framework's lxc/install.func.
stub="$(cat <<'EOF'
STD=""
color() { :; }
verb_ip6() { :; }
catch_errors() { set -Eeuo pipefail; trap 'echo "ERROR line $LINENO: $BASH_COMMAND" >&2' ERR; }
setting_up_container() { :; }
network_check() { :; }
update_os() { apt-get update -qq; }
msg_info() { echo "  .. $*"; }
msg_ok() { echo "  OK $*"; }
msg_error() { echo "  ERR $*" >&2; }
motd_ssh() { :; }
# Like the framework's customize: writes the update entrypoint the install script must remove.
customize() { printf '#!/bin/sh\necho framework update\n' >/usr/bin/update; chmod +x /usr/bin/update; }
cleanup_lxc() { :; }
EOF
)"

step "Run install script"
start="$(podman exec "$name" date '+%Y-%m-%d %H:%M:%S')"
bundle="$(tar -C "$root" --exclude=__pycache__ -czf - files | base64 -w0)"
echo "files bundle: ${#bundle} bytes"
podman exec -e FUNCTIONS_FILE_PATH="$stub" -e FTB_PACK_ID="$pack" -e FTB_VERSION_ID="$older" \
  -e FTB_PACK_NAME="Test pack ${pack}" -e FTB_ACCEPT_EULA=yes -e FTB_RAM_RESERVE=1536 \
  -e FTB_FILES_BUNDLE="$bundle" \
  "$name" bash -c "$(cat "$root/install/ftb-minecraft-install.sh")"

step "Wait for server start"
wait_done "$start"
podman exec "$name" journalctl -u minecraft -o cat --no-pager | grep 'JVM heap set'

step "Ownership (files not owned by minecraft)"
foreign="$(podman exec "$name" find /opt/minecraft/server ! -user minecraft -print)"
echo "${foreign:-none}"
[[ -z "$foreign" ]]

step "Console command"
podman exec "$name" mc-cmd list

step "No in-container update command"
if podman exec "$name" test -e /usr/bin/update; then
  echo "/usr/bin/update still exists"
  exit 1
fi
echo "removed"

step "Web GUI API (includes the modpack update ${older} -> ${latest})"
podman exec -e EXPECT_PROVIDER="$provider" -e EXPECT_OLDER="$older" -e EXPECT_LATEST="$latest" \
  "$name" bash -c "$(cat "$root/tests/web-api-check.sh")"
podman exec "$name" ftb-backup list

step "Already up to date"
podman exec "$name" ftb-update

step "Graceful stop"
start="$(podman exec "$name" date '+%Y-%m-%d %H:%M:%S')"
podman exec "$name" systemctl stop minecraft
podman exec "$name" journalctl -u minecraft --since "$start" -o cat --no-pager | grep -E 'Stopping (the )?server|All dimensions are saved'
podman exec "$name" systemctl show minecraft -p Result -p ExecMainStatus
if [[ -n "${KEEP:-}" ]]; then
  podman exec "$name" systemctl start minecraft
fi
echo
echo "container install test passed"
