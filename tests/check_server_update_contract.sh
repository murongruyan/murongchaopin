#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HANDLER="$ROOT/scripts/web_handler.sh"
WORKFLOW="$ROOT/.github/workflows/build-module.yml"
WEB="$ROOT/webroot/js/main.js"

grep -Fq 'platform=display_module' "$HANDLER"
grep -Fq 'update_source=server' "$HANDLER"
grep -Fq 'response.data.latest_version' "$WEB"
grep -Fq 'remote.download_url' "$WEB"
grep -Fq 'remote.update_log' "$WEB"
grep -Fq '基础模块更新日志' "$WEB"

if grep -Eq 'BASE_UPDATE_(RELEASE|RAW)_JSON_URL' "$HANDLER"; then
    echo 'WebUI update checks must use the server API, not GitHub manifests' >&2
    exit 1
fi
if grep -Eq '^ *artifacts: .*update\.json|^ *update\.json$' "$WORKFLOW"; then
    echo 'GitHub Release must not be the WebUI update metadata source' >&2
    exit 1
fi

echo 'Server-backed update contracts passed'
