#!/system/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HTML="$ROOT/webroot/index.html"
CSS="$ROOT/webroot/css/style.css"
JS="$ROOT/webroot/js/main.js"
CUSTOMIZE="$ROOT/customize.sh"
HANDLER="$ROOT/scripts/web_handler.sh"
GATE="$ROOT/scripts/display_license_gate.sh"

require_text() {
    file="$1"
    text="$2"
    if ! grep -Fq "$text" "$file"; then
        echo "missing WebUI contract: $text" >&2
        exit 1
    fi
}

require_text "$HTML" 'id="payment-overlay"'
require_text "$HTML" 'id="payment-body"'
require_text "$HTML" 'id="payment-actions"'
require_text "$HTML" 'class="bottom-nav"'
require_text "$HTML" 'class="device-actions"'
require_text "$HTML" 'id="btn-save-global" class="fab-save"'
require_text "$HTML" '<img src="1000003559.png" alt=""'

require_text "$CSS" '.payment-sheet'
require_text "$CSS" '.app-mode-picker'
require_text "$CSS" '.app-mode-grid'
require_text "$CSS" 'backdrop-filter: blur(22px) saturate(175%)'
require_text "$CSS" '.bottom-nav::before'
require_text "$CSS" 'tab-indicator-index: 0'
require_text "$CSS" '.fab-save {'
require_text "$CSS" '.update-release-notes-body'

require_text "$JS" "product_code === 'display_oc_permanent'"
require_text "$JS" "order_kind: 'display_cardkey_new'"
require_text "$JS" "payment.php?action=create_order"
require_text "$JS" "payment.php?action=order_status"
require_text "$JS" 'function startPaymentPolling()'
require_text "$JS" 'function resumePendingPayment()'
require_text "$JS" "body.className = 'app-mode-picker'"
require_text "$JS" 'data-resolution="default"'
require_text "$JS" 'data-fps="-1"'
require_text "$JS" '付费组件更新日志'
require_text "$JS" 'result.paid.release_notes'
require_text "$JS" 'authState.package_version_code'
require_text "$JS" 'result.paid.version_code'
require_text "$JS" "deviceInfo?.device_model || ''"
require_text "$JS" "querySelectorAll('.video-memc-only')"

require_text "$CUSTOMIZE" 'auth_install_latest'
require_text "$CUSTOMIZE" '付费组件自动更新暂不可用，已保留现有组件并继续安装'
require_text "$HANDLER" 'install_latest_paid_package()'
require_text "$HANDLER" 'gate_lease_verify'
require_text "$HANDLER" 'require_premium game_assistant'
require_text "$HANDLER" 'gate_package_commit "$REMOTE_SHA" "$REMOTE_ID" "$REMOTE_VERSION" "$REMOTE_VERSION_CODE"'
require_text "$GATE" 'package_version_code='
require_text "$GATE" '_version_code="${4:-}"'
require_text "$GATE" 'video_memc game_assistant'

memc_group_count="$(grep -c 'class="group video-memc-only"' "$HTML")"
[ "$memc_group_count" = 2 ] || {
    echo "expected exactly two RMX5200-only MEMC groups, got $memc_group_count" >&2
    exit 1
}

if grep -Eq '购买说明|无内嵌支付|请前往.*App.*购买' "$JS"; then
    echo 'legacy external-purchase guide leaked into WebUI' >&2
    exit 1
fi

picker_body="$(sed -n '/async function openAppConfigDialog/,/^async function saveAppConfig/p' "$JS")"
if printf '%s\n' "$picker_body" | grep -q "type: 'select'"; then
    echo 'app refresh-rate picker regressed to native select' >&2
    exit 1
fi

app_list_css="$(sed -n '/^\.app-list {/,/^}/p' "$CSS")"
if ! printf '%s\n' "$app_list_css" | grep -Fq 'max-height: none;' ||
        ! printf '%s\n' "$app_list_css" | grep -Fq 'overflow: visible;'; then
    echo 'app list regressed to card-internal scrolling' >&2
    exit 1
fi

device_actions_line="$(grep -n 'class="device-actions"' "$HTML" | head -n 1 | cut -d: -f1)"
policy_line="$(grep -n 'id="policy-card"' "$HTML" | head -n 1 | cut -d: -f1)"
if [ -z "$device_actions_line" ] || [ -z "$policy_line" ] || [ "$device_actions_line" -ge "$policy_line" ]; then
    echo 'restore and uninstall actions must stay before the display policy' >&2
    exit 1
fi

if command -v node >/dev/null 2>&1; then
    node --check "$JS"
fi

echo 'paid WebUI contract checks passed'
