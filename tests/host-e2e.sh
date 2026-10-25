#!/usr/bin/env bash
# End-to-end test of ct/ftb-minecraft.sh as it runs on a Proxmox host, with the
# Proxmox tools replaced by the stubs in tests/pve-stub (containers become
# podman containers with Debian 13 + systemd, standing in for LXC).
#
#   A  unattended run: older pack version, then the web GUI API check
#      (incl. the modpack update via the GUI) and a clean stop
#   B  interactive run through every dialog ("Erweitert": static IP, VLAN,
#      password, second storage), full install
#   C  failures before creation: no container may be created
#   D  failure after creation: container is kept and reported
#
# Usage: tests/host-e2e.sh [pack-id] [v2|v3|own] [interactive-pack-id]
#        (defaults: 128 v2 35; scenario B is skipped with SKIP_INTERACTIVE=1)
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pack="${1:-128}"
provider="${2:-v2}"
pack_b="${3:-35}"
api="https://api.feed-the-beast.com/v1/modpacks/public/modpack"
image="localhost/ftb-pve-stub:trixie"

work="$(mktemp -d)"
export PVE_STUB_STATE="$work/state" PVE_STUB_IMAGE="$image" PVE_STUB_WEB_PORT=18080
export PVE_STUB_WHIPTAIL="$work/answers" FTB_LOG_DIR="$work/logs"
export PATH="$root/tests/pve-stub:$PATH"
mkdir -p "$PVE_STUB_STATE"

