#!/usr/bin/env bash
# Static checks: bash syntax + shellcheck, Python compile + pyflakes (if
# installed), JavaScript syntax (if node is installed), MANIFEST completeness.
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

shell_files=(ct/*.sh install/*.sh tests/*.sh files/bin/ftb-heap files/bin/ftb-install-pack files/bin/ftb-start files/bin/ftb-update files/bin/mc-cmd)
for f in "${shell_files[@]}"; do
  bash -n "$f"
done
# SC1090/SC1091: framework and env files are sourced at runtime.
# SC2034: var_* settings are read by the sourced framework.
shellcheck -s bash -e SC1090,SC1091,SC2034 "${shell_files[@]}"

python_files=(files/web/ftb-web.py files/lib/ftb_backup.py files/bin/ftb-backup tests/index-parse.py tests/job-filter.py)
for f in "${python_files[@]}"; do
  python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f"
done
if python3 -m pyflakes --version >/dev/null 2>&1; then
  python3 -m pyflakes "${python_files[@]}"
fi
if command -v node >/dev/null; then
  node --check files/web/static/app.js
fi

python3 -B tests/index-parse.py >/dev/null
python3 -B tests/job-filter.py >/dev/null

# Every file under files/ is listed in MANIFEST and vice versa.
diff <(grep -vE '^(#|$)' files/MANIFEST | sort) \
  <(cd files && find . -type f ! -name MANIFEST ! -path '*/__pycache__/*' | sed 's|^\./||' | sort)

echo "lint ok"
