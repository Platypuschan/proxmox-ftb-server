#!/usr/bin/env bash
# Runs the host-side modpack selection of ct/ftb-minecraft.sh against the live
# FTB API, unattended, with the framework's message functions stubbed out.
set -Euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="$(mktemp)"
trap 'rm -f "$harness"' EXIT

{
  cat <<'EOF'
set -Eeo pipefail
msg_info() { echo "INFO $*"; }
msg_ok() { echo "OK $*"; }
msg_error() { echo "ERR $*"; }
exit_script() { echo "cancelled"; exit 2; }
FTB_API="https://api.feed-the-beast.com/v1/modpacks/public"
FTB_RAM_RESERVE=1536
var_ram="${var_ram:-}"
var_disk="${var_disk:-}"
EOF
  sed -n '/^ftb_json()/,/^}/p; /^ftb_fetch()/,/^}/p; /^ftb_select_pack()/,/^}/p' "$root/ct/ftb-minecraft.sh"
  cat <<'EOF'
ftb_select_pack </dev/null
echo "RESULT pack=$FTB_PACK_ID version=$FTB_VERSION_ID name=$FTB_PACK_NAME ram=$var_ram disk=$var_disk hostname=$var_hostname"
EOF
} >"$harness"

fail=0
check() {
  local want_rc="$1"
  shift
  local out rc
  out="$(env "$@" bash "$harness" 2>&1)"
  rc=$?
  printf '### %s (rc=%s, expected %s)\n%s\n' "$*" "$rc" "$want_rc" "$(tail -n 3 <<<"$out")"
  [[ "$rc" == "$want_rc" ]] || fail=1
}

check 0 FTB_PACK_ID=135                          # newest NeoForge pack
check 0 FTB_PACK_ID=35                           # Forge 1.12.2 / Java 8
check 0 FTB_PACK_ID=109                          # Fabric
check 0 FTB_PACK_ID=128 FTB_VERSION_ID=100482 var_ram=4096 var_hostname=mc1
check 1 FTB_PACK_ID=128 FTB_VERSION_ID=1         # foreign version id
check 1 FTB_PACK_ID=99999                        # unknown pack
check 1 FTB_PACK_ID=abc                          # not numeric
check 0 FTB_PACK_ID=128                                              # EULA is accepted automatically
exit "$fail"
