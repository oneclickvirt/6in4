#!/usr/bin/env bash
# Compatibility wrapper for the historical back/6in4.sh entry.

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
ROOT_SCRIPT="${SCRIPT_DIR}/../6in4.sh"

if [ -x "$ROOT_SCRIPT" ]; then
    exec "$ROOT_SCRIPT" "$@"
fi

tmp_script=$(mktemp /tmp/6in4.XXXXXX.sh)
trap 'rm -f "$tmp_script"' EXIT
curl -fsSL https://raw.githubusercontent.com/oneclickvirt/6in4/main/6in4.sh -o "$tmp_script"
chmod +x "$tmp_script"
exec "$tmp_script" "$@"
