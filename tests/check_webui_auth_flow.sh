#!/usr/bin/env bash
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JS="$ROOT/webroot/js/main.js"
HANDLER="$ROOT/scripts/web_handler.sh"

grep -Fq 'let leaseRefreshPromise = null;' "$JS"
grep -Fq 'if (leaseRefreshPromise) return leaseRefreshPromise;' "$JS"
grep -Fq 'post-login authorization sync failed' "$JS"
grep -Fq "showToast('登录成功，但授权同步失败：' + e.message)" "$JS"
grep -Fq 'function persistAuthToken(token)' "$JS"
grep -Fq "resp.headers.get('X-Refresh-Token')" "$JS"
grep -Fq "proxied.refresh_token" "$JS"
grep -Fq "handlerCmd('auth_update_token', authToken)" "$JS"
grep -Fq 'auth_update_token' "$HANDLER"
grep -Fq 'X-Refresh-Token' "$HANDLER"

node - "$JS" <<'NODE'
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(process.argv[2], 'utf8').replace(/\r\n/g, '\n');
const start = source.indexOf('async function ksuExec(');
const end = source.indexOf('// ============================================================\n// 工具函数', start);
if (start < 0 || end < 0) throw new Error('ksuExec source boundary missing');
const functionSource = source.slice(start, end);

async function runCase(kind) {
  let calls = 0;
  const context = {
    console,
    setTimeout,
    clearTimeout,
    Math,
    Date,
    Promise,
    window: {},
    debugLog() {},
    ksu: {
      exec(command, options, callbackName) {
        calls += 1;
        if (kind === 'callback') {
          if (!callbackName) throw new Error('callback API did not receive callback');
          setTimeout(() => context.window[callbackName](0, 'ok\n', ''), 0);
          return undefined;
        }
        return Promise.resolve({ stdout: 'ok\n' });
      }
    }
  };
  vm.createContext(context);
  vm.runInContext(functionSource, context);
  const result = await context.ksuExec('state-changing-command', true, 1000);
  if (result !== 'ok') throw new Error(`${kind}: unexpected result ${JSON.stringify(result)}`);
  if (calls !== 1) throw new Error(`${kind}: command dispatched ${calls} times`);
}

(async () => {
  await runCase('callback');
  await runCase('promise');
  console.log('WebUI auth bridge contracts passed');
})().catch(error => {
  console.error(error.stack || error);
  process.exit(1);
});
NODE

echo 'WebUI auth flow contracts passed'
