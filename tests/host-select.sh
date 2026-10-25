#!/usr/bin/env bash
# Runs the modpack selection and container sizing of ct/ftb-minecraft.sh
# against the live FTB API, unattended (pvesh comes from tests/pve-stub).
set -Euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$root/tests/pve-stub:$PATH" PVE_STUB_STATE="$work/state"
mkdir -p "$PVE_STUB_STATE"

{
  cat <<'EOF'
set -Eeuo pipefail
FTB_API="https://api.feed-the-beast.com/v1/modpacks/public"
FTB_RAM_RESERVE=1536
FTB_UNATTENDED=1
C_OK="" C_ERR="" C_WARN="" C_DIM="" C_BOLD="" C_OFF=""
EOF
  printf 'WORK_DIR=%q\n' "$work"
  sed -n '/^msg_info()/p; /^msg_ok()/p; /^msg_warn()/p; /^msg_error()/p; /^die()/,/^}/p; /^interactive()/,/^}/p;
    /^ftb_json()/,/^}/p; /^ftb_fetch()/,/^}/p; /^ftb_select_pack()/,/^}/p; /^default_settings()/,/^}/p' "$root/ct/ftb-minecraft.sh"
  cat <<'EOF'
ftb_select_pack </dev/null
default_settings
echo "RESULT pack=$FTB_PACK_ID version=$FTB_VERSION_ID name=$FTB_PACK_NAME eula=$FTB_ACCEPT_EULA ctid=$CTID ram=$CT_RAM disk=$CT_DISK hostname=$CT_HOSTNAME"
EOF
} >"$work/harness.sh"

fail=0
check() {
  local want_rc="$1"
  shift
  local out rc
  out="$(env "$@" bash "$work/harness.sh" 2>&1)"
  rc=$?
  printf '### %s (rc=%s, expected %s)\n%s\n' "$*" "$rc" "$want_rc" "$(tail -n 2 <<<"$out")"
  [[ "$rc" == "$want_rc" ]] || fail=1
}

check 0 FTB_PACK_ID=135                          # newest NeoForge pack (MC 26.1)
check 0 FTB_PACK_ID=35                           # Forge 1.12.2 / Java 8
check 0 FTB_PACK_ID=109                          # Fabric
check 0 FTB_PACK_ID=128 FTB_VERSION_ID=100482 var_ram=4096 var_hostname=mc1 var_ctid=150
check 3 FTB_PACK_ID=128 FTB_VERSION_ID=1         # foreign version id
check 3 FTB_PACK_ID=99999                        # unknown pack
check 3 FTB_PACK_ID=abc                          # not numeric
check 3                                          # no pack id and no terminal
exit "$fail"
