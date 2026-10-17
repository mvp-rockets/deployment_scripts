#!/usr/bin/env bash
# Unit tests for the deploy scripts that need no VM or AWS: pytest (the real scripts with aws,
# ssh, rsync, pm2, npm and curl stubbed), then shellcheck on the scripts they cover.
# Needs python3 with pytest (or uv), jq, git; shellcheck if installed.
#
#   test/unit/run.sh [pytest args]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
for tool in jq git; do
  command -v "$tool" >/dev/null || { echo "test/unit/run.sh: $tool is required" >&2; exit 1; }
done
if python3 -c 'import pytest' 2>/dev/null; then
  python3 -m pytest -q test/unit "$@"
elif command -v uvx >/dev/null; then
  uvx pytest -q test/unit "$@"
else
  echo "test/unit/run.sh: install pytest (pip install pytest) or uv" >&2
  exit 1
fi
if command -v shellcheck >/dev/null; then
  shellcheck -x secrets.sh remote/common/secrets_manifest.sh remote/current/init_api.sh remote/current/reload_secrets.sh
  echo "shellcheck: ok"
else
  echo "test/unit/run.sh: shellcheck not installed: skipped" >&2
fi