cleanup() {
  podman ps -a --format '{{.Names}}' | grep '^ftb-pve-' | xargs -r podman rm -f >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

step() { printf '\n=== %s\n' "$*"; }
ok() { echo "ok    $*"; }
fail() {
  echo "FAIL  $*"
  exit 1
}
expect() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
arg_after() { grep -A1 -x -- "$2" "$PVE_STUB_STATE/$1.args" | tail -n 1; }
in_ct() { podman exec "ftb-pve-$1" "${@:2}"; }

wait_done() {
  local ct="$1" i
  for ((i = 0; i < 120; i++)); do
    in_ct "$ct" journalctl -u minecraft -o cat --no-pager | grep 'Done (' >/dev/null && return 0
    sleep 5
  done
  in_ct "$ct" journalctl -u minecraft -n 40 -o cat --no-pager
  fail "server in container ${ct} did not reach 'Done'"
}

step "Build the stand-in for the Debian 13 template"
podman build -q -t "$image" - <<'EOF' >/dev/null
FROM docker.io/library/debian:trixie
# Rootless podman with a short subuid range cannot map apt's _apt user (65534).
RUN echo 'APT::Sandbox::User "root";' >/etc/apt/apt.conf.d/99-test-sandbox \
 && apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus iproute2 \
 && rm -rf /var/lib/apt/lists/*
CMD ["/sbin/init"]
EOF
ok "image ${image}"

mapfile -t releases < <(curl -fsSL "${api}/${pack}" | jq -r '[.versions[] | select(.type == "release")] | sort_by(.id) | reverse | .[0:2][] | .id')
latest="${releases[0]}"
older="${releases[1]:-${releases[0]}}"

step "C: failures before any container exists"
set +e
out="$(FTB_UNATTENDED=1 FTB_PACK_ID=abc bash "$root/ct/ftb-minecraft.sh" </dev/null 2>&1)"
rc=$?
set -e
expect "non-numeric pack id rejected (exit 3)" "$rc" 3
grep -q 'FTB_PACK_ID muss eine Zahl sein' <<<"$out" || fail "clear message"
ok "clear message"
set +e
FTB_UNATTENDED=1 FTB_PACK_ID="$pack" var_ram=1024 bash "$root/ct/ftb-minecraft.sh" </dev/null >/dev/null 2>&1
rc=$?
FTB_UNATTENDED=1 FTB_PACK_ID="$pack" var_container_storage=offline-nfs bash "$root/ct/ftb-minecraft.sh" </dev/null >"$work/c3" 2>&1
rc3=$?
set -e
expect "too little RAM rejected" "$rc" 3
expect "inactive storage rejected" "$rc3" 3
grep -q 'offline-nfs ist nicht aktiv' "$work/c3" || fail "storage message"
ok "storage message"
expect "no container created" "$(find "$PVE_STUB_STATE" -name '*.args' | wc -l)" 0
[[ ! -f "$PVE_STUB_STATE/downloads" ]] || fail "template not downloaded yet"
ok "template not downloaded yet"

step "A: unattended run (pack ${pack}, version ${older})"
FTB_UNATTENDED=1 FTB_PACK_ID="$pack" FTB_VERSION_ID="$older" bash "$root/ct/ftb-minecraft.sh" </dev/null | tee "$work/a.out"
ct=9100
expect "template downloaded once" "$(cat "$PVE_STUB_STATE/downloads")" "debian-13-standard_13.1-2_amd64.tar.zst"
expect "template" "$(head -n 1 "$PVE_STUB_STATE/$ct.args")" "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
expect "rootfs on local-lvm" "$(arg_after $ct --rootfs | cut -d: -f1)" local-lvm
expect "net0 dhcp" "$(arg_after $ct --net0)" "name=eth0,bridge=vmbr0,ip=dhcp"
expect "unprivileged" "$(arg_after $ct --unprivileged)" 1
expect "nesting" "$(arg_after $ct --features)" "nesting=1"
expect "timezone" "$(arg_after $ct --timezone)" host
expect "onboot" "$(arg_after $ct --onboot)" 1
grep -qx -- '--password' "$PVE_STUB_STATE/$ct.args" && fail "password set although none was given"
ok "no root password"
grep -q "Web-Oberfläche" "$PVE_STUB_STATE/$ct.description" || fail "Proxmox notes written"
ok "Proxmox notes written"
grep -q "http://.*:8080" "$work/a.out" || fail "final output shows the web GUI URL"
ok "final output shows the web GUI URL"
check_ct() {
  local ct="$1" autologin="$2"
  if in_ct "$ct" test -e /usr/bin/update; then fail "/usr/bin/update exists"; fi
  ok "no /usr/bin/update"
  if in_ct "$ct" test -e /root/ftb-setup; then fail "setup files left behind"; fi
  ok "setup files removed"
  expect "services active" "$(in_ct "$ct" systemctl is-active minecraft ftb-web | tr '\n' ' ')" "active active "
  if [[ "$autologin" == yes ]]; then
    in_ct "$ct" grep -q -- '--autologin root' /etc/systemd/system/container-getty@1.service.d/autologin.conf || fail "console autologin"
    ok "console autologin"
  else
    if in_ct "$ct" test -e /etc/systemd/system/container-getty@1.service.d/autologin.conf; then fail "autologin despite password"; fi
    ok "no autologin (password set)"
  fi
  in_ct "$ct" bash -lc 'true' 2>&1 | grep 'Web-Oberfläche: http://' >/dev/null || fail "login banner"
  ok "login banner"
}
check_ct "$ct" yes
wait_done "$ct"
ok "server up"

step "A: web GUI API (includes the modpack update ${older} -> ${latest})"
podman exec -e EXPECT_PROVIDER="$provider" -e EXPECT_OLDER="$older" -e EXPECT_LATEST="$latest" \
  "ftb-pve-$ct" bash -c "$(cat "$root/tests/web-api-check.sh")"

step "A: clean stop"
in_ct "$ct" systemctl stop minecraft
in_ct "$ct" journalctl -u minecraft -o cat --no-pager | grep 'All dimensions are saved' >/dev/null || fail "world saved on stop"
ok "world saved on stop"
expect "stop result" "$(in_ct "$ct" systemctl show minecraft -p Result --value)" success
pct destroy "$ct" --purge

if [[ -z "${SKIP_INTERACTIVE:-}" ]]; then
  step "B: interactive run through all dialogs (pack ${pack_b})"
  key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnlyForTests test@example"
  cat >"$PVE_STUB_WHIPTAIL" <<EOF
ok ${pack_b}
ok
ok advanced
ok 9200
ok mc-test
ok 2
ok 4096
ok 20
ok fast-ssd
ok vmbr1
ok 192.0.2.50/24
ok 192.0.2.1
ok 30
ok secret-test-pw
ok ${key}
no
yes
EOF
  # The version dialog answers "ok" with no value = keep the preselected latest release.
  sed -i '2s/.*/ok LATEST/' "$PVE_STUB_WHIPTAIL"
  latest_b="$(curl -fsSL "${api}/${pack_b}" | jq -r '[.versions[] | select(.type == "release")] | max_by(.id) | .id')"
  sed -i "2s/LATEST/${latest_b}/" "$PVE_STUB_WHIPTAIL"
  PVE_STUB_EXTRA_STORAGE=fast-ssd PVE_STUB_WEB_PORT=18081 \
    script -qec "bash '$root/ct/ftb-minecraft.sh'" /dev/null | tee "$work/b.out"
  ct=9200
  expect "all answers used" "$(wc -l <"$PVE_STUB_WHIPTAIL")" 0
  cat "$PVE_STUB_STATE/whiptail.log"
  expect "hostname" "$(arg_after $ct --hostname)" mc-test
  expect "cores" "$(arg_after $ct --cores)" 2
  expect "memory" "$(arg_after $ct --memory)" 4096
  expect "rootfs" "$(arg_after $ct --rootfs)" fast-ssd:20
  expect "net0 static with gateway and VLAN" "$(arg_after $ct --net0)" "name=eth0,bridge=vmbr1,ip=192.0.2.50/24,gw=192.0.2.1,tag=30"
  expect "password" "$(arg_after $ct --password)" secret-test-pw
  expect "onboot off" "$(arg_after $ct --onboot)" 0
  [[ -n "$(arg_after $ct --ssh-public-keys)" ]] || fail "ssh key passed to pct create"
  ok "ssh key passed to pct create"
  check_ct "$ct" no
  wait_done "$ct"
  ok "server up"
  pct destroy "$ct" --purge
fi

step "D: failure after creation keeps the container"
set +e
PVE_STUB_FAIL_PUSH=1 FTB_UNATTENDED=1 FTB_PACK_ID="$pack" bash "$root/ct/ftb-minecraft.sh" </dev/null >"$work/d.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "run failed (exit ${rc})"
ok "run failed (exit ${rc})"
grep -q 'bleibt zur Fehlersuche bestehen' "$work/d.out" || fail "container kept with a hint"
ok "container kept with a hint"
grep -q 'Vollständiges Log' "$work/d.out" || fail "log file named"
ok "log file named"
podman ps -a --format '{{.Names}}' | grep '^ftb-pve-9100$' >/dev/null || fail "container still exists"
ok "container still exists"

echo
echo "host e2e test passed"
