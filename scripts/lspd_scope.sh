#!/system/bin/sh
# Restore LSPosed module enablement and scope for the free/premium display
# hooks after a package reinstall (certificate swap). Idempotent; safe to run
# from customize.sh, the paid-package installer, or premium_service.sh.
FREE_PKG="com.murongchaopin.displayhook"
PREMIUM_PKG="com.murongchaopin.displayhook.premium"
LSPD_DB="/data/adb/lspd/config/modules_config.db"

SCRIPT_DIR=$(dirname "$0")
SQLITE_BIN=""
for candidate in \
  "$SCRIPT_DIR/../bin/sqlite3" \
  "/data/adb/modules/murongchaopin/bin/sqlite3"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    SQLITE_BIN="$candidate"
    break
  fi
done
[ -n "$SQLITE_BIN" ] || exit 0
[ -f "$LSPD_DB" ] || exit 0

scope_insert() {
  _pkg="$1"
  "$SQLITE_BIN" "$LSPD_DB" \
    "INSERT OR IGNORE INTO modules_state(module_pkg_name,user_id,enabled,scope_request_blocked) VALUES('$_pkg',0,1,0); UPDATE modules_state SET enabled=1,scope_request_blocked=0 WHERE module_pkg_name='$_pkg' AND user_id=0;" \
    >/dev/null 2>&1 || true
}

if pm path "$FREE_PKG" >/dev/null 2>&1; then
  scope_insert "$FREE_PKG"
  for _app in system me.weishu.kernelsu com.android.systemui; do
    "$SQLITE_BIN" "$LSPD_DB" \
      "INSERT OR IGNORE INTO scope(module_pkg_name,app_pkg_name,user_id) VALUES('$FREE_PKG','$_app',0);" \
      >/dev/null 2>&1 || true
  done
fi

if pm path "$PREMIUM_PKG" >/dev/null 2>&1; then
  scope_insert "$PREMIUM_PKG"
  for _app in system com.android.settings com.oplus.games com.omarea.vtools com.coloros.video; do
    "$SQLITE_BIN" "$LSPD_DB" \
      "INSERT OR IGNORE INTO scope(module_pkg_name,app_pkg_name,user_id) VALUES('$PREMIUM_PKG','$_app',0);" \
      >/dev/null 2>&1 || true
  done
fi

exit 0
