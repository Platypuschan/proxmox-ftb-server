#!/usr/bin/env bash
# Static checks: bash syntax + shellcheck, Python syntax + pyflakes (if
# installed), JavaScript syntax (if node is installed), unit checks, and that
# nothing shipped depends on the community-scripts infrastructure.
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

shell_files=(ct/*.sh install/*.sh tests/*.sh tests/pve-stub/*
  files/bin/ftb-heap files/bin/ftb-install-pack files/bin/ftb-start files/bin/ftb-update files/bin/mc-cmd)
for f in "${shell_files[@]}"; do
  bash -n "$f"
done
# SC1091: /opt/minecraft/ftb-pack.env only exists inside the container.
shellcheck -s bash -e SC1091 "${shell_files[@]}"

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

# Standalone: no runtime reference to the community-scripts infrastructure.
if grep -rnE 'community-scripts|raw\.githubusercontent\.com|build\.func|install\.func' ct install files; then
  echo "community-scripts reference found in shipped files" >&2
  exit 1
fi

echo "lint ok"
