// main.js — 慕容调度 · 显示模块 WebUI
// 纯原生 JS，兼容 Android WebView (KsuWebUI / Chrome 内核)。
// 冻结后端契约：所有 shell 调用走 ${MOD_DIR}/scripts/web_handler.sh，
// 授权/账号/付费资源走 BASE_API（见下方常量）。

// ============================================================
// 常量与全局状态
// ============================================================
const MODULE_ID = "murongchaopin";
const MOD_DIR = `/data/adb/modules/${MODULE_ID}`;
const CONFIG_FILE = `${MOD_DIR}/config/mode.txt`;
const LOG_FILE = `${MOD_DIR}/daemon.log`;
const BASE_API = "https://murongdiaodu.rl1.cc/api";
const PKG_CHUNK_BYTES = 64 * 1024; // 分块上传；base64url 后约 87KB，低于单参上限
const THEME_KEY = "murongchaopin_theme";
const TOKEN_KEY = "murongchaopin_token";
const PAYMENT_ORDER_KEY = "murongchaopin_pending_payment";
const VIDEO_MOTION_TARGET_KEY = "murong_video_motion_target_rate";
const SHOW_SYSTEM_APPS_KEY = "murongchaopin_show_system_apps";
const UPDATE_NOTICE_SESSION_KEY = "murongchaopin_update_notice";
const AUTH_REFRESH_TTL_MS = 15000;
const VIDEO_DATA_TTL_MS = 10000;
const APPLIED_MODE_POLL_MS = 2500;

let currentMode = -1;
let appliedMode = -1;
let appliedModePoll = null;
let appliedModePollBusy = false;
let displayModes = [];
let appConfigs = {};
let allPackages = [];
let appLabels = {};
let currentResolutionWidth = 1080;
let currentDtsBackend = 'dtbo';
let dtsBackendBusy = false;
let adfrPolicyBusy = false;
let displayPolicyProfile = 'rmx5200';
let videoMotionEntries = [];
let ocNodes = [];
const nativeMemcRates = new Set([60, 90, 120, 144]);
const labelQueue = [];
let processingQueue = false;
let activeTabId = 'tab-oc';
let modalHistoryActive = false;
let paymentHistoryActive = false;
let modalClosing = false;
let paymentClosing = false;
const tabScrollPositions = new Map();
let tabHistory = [];
let predictiveBackState = null;

// 授权相关运行时状态
let authToken = null;
let authState = { account: 'none', entitlement: 'unknown', premium_available: 0, package_installed: 0, lease_valid: 0 };
let deviceInfo = null;
let serverEntitlement = null;
let licenses = null;
let downloadBusy = false;
let paymentCatalog = null;
let paymentOrder = null;
let paymentPollTimer = null;
let updateCheckBusy = false;
let automaticUpdateCheckStarted = false;
let paymentCheckBusy = false;
let authorizationRefreshPromise = null;
let authorizationRefreshedAt = 0;
let videoDataRefreshPromise = null;
let videoDataRefreshedAt = 0;
let appListLoaded = false;
let appListLoadPromise = null;

// ============================================================
// 调试日志
// ============================================================
function debugLog(msg) {
    if (msg === undefined || msg === null) return;
    console.log(msg);
    const consoleEl = document.getElementById('debug-console');
    if (consoleEl) {
        const time = new Date().toLocaleTimeString();
        consoleEl.innerText += `[${time}] ${msg}\n`;
        consoleEl.scrollTop = consoleEl.scrollHeight;
    }
}

function toggleDebug() {
    const el = document.getElementById('debug-container');
    if (el) el.hidden = !el.hidden;
}

// 兼容 KSU 的 exec 封装（quiet=true 时不刷 debug，用于高频轮询与含敏感参数的调用）
async function ksuExec(cmd, quiet = false, timeoutMs = 30000) {
    if (!quiet) debugLog(`[Exec] ${cmd}`);
    return new Promise((resolve, reject) => {
        if (typeof ksu === 'undefined') {
            debugLog("[Mock] ksu undefined");
            resolve("");
            return;
        }

        try {
            const result = ksu.exec(cmd, "{}");
            if (result instanceof Promise) {
                let settled = false;
                const timer = setTimeout(() => {
                    if (settled) return;
                    settled = true;
                    if (!quiet) debugLog(`[Timeout] ${cmd}`);
                    resolve("Error: Command timed out");
                }, timeoutMs);
                result.then(res => {
                    if (settled) return;
                    settled = true;
                    clearTimeout(timer);
                    if (typeof res === 'string') {
                        if (!quiet) debugLog(`[Res] length=${res.length}`);
                        resolve(res);
                    } else {
                        if (!quiet) debugLog(`[Res] stdout length=${res.stdout ? res.stdout.length : 0}`);
                        resolve(res.stdout || "");
                    }
                }).catch(err => {
                    if (settled) return;
                    settled = true;
                    clearTimeout(timer);
                    if (!quiet) debugLog(`[Err] ${err}`);
                    console.error("KSU Promise Error:", err);
                    resolve("");
                });
            } else {
                const callbackName = `cb_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

                const timeout = setTimeout(() => {
                    delete window[callbackName];
                    debugLog(`[Timeout] ${cmd}`);
                    console.warn(`Command timed out: ${cmd}`);
                    resolve("Error: Command timed out");
                }, timeoutMs);

                window[callbackName] = (code, stdout, stderr) => {
                    clearTimeout(timeout);
                    delete window[callbackName];
                    debugLog(`[CB] code=${code} out_len=${stdout ? stdout.length : 0}`);
                    if (code !== 0) {
                        console.error(`Command failed with code ${code}: ${stderr}`);
                        resolve(stdout ? stdout.trim() : (stderr ? "Error: " + stderr : "Error: Unknown failure"));
                        return;
                    }
                    resolve(stdout ? stdout.trim() : "");
                };

                ksu.exec(cmd, "{}", callbackName);
            }
        } catch (e) {
            debugLog(`[Exception] ${e.message}`);
            console.error("KSU Exec Exception:", e);
            resolve("");
        }
    });
}

// ============================================================
// 工具函数
// ============================================================
function parseKeyValueOutput(output) {
    const values = {};
    String(output || '').split(/\r?\n/).forEach(line => {
        const separator = line.indexOf('=');
        if (separator <= 0) return;
        values[line.slice(0, separator).trim()] = line.slice(separator + 1).trim();
    });
    return values;
}

function shellQuote(value) {
    return "'" + String(value).replaceAll("'", "'\"'\"'") + "'";
}

function esc(value) {
    return String(value == null ? '' : value)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
}

function handlerCmd(action, ...args) {
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    if (!args.length) return `sh "${scriptPath}" ${action}`;
    return `sh "${scriptPath}" ${action} ${args.map(shellQuote).join(' ')}`;
}

function randomUUID() {
    if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
        return crypto.randomUUID();
    }
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
        const r = Math.random() * 16 | 0;
        const v = c === 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
}

function bytesToBase64Url(bytes) {
    let binary = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function utf8ToBase64Url(str) {
    const bytes = new TextEncoder().encode(str);
    return bytesToBase64Url(bytes);
}

function base64UrlToUtf8(value) {
    const normalized = String(value || '').replace(/-/g, '+').replace(/_/g, '/');
    const padded = normalized + '='.repeat((4 - normalized.length % 4) % 4);
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new TextDecoder().decode(bytes);
}

function formatBytes(n) {
    n = Number(n) || 0;
    if (n < 1024) return n + ' B';
    if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
    if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
    return (n / 1073741824).toFixed(2) + ' GB';
}

function pad2(n) { return String(n).padStart(2, '0'); }

function formatEpoch(epoch) {
    const n = Number(epoch);
    if (!n || !isFinite(n)) return '—';
    const d = new Date(n * 1000);
    return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

function resolutionWidth(token) {
    const value = String(token || '').toUpperCase();
    if (value === 'FHD+' || value === 'FHD' || value === '1080P' || value === '1080') return 1080;
    if (value === 'QHD+' || value === 'QHD' || value === '2K' || value === '1440') return 1440;
    return -1;
}

function resolutionLabel(width) {
    return Number(width) >= 1200 ? '2K (QHD+)' : '1080P (FHD+)';
}

function modeForChoice(width, fps) {
    return displayModes.find(mode => mode.width === Number(width) && mode.fps === Number(fps));
}

function parseModeChoice(text, fallbackWidth) {
    const value = String(text || '').trim();
    if (!value) return { modeId: -1, width: -1, fps: -1 };
    if (/^\d+$/.test(value)) {
        const id = Number(value);
        const mode = displayModes.find(item => item.id === id);
        return mode ? { modeId: id, width: mode.width, fps: mode.fps } : { modeId: id, width: -1, fps: -1 };
    }
    const fields = value.split(/\s+/);
    if (fields.length >= 2) {
        const width = resolutionWidth(fields[0]);
        const fps = Number(fields[1]);
        const mode = modeForChoice(width, fps);
        return { modeId: mode ? mode.id : -1, width, fps };
    }
    const fps = Number(fields[0]);
    const mode = modeForChoice(fallbackWidth, fps);
    return { modeId: mode ? mode.id : -1, width: Number(fallbackWidth), fps };
}

function isFlashSuccess(result) {
    if (!result) return false;
    if (result.includes("Success")) return true;
    if (result.includes("刷入成功") || result.includes("操作完成")) return true;
    return false;
}

function extractFlashError(result) {
    if (!result) return "无输出";
    const m = result.match(/错误：[^\n]*|警告:[^\n]*|失败[：:][^\n]*/);
    return m ? m[0] : result;
}

function calcAuto(fps, clock, transfer, targetFps) {
    if (!fps || fps <= 0 || !targetFps || targetFps <= 0) return null;
    return {
        clock: clock > 0 ? Math.floor(clock * targetFps / fps) : 0,
        transfer: transfer > 0 ? Math.floor(transfer * fps / targetFps) : 0
    };
}

function videoMotionTargetLabel(rate) {
    if (rate === 0) return '跟随用户选择';
    if (nativeMemcRates.has(rate)) return `优化至 ${rate} 帧`;
    return `选择 ${rate} Hz · R1 扩展实验输出`;
}

function nodeStability(fps) {
    if (fps >= 180) return { level: 'critical', text: '严重风险' };
    if (fps >= 175) return { level: 'edge', text: '边缘档' };
    if (fps >= 170) return { level: 'high', text: '超出原厂档' };
    if (fps === 123 || fps > 144) return { level: 'overclock', text: '超频档' };
    return { level: 'safe', text: '稳定' };
}

function nodeOrigin(file) {
    return String(file || '').indexOf('runtime') >= 0 ? 'DRM 运行时' : 'DTBO 工作区';
}

function isNativeNode(node) {
    if (currentDtsBackend === 'drm') return false; // DRM 运行时规格均为自定义，可删
    const fps = Number(node.fps);
    return [30, 60, 90, 120, 144].includes(fps); // 原厂标准档不可误删
}

// ============================================================
// 内联图标（无外链）
// ============================================================
function svgIcon(inner, size = 24) {
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${inner}</svg>`;
}

const ICON = {
    lock: (s = 24) => svgIcon('<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>', s),
    edit: (s = 16) => svgIcon('<path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z"/>', s),
    trash: (s = 16) => svgIcon('<polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>', s),
    refresh: (s = 16) => svgIcon('<polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>', s),
    download: (s = 16) => svgIcon('<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>', s),
    check: (s = 16) => svgIcon('<polyline points="20 6 9 17 4 12"/>', s)
};

// ============================================================
// Toast
// ============================================================
let toastTimer = null;
function showToast(message) {
    let toast = document.getElementById('toast');
    if (!toast) {
        toast = document.createElement('div');
        toast.id = 'toast';
        toast.className = 'ui-toast';
        document.body.appendChild(toast);
    }
    toast.innerText = message;
    toast.className = 'ui-toast show';
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
        toast.className = 'ui-toast';
    }, 3200);
}

// ============================================================
// 统一弹窗组件（Toast / 确认 / 输入 / 表单 / 流程日志）
// ============================================================
let modalResolve = null;
let flowButtonsResolve = null;

function modalEl() { return document.getElementById('modal-overlay'); }

function closePendingModal() {
    if (modalResolve) { const r = modalResolve; modalResolve = null; r(null); }
    if (flowButtonsResolve) { const r = flowButtonsResolve; flowButtonsResolve = null; r(null); }
}

function beginModalHistory() {
    if (modalHistoryActive) return;
    history.pushState({ kind: 'modal', tab: activeTabId }, '', `#${activeTabId}/dialog`);
    modalHistoryActive = true;
}

function renderModalBody(title, bodyEl) {
    const overlay = modalEl();
    overlay.classList.remove('is-closing');
    modalClosing = false;
    document.getElementById('modal-title').innerText = title;
    const body = document.getElementById('modal-body');
    body.innerHTML = '';
    if (typeof bodyEl === 'string') {
        const p = document.createElement('div');
        p.className = 'modal-message';
        p.innerText = bodyEl;
        body.appendChild(p);
    } else if (bodyEl) {
        body.appendChild(bodyEl);
    }
    document.getElementById('modal-log').hidden = true;
    document.getElementById('modal-log').innerHTML = '';
    const panel = overlay.querySelector('.modal-content');
    panel.classList.toggle('modal-lg', Boolean(bodyEl && bodyEl.classList
        && (bodyEl.classList.contains('app-mode-picker') || bodyEl.classList.contains('selection-dialog'))));
}

function renderModalButtons(buttons, onPick) {
    const actionsEl = document.getElementById('modal-actions');
    actionsEl.innerHTML = '';
    buttons.forEach(b => {
        const btn = document.createElement('button');
        btn.className = `btn ${b.className || 'btn-primary'}`;
        btn.innerText = b.label;
        btn.onclick = () => onPick(b.value);
        actionsEl.appendChild(btn);
    });
}

function finishModal(value, fromHistory = false) {
    if (modalClosing) return;
    const hadHistory = modalHistoryActive;
    modalHistoryActive = false;
    modalClosing = true;
    const overlay = modalEl();
    overlay.classList.add('is-closing');
    if (hadHistory && !fromHistory) history.back();
    const finish = () => {
        overlay.hidden = true;
        overlay.classList.remove('is-closing');
        document.getElementById('modal-log').hidden = true;
        overlay.querySelector('.modal-content').classList.remove('modal-lg');
        modalClosing = false;
        if (modalResolve) {
            const r = modalResolve;
            modalResolve = null;
            r(value);
        }
    };
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) finish();
    else setTimeout(finish, 190);
}

function showModalRaw(title, bodyEl, buttons) {
    return new Promise(resolve => {
        closePendingModal();
        modalResolve = resolve;
        renderModalBody(title, bodyEl);
        renderModalButtons(buttons, v => finishModal(v));
        beginModalHistory();
        modalEl().hidden = false;
    });
}

function showConfirm(title, message, opts = {}) {
    if (opts.single) {
        return showModalRaw(title, message, [
            { label: opts.okLabel || '知道了', className: 'btn-primary', value: true }
        ]);
    }
    return showModalRaw(title, message, [
        { label: opts.cancelLabel || '取消', className: 'btn-secondary', value: false },
        { label: opts.okLabel || '确定', className: opts.danger ? 'btn-danger' : 'btn-primary', value: true }
    ]);
}

async function showRebootModal(title, message) {
    const action = await showModalRaw(title, message, [
        { label: '立即重启', className: 'btn-danger', value: 'reboot' },
        { label: '稍后重启', className: 'btn-secondary', value: 'later' }
    ]);
    if (action === 'reboot') {
        showToast('正在重启设备…');
        await ksuExec('reboot');
    }
}

function showPrompt(title, message, opts = {}) {
    return new Promise(resolve => {
        closePendingModal();
        modalResolve = resolve;
        const container = document.createElement('div');
        if (message) {
            const p = document.createElement('div');
            p.className = 'modal-message';
            p.innerText = message;
            container.appendChild(p);
        }
        const input = document.createElement('input');
        input.className = 'form-input';
        input.type = opts.type || 'text';
        input.placeholder = opts.placeholder || '';
        input.value = opts.value || '';
        input.style.marginTop = '12px';
        container.appendChild(input);
        renderModalBody(title, container);
        const actionsEl = document.getElementById('modal-actions');
        actionsEl.innerHTML = '';
        const cancelBtn = document.createElement('button');
        cancelBtn.className = 'btn btn-secondary';
        cancelBtn.innerText = '取消';
        cancelBtn.onclick = () => finishModal(null);
        const okBtn = document.createElement('button');
        okBtn.className = `btn ${opts.danger ? 'btn-danger' : 'btn-primary'}`;
        okBtn.innerText = opts.okLabel || '确定';
        okBtn.onclick = () => finishModal(input.value);
        actionsEl.append(cancelBtn, okBtn);
        beginModalHistory();
        modalEl().hidden = false;
    });
}

function showForm(title, message, fields, opts = {}) {
    return new Promise(resolve => {
        closePendingModal();
        modalResolve = resolve;
        const container = document.createElement('div');
        if (message) {
            const p = document.createElement('div');
            p.className = 'modal-message';
            p.innerText = message;
            container.appendChild(p);
        }
        const fieldEls = {};
        fields.forEach(f => {
            const group = document.createElement('div');
            group.className = 'form-group';
            group.style.marginTop = '12px';
            const label = document.createElement('label');
            label.innerText = f.label;
            let input;
            if (f.type === 'select') {
                input = document.createElement('select');
                (f.options || []).forEach(o => {
                    const opt = document.createElement('option');
                    opt.value = o.value;
                    opt.innerText = o.label;
                    input.appendChild(opt);
                });
                input.value = f.value || '';
            } else {
                input = document.createElement('input');
                input.type = f.type || 'text';
                input.placeholder = f.placeholder || '';
                input.value = f.value || '';
            }
            input.className = 'form-input';
            input.dataset.fieldId = f.id;
            group.appendChild(label);
            group.appendChild(input);
            container.appendChild(group);
            fieldEls[f.id] = input;
            if (typeof f.onInput === 'function') {
                input.addEventListener('input', () => f.onInput(input, container));
            }
        });
        renderModalBody(title, container);
        const actionsEl = document.getElementById('modal-actions');
        actionsEl.innerHTML = '';
        const cancelBtn = document.createElement('button');
        cancelBtn.className = 'btn btn-secondary';
        cancelBtn.innerText = '取消';
        cancelBtn.onclick = () => finishModal(null);
        const okBtn = document.createElement('button');
        okBtn.className = `btn ${opts.danger ? 'btn-danger' : 'btn-primary'}`;
        okBtn.innerText = opts.okLabel || '确定';
        okBtn.onclick = () => {
            const result = {};
            let valid = true;
            fields.forEach(f => {
                const v = fieldEls[f.id].value.trim();
                if (f.required && !v) valid = false;
                result[f.id] = v;
            });
            if (!valid) { showToast('请填写必填项'); return; }
            finishModal(result);
        };
        actionsEl.append(cancelBtn, okBtn);
        beginModalHistory();
        modalEl().hidden = false;
    });
}

// 流程日志弹窗：{log(text, cls), setButtons([...]), waitButton(), close()}
function openFlowModal(title) {
    closePendingModal();
    const overlay = modalEl();
    overlay.classList.remove('is-closing');
    modalClosing = false;
    overlay.querySelector('.modal-content').classList.add('modal-lg');
    document.getElementById('modal-title').innerText = title;
    const body = document.getElementById('modal-body');
    body.innerHTML = '';
    const logEl = document.getElementById('modal-log');
    logEl.hidden = false;
    logEl.innerHTML = '';
    const actionsEl = document.getElementById('modal-actions');
    actionsEl.innerHTML = '';
    beginModalHistory();
    overlay.hidden = false;
    return {
        log(text, cls = '') {
            if (cls) {
                const span = document.createElement('span');
                span.className = 'log-' + cls;
                span.innerText = text;
                logEl.appendChild(span);
            } else {
                logEl.appendChild(document.createTextNode(text));
            }
            logEl.appendChild(document.createTextNode('\n'));
            logEl.scrollTop = logEl.scrollHeight;
        },
        setButtons(buttons) {
            actionsEl.innerHTML = '';
            buttons.forEach(b => {
                const btn = document.createElement('button');
                btn.className = `btn ${b.cls || 'btn-secondary'}`;
                btn.innerText = b.label;
                btn.onclick = () => {
                    actionsEl.innerHTML = '';
                    if (flowButtonsResolve) {
                        const r = flowButtonsResolve;
                        flowButtonsResolve = null;
                        r(b.value != null ? b.value : b.id);
                    }
                };
                actionsEl.appendChild(btn);
            });
        },
        waitButton() {
            return new Promise(resolve => { flowButtonsResolve = resolve; });
        },
        close() {
            if (modalClosing) return;
            const hadHistory = modalHistoryActive;
            modalHistoryActive = false;
            modalClosing = true;
            if (flowButtonsResolve) { flowButtonsResolve(null); flowButtonsResolve = null; }
            if (hadHistory) history.back();
            overlay.classList.add('is-closing');
            const finish = () => {
                overlay.hidden = true;
                overlay.classList.remove('is-closing');
                logEl.hidden = true;
                overlay.querySelector('.modal-content').classList.remove('modal-lg');
                modalClosing = false;
            };
            if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) finish();
            else setTimeout(finish, 190);
        }
    };
}

const nextPaint = () => new Promise(r => setTimeout(r, 30));

// 后台任务日志流式轮询（start_apply / start_flash 共用 apply.log 机制）
function pollProcessLog(logPath, statusPath, term, interval = 500) {
    return new Promise((resolve) => {
        let lastLen = 0;
        let pending = '';
        const timer = setInterval(async () => {
            try {
                const chunk = await ksuExec(`tail -c +${lastLen + 1} "${logPath}" 2>/dev/null`, true);
                if (chunk) {
                    lastLen += chunk.length;
                    const all = pending + chunk;
                    const lines = all.split('\n');
                    pending = lines.pop() || '';
                    lines.forEach(line => {
                        const t = line.trim();
                        if (!t) return;
                        let cls = 'info';
                        if (t.includes('Success:') || t.includes('操作完成')) cls = 'ok';
                        else if (t.includes('错误') || t.includes('Error:')) cls = 'err';
                        else if (t.includes('== 步骤') || t.includes('步骤')) cls = 'step';
                        else if (t.includes('WARNING')) cls = 'warn';
                        term.log(t, cls);
                    });
                }
                const st = (await ksuExec(`cat "${statusPath}" 2>/dev/null`, true)).trim();
                if (st === 'SUCCESS' || st === 'FAIL') {
                    clearInterval(timer);
                    resolve(st);
                }
            } catch (e) {
                // 轮询异常忽略，继续
            }
        }, interval);
    });
}

// ============================================================
// 主题系统
// ============================================================
function resolveSystemDark() {
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
}

function applyTheme(mode) {
    const root = document.documentElement;
    let effective = mode;
    if (mode === 'system') {
        effective = resolveSystemDark() ? 'dark' : 'light';
    }
    root.dataset.theme = effective;
    try { localStorage.setItem(THEME_KEY, mode); } catch (e) { /* ignore */ }
    renderThemeSeg();
}

function currentThemeMode() {
    try { return localStorage.getItem(THEME_KEY) || 'system'; } catch (e) { return 'system'; }
}

function renderThemeSeg() {
    const mode = currentThemeMode();
    ['system', 'light', 'dark'].forEach(m => {
        const btn = document.getElementById(`theme-${m}`);
        if (btn) btn.classList.toggle('active', m === mode);
    });
}

function setupTheme() {
    applyTheme(currentThemeMode());
    if (window.matchMedia) {
        window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
            if (currentThemeMode() === 'system') applyTheme('system');
        });
    }
}

// ============================================================
// 底部导航
// ============================================================
const TAB_ORDER = ['tab-oc', 'tab-rates', 'tab-video', 'tab-logs', 'tab-mine'];

function setBottomNavIndicator(index, animate = true) {
    const nav = document.querySelector('.bottom-nav');
    if (!nav || index < 0) return;
    const immediate = !animate && !nav.classList.contains('predictive-back-settle');
    nav.classList.toggle('indicator-immediate', immediate);
    nav.style.setProperty('--tab-indicator-index', String(index));
    if (immediate) requestAnimationFrame(() => nav.classList.remove('indicator-immediate'));
}

function setPredictiveTabWeight(index, weight) {
    const button = document.querySelector(`.tab-btn[data-tab="${TAB_ORDER[index] || ''}"]`);
    if (!button) return;
    button.classList.add('predictive-back-tab');
    button.style.setProperty('--predictive-tab-weight', String(Math.max(0, Math.min(1, weight))));
}

function predictiveCommitDuration(progress) {
    const bounded = Math.max(0, Math.min(1, Number(progress) || 0));
    if (bounded >= 1) return 0;
    return Math.max(72, Math.min(180, Math.round(180 * (1 - bounded))));
}

function configurePredictiveSettle(state, duration, easing) {
    [state.currentPage, state.targetPage, state.surface].filter(Boolean).forEach(element => {
        element.style.setProperty('--predictive-settle-duration', `${duration}ms`);
        element.style.setProperty('--predictive-settle-easing', easing);
        element.classList.add('predictive-back-settle');
    });
    const nav = document.querySelector('.bottom-nav');
    if (nav) {
        nav.classList.remove('indicator-immediate');
        nav.style.setProperty('--predictive-settle-duration', `${duration}ms`);
        nav.style.setProperty('--predictive-settle-easing', easing);
        nav.classList.add('predictive-back-settle');
    }
}

function cleanupPredictiveBack() {
    const state = predictiveBackState;
    if (!state) return;
    if (state.resetTimer) clearTimeout(state.resetTimer);
    [state.currentPage, state.targetPage, state.surface].filter(Boolean).forEach(element => {
        element.classList.remove(
            'predictive-back-layer', 'predictive-back-from', 'predictive-back-to',
            'predictive-back-surface', 'predictive-back-root', 'predictive-back-settle'
        );
        [
            '--predictive-back-x', '--predictive-back-scale', '--predictive-back-alpha',
            '--predictive-back-progress', '--predictive-scroll-y', '--predictive-header-bottom',
            '--predictive-settle-duration', '--predictive-settle-easing'
        ].forEach(property => element.style.removeProperty(property));
    });
    const nav = document.querySelector('.bottom-nav');
    if (nav) {
        nav.classList.remove('predictive-back-nav', 'predictive-back-settle', 'indicator-immediate');
        nav.style.removeProperty('--predictive-settle-duration');
        nav.style.removeProperty('--predictive-settle-easing');
        nav.querySelectorAll('.predictive-back-tab').forEach(button => {
            button.classList.remove('predictive-back-tab');
            button.style.removeProperty('--predictive-tab-weight');
        });
    }
    document.documentElement.classList.remove('predictive-back-active', 'predictive-back-root-active');
    predictiveBackState = null;
    setBottomNavIndicator(TAB_ORDER.indexOf(activeTabId), false);
}

function activateTab(targetId, { push = false, back = false } = {}) {
    const tabs = document.querySelectorAll('.tab-btn');
    const contents = document.querySelectorAll('.page');
    const target = document.getElementById(targetId);
    if (!target) return;
    const changed = activeTabId !== targetId;
    if (push && changed) {
        history.pushState({ kind: 'tab', tab: targetId }, '', `#${targetId}`);
        tabHistory.push(targetId);
    }
    if (!changed) return;

    tabScrollPositions.set(activeTabId, window.scrollY || document.documentElement.scrollTop || 0);
    const oldIndex = TAB_ORDER.indexOf(activeTabId);
    const newIndex = TAB_ORDER.indexOf(targetId);
    const direction = back || (oldIndex >= 0 && newIndex >= 0 && newIndex < oldIndex) ? 'back' : 'forward';
    const apply = () => {
        tabs.forEach(t => t.classList.toggle('active', t.getAttribute('data-tab') === targetId));
        contents.forEach(c => c.classList.remove('active', 'page-forward', 'page-back'));
        target.classList.add('active');
        target.classList.add(direction === 'back' ? 'page-back' : 'page-forward');
        activeTabId = targetId;
        const restoreY = tabScrollPositions.get(targetId) || 0;
        window.scrollTo(0, restoreY);
        cleanupPredictiveBack();
        setBottomNavIndicator(newIndex, !back);
    };

    apply();

    syncAppliedModePolling();
    runAfterFirstPaint(() => {
        if (activeTabId !== targetId) return;
        if (targetId === 'tab-logs') refreshLogs();
        if (targetId === 'tab-video' || targetId === 'tab-mine') {
            refreshAuthorizationView().catch(error => {
                debugLog(`background authorization refresh failed: ${error.message}`);
            });
        }
        if (targetId === 'tab-video') {
            refreshVideoPageData();
            ensureAppListLoaded();
        }
        if (targetId === 'tab-rates') {
            refreshAppliedMode();
            ensureAppListLoaded();
        }
        if (targetId === 'tab-rates' || targetId === 'tab-video') processLabelQueue();
    });
}

function setupTabs() {
    const tabs = document.querySelectorAll('.tab-btn');
    const initial = document.querySelector('.tab-btn.active')?.getAttribute('data-tab') || 'tab-oc';
    activeTabId = initial;
    tabHistory = [initial];
    history.replaceState({ kind: 'tab', tab: initial }, '', `#${initial}`);
    setBottomNavIndicator(TAB_ORDER.indexOf(initial), false);
    tabs.forEach(tab => {
        tab.addEventListener('click', () => {
            const targetId = tab.getAttribute('data-tab');
            activateTab(targetId, { push: true });
        });
    });
    window.addEventListener('popstate', event => {
        const payment = paymentOverlayEl();
        if (payment && !payment.hidden) {
            closePaymentOverlay(true);
            return;
        }
        const overlay = modalEl();
        if (overlay && !overlay.hidden) {
            modalHistoryActive = false;
            finishModal(null, true);
            if (flowButtonsResolve) {
                const resolve = flowButtonsResolve;
                flowButtonsResolve = null;
                resolve(null);
            }
            return;
        }
        const targetId = event.state && event.state.kind === 'tab' ? event.state.tab : null;
        if (targetId) {
            if (tabHistory.length > 1 && tabHistory[tabHistory.length - 2] === targetId) {
                tabHistory.pop();
            } else {
                const existing = tabHistory.lastIndexOf(targetId);
                if (existing >= 0) tabHistory = tabHistory.slice(0, existing + 1);
                else tabHistory.push(targetId);
            }
            activateTab(targetId, { back: true });
        }
    });
}

// Native predictive-back needs a synchronous-looking answer, but WebView's
// canGoBack() does not consistently count pushState entries on ColorOS. Keep
// the decision in the same history model that renders the two-page preview.
window.__murongPredictiveBackCanPop = function () {
    const payment = paymentOverlayEl();
    const modal = modalEl();
    return tabHistory.length > 1
        || !!(payment && !payment.hidden)
        || !!(modal && !modal.hidden);
};

function preparePredictiveBack(edge) {
    if (predictiveBackState) return predictiveBackState;
    const payment = paymentOverlayEl();
    const modal = modalEl();
    const surface = payment && !payment.hidden
        ? payment.querySelector('.payment-sheet')
        : (modal && !modal.hidden ? modal.querySelector('.modal-content') : null);
    if (surface) {
        predictiveBackState = {
            mode: 'surface', surface, direction: Number(edge) === 1 ? -1 : 1,
            progress: 0, resetTimer: null
        };
        surface.classList.add('predictive-back-surface');
    } else {
        const targetId = tabHistory.length > 1 ? tabHistory[tabHistory.length - 2] : null;
        const currentPage = document.getElementById(activeTabId);
        const targetPage = targetId ? document.getElementById(targetId) : null;
        const fromIndex = TAB_ORDER.indexOf(activeTabId);
        const toIndex = TAB_ORDER.indexOf(targetId);
        if (currentPage && targetPage && currentPage !== targetPage && fromIndex >= 0 && toIndex >= 0) {
            const headerBottom = document.querySelector('.app-header')?.getBoundingClientRect().bottom || 0;
            const currentScroll = window.scrollY || document.documentElement.scrollTop || 0;
            const targetScroll = tabScrollPositions.get(targetId) || 0;
            const direction = fromIndex > toIndex ? 1 : -1;
            predictiveBackState = {
                mode: 'tabs', currentPage, targetPage, fromIndex, toIndex, direction,
                progress: 0, resetTimer: null
            };
            currentPage.classList.add('predictive-back-layer', 'predictive-back-from');
            targetPage.classList.add('predictive-back-layer', 'predictive-back-to');
            currentPage.style.setProperty('--predictive-scroll-y', `${currentScroll}px`);
            targetPage.style.setProperty('--predictive-scroll-y', `${targetScroll}px`);
            currentPage.style.setProperty('--predictive-header-bottom', `${headerBottom}px`);
            targetPage.style.setProperty('--predictive-header-bottom', `${headerBottom}px`);
            document.querySelector('.bottom-nav')?.classList.add('predictive-back-nav');
        } else {
            const rootSurface = document.querySelector('.app');
            predictiveBackState = {
                mode: 'root', surface: rootSurface, direction: Number(edge) === 1 ? -1 : 1,
                progress: 0, resetTimer: null
            };
            rootSurface?.classList.add('predictive-back-surface', 'predictive-back-root');
            document.documentElement.classList.add('predictive-back-root-active');
        }
    }
    document.documentElement.classList.add('predictive-back-active');
    return predictiveBackState;
}

function applyPredictiveBackProgress(state, progress) {
    const bounded = Math.max(0, Math.min(1, Number(progress) || 0));
    state.progress = bounded;
    if (state.mode === 'tabs') {
        const currentX = state.direction * bounded * window.innerWidth;
        const targetX = currentX - state.direction * window.innerWidth;
        const currentScale = 1 - (0.1 * bounded);
        const targetScale = 0.9 + (0.1 * bounded);
        const currentAlpha = 1 - (0.3 * bounded);
        const targetAlpha = 0.7 + (0.3 * bounded);
        state.currentPage.style.setProperty('--predictive-back-x', `${currentX}px`);
        state.currentPage.style.setProperty('--predictive-back-scale', String(currentScale));
        state.currentPage.style.setProperty('--predictive-back-alpha', String(currentAlpha));
        state.targetPage.style.setProperty('--predictive-back-x', `${targetX}px`);
        state.targetPage.style.setProperty('--predictive-back-scale', String(targetScale));
        state.targetPage.style.setProperty('--predictive-back-alpha', String(targetAlpha));
        state.currentPage.style.setProperty('--predictive-back-progress', String(bounded));
        state.targetPage.style.setProperty('--predictive-back-progress', String(bounded));
        setBottomNavIndicator(state.fromIndex + (state.toIndex - state.fromIndex) * bounded, false);
        setPredictiveTabWeight(state.fromIndex, 1 - bounded);
        setPredictiveTabWeight(state.toIndex, bounded);
        return;
    }
    if (state.surface) {
        state.surface.style.setProperty('--predictive-back-x', `${state.direction * bounded * window.innerWidth}px`);
        state.surface.style.setProperty('--predictive-back-scale', String(1 - 0.1 * bounded));
        state.surface.style.setProperty('--predictive-back-alpha', String(1 - 0.3 * bounded));
        state.surface.style.setProperty('--predictive-back-progress', String(bounded));
    }
}

window.__murongPredictiveBack = function (type, progress = 0, edge = 0) {
    if (type === 'start' || type === 'progress') {
        const state = preparePredictiveBack(edge);
        if (state) applyPredictiveBackProgress(state, progress);
        return;
    }
    const state = predictiveBackState;
    if (!state) return;
    if (type === 'cancel') {
        configurePredictiveSettle(state, 260, 'cubic-bezier(0.2, 1.08, 0.32, 1)');
        applyPredictiveBackProgress(state, 0);
        state.resetTimer = setTimeout(cleanupPredictiveBack, 260);
        return;
    }
    if (type === 'commit' || type === 'invoke') {
        const duration = predictiveCommitDuration(state.progress);
        configurePredictiveSettle(state, duration, 'linear');
        applyPredictiveBackProgress(state, 1);
        return;
    }
    cleanupPredictiveBack();
};

function setupAuthorizationPullRefresh() {
    let startY = 0;
    let armed = false;
    const canRefresh = () => {
        const mine = document.getElementById('tab-mine');
        const video = document.getElementById('tab-video');
        const active = (mine && mine.classList.contains('active')) || (video && video.classList.contains('active'));
        return active && (window.scrollY || document.documentElement.scrollTop || 0) <= 0;
    };
    document.addEventListener('touchstart', (event) => {
        armed = canRefresh();
        startY = armed ? event.touches[0].clientY : 0;
    }, { passive: true });
    document.addEventListener('touchend', (event) => {
        if (!armed) return;
        const endY = event.changedTouches[0].clientY;
        armed = false;
        if (endY - startY < 80) return;
        forceRefreshAuthorization();
    }, { passive: true });
}

// ============================================================
// API 客户端（跨域，遗留接口 CORS 已为 *）
// ============================================================
async function apiFetch(path, opts = {}) {
    const method = opts.method || 'GET';
    const headers = {};
    if (opts.auth && authToken) headers['Authorization'] = `Bearer ${authToken}`;
    const requestNonce = opts.nonce ? randomUUID() : '';
    if (requestNonce) headers['X-Display-Request-Nonce'] = requestNonce;
    let payload;
    if (opts.body !== undefined && opts.body !== null) {
        if (opts.form) {
            headers['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
            payload = new URLSearchParams(opts.body).toString();
        } else {
            headers['Content-Type'] = 'application/json';
            payload = JSON.stringify(opts.body);
        }
    }
    // Authenticated requests use the root-side HTTPS channel. ColorOS WebView
    // can reject cross-origin POST before the request reaches the server, and
    // the root channel can restore the persisted token after WebView recreation.
    if (opts.auth && !opts.form && (method === 'GET' || method === 'POST')) {
        const payloadB64 = payload === undefined ? '' : utf8ToBase64Url(payload);
        const raw = await ksuExec(handlerCmd(
            'api_request', method, path, '1', payloadB64, requestNonce
        ), true);
        if (!raw || raw.startsWith('Error:')) {
            throw new Error((raw || '授权后端无响应').replace(/^Error:\s*/, ''));
        }
        let proxied;
        try {
            proxied = JSON.parse(raw);
        } catch (error) {
            throw new Error('服务响应格式错误');
        }
        if (proxied.success === false || proxied.error) {
            throw new Error(proxied.message || proxied.error || '请求失败');
        }
        return proxied;
    }

    let resp;
    try {
        resp = await fetch(`${BASE_API}/${path}`, { method, headers, body: payload });
    } catch (e) {
        throw new Error('网络不可用：' + e.message);
    }
    let json = null;
    try { json = await resp.json(); } catch (e) { json = null; }
    if (!json) throw new Error(`服务响应异常 HTTP ${resp.status}`);
    if (json.success === false || json.error) {
        throw new Error(json.message || json.error || `请求失败 HTTP ${resp.status}`);
    }
    return json;
}

// ============================================================
// 授权状态（本地 handler + 服务端）
// ============================================================
function isPremium() {
    return authState.premium_available === 1;
}

async function refreshAuthState() {
    try {
        const raw = await ksuExec(handlerCmd('auth_state'), true);
        authState = parseKeyValueOutput(raw);
    } catch (e) {
        authState = {};
    }
    if (!authState || typeof authState !== 'object') authState = {};
    authState.account = authState.account || 'none';
    authState.entitlement = authState.entitlement || 'unknown';
    authState.premium_available = authState.premium_available === '1' ? 1 : 0;
    authState.package_installed = authState.package_installed === '1' ? 1 : 0;
    authState.package_version_code = Number(authState.package_version_code || 0);
    if (!Number.isInteger(authState.package_version_code) || authState.package_version_code < 0) {
        authState.package_version_code = 0;
    }
    authState.package_pending = authState.package_pending === '1' ? 1 : 0;
    authState.device_bound = authState.device_bound === '1' ? 1 : 0;
    authState.lease_valid = authState.lease_valid === '1' ? 1 : 0;
    authState.reboot_required = authState.reboot_required === '1' ? 1 : 0;
    return authState;
}

async function refreshDeviceInfo() {
    try {
        const raw = await ksuExec(handlerCmd('auth_device_info'), true);
        deviceInfo = parseKeyValueOutput(raw);
    } catch (e) {
        deviceInfo = {};
    }
    if (!deviceInfo || typeof deviceInfo !== 'object') deviceInfo = {};
    return deviceInfo;
}

async function refreshServerAuth() {
    if (!authToken && authState.account !== 'logged_in') return false;
    const qs = new URLSearchParams({
        device_id: (deviceInfo && deviceInfo.device_id) || '',
        sn: (deviceInfo && deviceInfo.sn) || '',
        imei1: (deviceInfo && deviceInfo.imei1) || '',
        imei2: (deviceInfo && deviceInfo.imei2) || '',
        device_id_hash: (deviceInfo && deviceInfo.device_id_hash) || ''
    });
    const ent = await apiFetch(`v1/display/entitlement?${qs.toString()}`, { auth: true });
    serverEntitlement = ent.data || null;
    const lic = await apiFetch('v1/display/licenses', { auth: true });
    licenses = lic.data || [];
    // 缓存服务端判定到本地状态（离线时展示最后已知状态）
    try {
        const last4 = (licenses.length && licenses[0].key_last4) ? String(licenses[0].key_last4) : '';
        const boundModel = (serverEntitlement && serverEntitlement.device && serverEntitlement.device.device_model) || '';
        await ksuExec(handlerCmd('auth_entitlement_cache', serverEntitlement ? String(serverEntitlement.status) : 'not_purchased', last4, boundModel), true);
    } catch (e) { /* 缓存失败不影响在线展示 */ }
    // 服务端判定已激活且本地租约缺失/失效时，自动续租
    if (serverEntitlement && serverEntitlement.status === 'active' && authState.lease_valid !== 1) {
        await refreshLease();
    }
    await refreshAuthState();
    return true;
}

function renderCurrentAuthorizationPage() {
    if (activeTabId === 'tab-mine') renderMinePage();
    if (activeTabId === 'tab-video') renderVideoPage();
    updatePaidMarkers();
}

async function refreshAuthorizationView({ force = false } = {}) {
    renderCurrentAuthorizationPage();
    if (!force && authorizationRefreshedAt > 0
        && Date.now() - authorizationRefreshedAt < AUTH_REFRESH_TTL_MS) return true;
    if (authorizationRefreshPromise) return authorizationRefreshPromise;
    authorizationRefreshPromise = (async () => {
        await refreshAuthState();
        await refreshDeviceInfo();
        authorizationRefreshedAt = Date.now();
        if (authToken || authState.account === 'logged_in') await refreshServerAuth();
        await refreshAuthState();
        renderCurrentAuthorizationPage();
        if (activeTabId === 'tab-video') refreshVideoPageData({ force: true });
        return true;
    })().finally(() => {
        authorizationRefreshPromise = null;
    });
    return authorizationRefreshPromise;
}

async function forceRefreshAuthorization() {
    showToast('正在刷新授权…');
    try {
        await refreshAuthorizationView({ force: true });
        showToast('授权状态已刷新');
    } catch (error) {
        debugLog(`authorization refresh failed: ${error.message}`);
        showToast('授权刷新失败：' + error.message);
    }
}

async function refreshLease() {
    if (!deviceInfo || (!deviceInfo.device_id && !deviceInfo.sn && !deviceInfo.device_id_hash)) throw new Error('无法获取设备信息');
    const resp = await apiFetch('v1/display/licenses/lease', {
        method: 'POST', auth: true, nonce: true,
        body: {
            device_id: deviceInfo.device_id || '',
            sn: deviceInfo.sn || deviceInfo.device_id || '',
            imei1: deviceInfo.imei1 || '',
            imei2: deviceInfo.imei2 || '',
            device_id_hash: deviceInfo.device_id_hash,
            device_model: deviceInfo.device_model || '',
            soc_model: deviceInfo.soc_model || '',
            build_fingerprint: deviceInfo.build_fingerprint || ''
        }
    });
    const leaseB64 = utf8ToBase64Url(JSON.stringify(resp.data));
    const r = await ksuExec(handlerCmd('auth_save_lease', leaseB64), true);
    if (!r.includes('Success')) throw new Error(r || '租约保存失败');
    return resp.data;
}

// 有效 entitlement：服务端在线时优先，离线回退本地
function effectiveEntitlement() {
    if (serverEntitlement && serverEntitlement.status) return serverEntitlement.status;
    return authState.entitlement;
}

// ============================================================
// 我的页（授权状态机）
// ============================================================
function updatePaidMarkers() {
    const premium = isPremium();
    document.querySelectorAll('.seg-btn-paid .lock, .paid-lock').forEach(el => {
        el.style.display = premium ? 'none' : 'inline-block';
    });
    const headerAuth = document.getElementById('header-auth');
    if (headerAuth) {
        const ent = effectiveEntitlement();
        headerAuth.className = 'status-badge';
        if (premium || ent === 'active' || ent === 'grace') {
            headerAuth.innerText = ent === 'grace' ? '离线授权' : '永久授权';
            headerAuth.classList.add(ent === 'grace' ? 'warning' : 'paid');
        } else if (ent === 'binding_required') {
            headerAuth.innerText = '待绑定';
            headerAuth.classList.add('warning');
        } else {
            headerAuth.innerText = '未授权';
        }
    }
}

function productCardHtml() {
    return `
        <div class="product-card">
            <div class="card-head">
                <span class="card-title">显示增强永久授权</span>
                <span class="price">20 元</span>
            </div>
            <p class="text-hint">永久授权，不限模块版本；一张卡密绑定一台设备。</p>
        </div>`;
}

function renderMinePage() {
    const el = document.getElementById('auth-section');
    if (!el) return;
    el.innerHTML = '';
    const st = authState;

    // 账号区
    if (st.account === 'logged_in' || authToken) {
        const acct = document.createElement('div');
        acct.className = 'card account-card';
        acct.innerHTML = `
            <div class="card-head">
                <span class="card-title">账号</span>
                <button class="btn btn-sm btn-secondary" data-action="logout">登出</button>
            </div>
            <ul class="kv-list">
                <li><span class="kv-label">用户名</span><span class="kv-value">${esc(st.username || '—')}</span></li>
                <li><span class="kv-label">用户 ID</span><span class="kv-value">${esc(st.user_id || '—')}</span></li>
            </ul>`;
        el.appendChild(acct);
    } else {
        const guest = document.createElement('div');
        guest.className = 'card account-card';
        guest.innerHTML = `
            <div class="card-head">
                <span class="card-title">账号</span>
                <span class="status-badge">未登录</span>
            </div>
            <p class="text-hint">登录慕容调度账号以购买、绑定和管理“显示增强永久授权”。</p>
            <div class="btn-row">
                <button class="btn btn-primary" data-action="login">登录</button>
                <button class="btn btn-secondary" data-action="register">注册</button>
            </div>`;
        el.appendChild(guest);
    }

    // 授权区
    const authWrap = document.createElement('div');
    authWrap.className = 'card account-card';
    authWrap.appendChild(renderEntitlementSection());
    el.appendChild(authWrap);
}

function renderEntitlementSection() {
    const div = document.createElement('div');
    const ent = effectiveEntitlement();
    const st = authState;
    const entitlementBadge = ent === 'active'
        ? '<span class="status-badge success">已授权</span>'
        : ent === 'grace'
            ? '<span class="status-badge warning">离线宽限</span>'
            : ent === 'binding_required'
                ? '<span class="status-badge warning">待绑定</span>'
                : '<span class="badge-paid">20 元永久</span>';

    let head = `<div class="card-head"><span class="card-title">授权</span><div class="card-actions">${entitlementBadge}<button class="icon-btn" type="button" data-action="refresh" title="刷新授权状态" aria-label="刷新授权状态">${ICON.refresh()}</button></div></div>`;
    let body = '';

    switch (ent) {
        case 'binding_required':
            body = `<ul class="kv-list">
                <li><span class="kv-label">卡密</span><span class="kv-value">尾号 ${esc(st.license_last4 || '—')}</span></li>
                <li><span class="kv-label">绑定状态</span><span class="status-badge warning">待绑定</span></li>
                </ul>
                <p class="text-hint">已购买未绑定，输入完整卡密即可绑定本机。</p>
                <button class="btn btn-primary btn-block" data-action="bind">绑定本机</button>`;
            break;
        case 'active':
            if (st.package_installed === 1) {
                body = installedBlockHtml();
            } else {
                body = `<ul class="kv-list">
                    <li><span class="kv-label">卡密</span><span class="kv-value">尾号 ${esc(st.license_last4 || '—')}</span></li>
                        <li><span class="kv-label">绑定机型</span><span class="kv-value">${esc(st.device_model || '—')}</span></li>
                        <li><span class="kv-label">付费包</span><span class="status-badge warning">未安装</span></li>
                    </ul>
                    <button class="btn btn-primary btn-block" data-action="download">下载付费组件</button>`;
            }
            break;
        case 'grace':
            body = graceBlockHtml();
            break;
        case 'expired':
            body = `<div class="notice notice-warning">授权租约已过期且离线宽限已结束。付费功能暂时停用，免费功能不受影响。</div>
                <button class="btn btn-secondary btn-block" data-action="lease">重新获取租约</button>`;
            break;
        case 'disabled':
        case 'revoked':
        case 'refunded':
            body = `<div class="notice notice-danger">${revokedText(ent)}</div>
                <p class="text-hint">已安装的付费组件将在下次整机重启后切回免费路径，不会在线卸载。</p>`;
            break;
        default:
            body = productCardHtml() + `
                <p class="text-hint">20 元永久授权，一张卡密绑定一台设备。支付交付时自动绑定本机。</p>
                <button class="btn btn-primary btn-block" data-action="purchase">立即购买</button>
                ${pendingPaymentActionHtml()}
                <button class="btn btn-secondary btn-block" data-action="bind">输入卡密绑定</button>`;
            break;
    }

    div.innerHTML = head + body;
    return div;
}

function installedBlockHtml() {
    const st = authState;
    const leaseLine = st.lease_valid === 1
        ? `租约至 ${esc(formatEpoch(st.lease_expires_at))}`
        : '租约已失效';
    return `
        <ul class="kv-list">
            <li><span class="kv-label">卡密</span><span class="kv-value">尾号 ${esc(st.license_last4 || '—')}</span></li>
            <li><span class="kv-label">绑定机型</span><span class="kv-value">${esc(st.device_model || '—')}</span></li>
            <li><span class="kv-label">付费包版本</span><span class="kv-value">${esc(st.package_version || '—')}</span></li>
            <li><span class="kv-label">租约刷新</span><span class="kv-value">${leaseLine}</span></li>
            <li><span class="kv-label">宽限截止</span><span class="kv-value">${esc(formatEpoch(st.grace_until))}</span></li>
        </ul>
        <div class="btn-row">
            <button class="btn btn-secondary" data-action="lease">重新续租</button>
            <button class="btn btn-primary" data-action="update">检查更新</button>
        </div>`;
}

function graceBlockHtml() {
    const st = authState;
    const countdown = graceCountdownHtml(st.grace_until);
    return `
        <div class="notice notice-warning">当前处于离线宽限期，付费功能可用。${countdown}</div>
        <ul class="kv-list">
            <li><span class="kv-label">付费包版本</span><span class="kv-value">${esc(st.package_version || '—')}</span></li>
            <li><span class="kv-label">宽限截止</span><span class="kv-value">${esc(formatEpoch(st.grace_until))}</span></li>
        </ul>
        <div class="btn-row">
            <button class="btn btn-secondary" data-action="lease">重新续租</button>
            <button class="btn btn-primary" data-action="update">检查更新</button>
        </div>`;
}

function graceCountdownHtml(untilEpoch) {
    const n = Number(untilEpoch);
    if (!n || !isFinite(n)) return '';
    const left = n * 1000 - Date.now();
    if (left <= 0) return '<span class="lease-countdown">宽限已结束</span>';
    const days = Math.floor(left / 86400000);
    const hours = Math.floor((left % 86400000) / 3600000);
    return `<span class="lease-countdown">剩余 ${days} 天 ${hours} 小时</span>`;
}

function revokedText(ent) {
    if (ent === 'refunded') return '该授权已退款。';
    if (ent === 'revoked') return '该授权已被撤销。';
    return '该授权已被禁用。';
}

// 我的页动作（委托绑定）
const mineActions = {
    login: showLogin,
    register: showRegister,
    bind: showBind,
    purchase: showPurchase,
    resumePayment: resumePendingPayment,
    logout: doLogout,
    lease: doRefreshLease,
    download: doDownload,
    update: doCheckUpdate,
    refresh: forceRefreshAuthorization,
    openPanel: openAuthPanel
};

async function doLogout() {
    const ok = await showConfirm('登出', '确定要登出账号吗？\n仅清除账号 Token，不删除永久授权租约与付费包。');
    if (!ok) return;
    authToken = null;
    try { sessionStorage.removeItem(TOKEN_KEY); } catch (e) { /* ignore */ }
    await ksuExec(handlerCmd('auth_clear_account'), true);
    serverEntitlement = null;
    licenses = null;
    showToast('已登出');
    await refreshAuthState();
    await renderMinePage();
}

async function doRefreshLease() {
    showToast('正在刷新租约…');
    try {
        await refreshLease();
        await refreshAuthState();
        await renderMinePage();
        showToast('租约已刷新');
    } catch (e) {
        showToast('租约刷新失败：' + e.message);
    }
}

async function doDownload() {
    if (downloadBusy) return;
    downloadBusy = true;
    try {
        const pkg = await pickDownloadablePackage();
        if (!pkg) { showToast('暂无可用付费组件'); return; }
        if (pkg.compatible === false) {
            showToast('设备或包不兼容，拒绝下载');
            return;
        }
        await startPackageDownload(pkg.pkg);
    } finally {
        downloadBusy = false;
    }
}

async function doCheckUpdate() {
    return checkForUpdates({ automatic: false });
}

function numericVersionParts(version) {
    const parts = String(version || '').match(/\d+/g);
    return parts ? parts.map(Number) : [];
}

function compareVersions(left, right) {
    const a = numericVersionParts(left);
    const b = numericVersionParts(right);
    const length = Math.max(a.length, b.length);
    for (let i = 0; i < length; i++) {
        const delta = (a[i] || 0) - (b[i] || 0);
        if (delta) return delta > 0 ? 1 : -1;
    }
    return 0;
}

function trustedUpdateUrl(value, kind) {
    const url = String(value || '');
    if (kind === 'zip') {
        return url.startsWith('https://github.com/murongruyan/murongchaopin/releases/download/');
    }
    return url.startsWith('https://github.com/murongruyan/murongchaopin')
        || url.startsWith('https://raw.githubusercontent.com/murongruyan/murongchaopin/');
}

async function fetchBaseUpdateInfo() {
    const raw = await ksuExec(handlerCmd('check_base_update'), true);
    if (!raw || raw.startsWith('Error:')) {
        throw new Error((raw || '更新后端无响应').replace(/^Error:\s*/, ''));
    }
    const values = parseKeyValueOutput(raw);
    let remote;
    try {
        remote = JSON.parse(base64UrlToUtf8(values.remote_json_b64));
    } catch (e) {
        throw new Error('更新信息格式错误');
    }
    const localCode = Number(values.local_version_code);
    const remoteCode = Number(remote.versionCode);
    if (!Number.isInteger(localCode) || localCode < 0
        || !Number.isInteger(remoteCode) || remoteCode <= 0) {
        throw new Error('更新版本号无效');
    }
    if (!trustedUpdateUrl(remote.zipUrl, 'zip')) throw new Error('更新下载地址不受信任');
    if (remote.changelog && !trustedUpdateUrl(remote.changelog, 'changelog')) {
        throw new Error('更新日志地址不受信任');
    }
    const info = {
        localVersion: values.local_version || '—',
        localCode,
        remoteVersion: String(remote.version || remoteCode),
        remoteCode,
        zipUrl: remote.zipUrl,
        changelogUrl: remote.changelog || '',
        available: remoteCode > localCode
    };
    const versionEl = document.getElementById('module-version');
    if (versionEl) versionEl.innerText = `${info.localVersion} (${info.localCode})`;
    return info;
}

async function collectUpdates() {
    const result = { base: null, paid: null, baseError: null, paidError: null };
    try {
        result.base = await fetchBaseUpdateInfo();
    } catch (e) {
        result.baseError = e;
    }
    if (authState.package_installed === 1) {
        try {
            const candidate = await pickDownloadablePackage();
            if (candidate && candidate.compatible !== false) {
                const current = String(authState.package_version || '');
                const remote = String(candidate.pkg.version || '');
                const currentCode = Number(authState.package_version_code || 0);
                const remoteCode = Number(candidate.pkg.version_code || 0);
                const hasValidCodes = Number.isInteger(currentCode) && currentCode > 0
                    && Number.isInteger(remoteCode) && remoteCode > 0;
                if ((hasValidCodes && remoteCode > currentCode)
                    || (!hasValidCodes && (!current || compareVersions(remote, current) > 0))) {
                    result.paid = candidate.pkg;
                }
            }
        } catch (e) {
            result.paidError = e;
        }
    }
    return result;
}

function updateNoticeId(result) {
    const baseCode = result.base && result.base.available ? result.base.remoteCode : 0;
    const paidCode = result.paid ? (result.paid.version_code || result.paid.version || '') : '';
    return `base:${baseCode}|paid:${paidCode}`;
}

async function showAvailableUpdate(result, automatic) {
    const body = document.createElement('div');
    const rows = [];
    if (result.base && result.base.available) {
        rows.push(`<li><span class="kv-label">基础模块</span><span class="kv-value">${esc(result.base.localVersion)} → ${esc(result.base.remoteVersion)}</span></li>`);
    }
    if (result.paid) {
        rows.push(`<li><span class="kv-label">付费组件</span><span class="kv-value">${esc(authState.package_version || '—')} → ${esc(result.paid.version || '—')}</span></li>`);
    }
    const paidNotes = result.paid && String(result.paid.release_notes || '').trim();
    const paidNotesHtml = paidNotes
        ? `<section class="update-release-notes">
            <div class="update-release-notes-title">付费组件更新日志</div>
            <div class="update-release-notes-body">${esc(paidNotes).replace(/\r?\n/g, '<br>')}</div>
        </section>`
        : '';
    body.innerHTML = `
        <div class="notice notice-info">检测到可用更新</div>
        <ul class="kv-list">${rows.join('')}</ul>
        ${paidNotesHtml}
        ${result.base && result.base.available && result.base.changelogUrl ? '<p class="text-hint">基础模块更新日志可在下载页面查看。</p>' : ''}`;
    const buttons = [{ label: '稍后', className: 'btn-secondary', value: 'later' }];
    if (result.base && result.base.available) {
        buttons.push({ label: '下载基础模块', className: 'btn-primary', value: 'base' });
    }
    if (result.paid) {
        buttons.push({ label: '更新付费组件', className: 'btn-primary', value: 'paid' });
    }
    const action = await showModalRaw(automatic ? '发现新版本' : '检查更新', body, buttons);
    if (action === 'base') await openUrl(result.base.zipUrl);
    if (action === 'paid') await startPackageDownload(result.paid);
}

async function checkForUpdates({ automatic = false } = {}) {
    if (updateCheckBusy) return;
    updateCheckBusy = true;
    if (!automatic) showToast('正在检查更新…');
    try {
        const result = await collectUpdates();
        const hasUpdate = Boolean((result.base && result.base.available) || result.paid);
        if (!hasUpdate) {
            if (!automatic) {
                const errors = [result.baseError, result.paidError].filter(Boolean);
                if (errors.length) throw errors[0];
                showToast('基础模块和付费组件均为最新版本');
            }
            return;
        }
        const noticeId = updateNoticeId(result);
        if (automatic) {
            try {
                if (sessionStorage.getItem(UPDATE_NOTICE_SESSION_KEY) === noticeId) return;
                sessionStorage.setItem(UPDATE_NOTICE_SESSION_KEY, noticeId);
            } catch (e) { /* session storage unavailable; still show once per runtime */ }
        }
        await showAvailableUpdate(result, automatic);
    } catch (e) {
        if (!automatic) showToast('检查更新失败：' + e.message);
        else debugLog(`automatic update check failed: ${e.message}`);
    } finally {
        updateCheckBusy = false;
    }
}

function scheduleAutomaticUpdateCheck(attempt = 0) {
    if (automaticUpdateCheckStarted && attempt === 0) return;
    automaticUpdateCheckStarted = true;
    setTimeout(() => {
        const overlayBusy = modalEl() && !modalEl().hidden;
        if (overlayBusy && attempt < 4) {
            scheduleAutomaticUpdateCheck(attempt + 1);
            return;
        }
        checkForUpdates({ automatic: true });
    }, attempt === 0 ? 1200 : 1500);
}

// ============================================================
// 登录 / 注册 / 绑定 / 内置购买
// ============================================================
async function showLogin() {
    const values = await showForm('登录', '使用慕容调度账号登录。密码只经账号接口提交，不落盘。', [
        { id: 'username', label: '用户名', required: true },
        { id: 'password', label: '密码', type: 'password', required: true }
    ], { okLabel: '登录' });
    if (!values) return false;
    showToast('正在登录…');
    try {
        const resp = await apiFetch('user.php?action=login', {
            method: 'POST', form: true,
            body: { username: values.username, password: values.password }
        });
        const data = resp.data || {};
        if (!data.token) throw new Error(resp.message || '登录失败');
        authToken = data.token;
        try { sessionStorage.setItem(TOKEN_KEY, authToken); } catch (e) { /* ignore */ }
        await ksuExec(handlerCmd('auth_save_account', data.username || values.username, String(data.user_id || ''), authToken), true);
        showToast('登录成功');
        await refreshAuthState();
        await refreshServerAuth();
        await renderMinePage();
        await renderVideoPage();
        updatePaidMarkers();
        return true;
    } catch (e) {
        showToast('登录失败：' + e.message);
        return false;
    }
}

async function showRegister() {
    const values = await showForm('注册', '注册后需邮箱验证。', [
        { id: 'username', label: '用户名', required: true },
        { id: 'password', label: '密码', type: 'password', required: true },
        { id: 'email', label: '邮箱', type: 'email', required: true }
    ], { okLabel: '注册' });
    if (!values) return;
    showToast('正在注册…');
    try {
        const resp = await apiFetch('user.php?action=register', {
            method: 'POST', form: true,
            body: { username: values.username, password: values.password, email: values.email }
        });
        const userId = (resp.data && resp.data.user_id) || '';
        showToast('验证码已发送至邮箱');
        const vcode = await showPrompt('邮箱验证', '请输入收到的验证码。', { placeholder: '验证码' });
        if (vcode === null || vcode === undefined) return;
        const verifyBody = userId
            ? { user_id: userId, verification_code: vcode }
            : { email: values.email, verification_code: vcode };
        await apiFetch('user.php?action=verify_email', { method: 'POST', form: true, body: verifyBody });
        showToast('验证成功，请登录');
        await showLogin();
    } catch (e) {
        showToast('注册失败：' + e.message);
    }
}

async function showBind(prefilledKey = '') {
    if (!authToken) {
        const loggedIn = await showLogin();
        if (!loggedIn) return;
    }
    let key = String(prefilledKey || '').trim();
    if (key) {
        const tail = key.slice(-4);
        const confirmed = await showConfirm('绑定本机', `将显示卡密（尾号 ${tail}）绑定到当前设备？`, { okLabel: '确认绑定' });
        if (!confirmed) return;
    } else {
        key = await showPrompt('绑定本机', '请输入完整显示卡密。', { placeholder: 'MOC-XXXX-XXXX-XXXX-XXXX' });
    }
    if (key === null || key === undefined || !key) return;
    if (!deviceInfo || (!deviceInfo.device_id && !deviceInfo.sn && !deviceInfo.device_id_hash)) {
        showToast('无法获取设备信息，请稍后重试');
        return;
    }
    showToast('正在绑定…');
    try {
        const activation = await apiFetch('v1/display/licenses/activate', {
            method: 'POST', auth: true, nonce: true,
            body: {
                card_key: key,
                device_id: deviceInfo.device_id || '',
                sn: deviceInfo.sn || deviceInfo.device_id || '',
                imei1: deviceInfo.imei1 || '',
                imei2: deviceInfo.imei2 || '',
                device_id_hash: deviceInfo.device_id_hash,
                device_model: deviceInfo.device_model || '',
                soc_model: deviceInfo.soc_model || '',
                build_fingerprint: deviceInfo.build_fingerprint || ''
            }
        });
        serverEntitlement = { ...(serverEntitlement || {}), ...(activation.data || {}), status: 'active' };
        try {
            await refreshLease();
        } catch (leaseError) {
            debugLog(`lease refresh after activation failed: ${leaseError.message}`);
        }
        await refreshServerAuth();
        await refreshAuthorizationView();
        showToast('绑定成功');
    } catch (e) {
        showToast('绑定失败：' + e.message);
    }
}

function paymentOverlayEl() { return document.getElementById('payment-overlay'); }

function setPaymentActions(buttons) {
    const el = document.getElementById('payment-actions');
    if (!el) return;
    el.innerHTML = '';
    buttons.forEach(item => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = `btn ${item.className || 'btn-primary'}`;
        button.innerText = item.label;
        button.disabled = item.disabled === true;
        button.onclick = item.onClick;
        el.appendChild(button);
    });
}

function setPaymentTitle(title) {
    const el = document.getElementById('payment-title');
    if (el) el.innerText = title;
}

function beginPaymentHistory() {
    if (paymentHistoryActive) return;
    history.pushState({ kind: 'payment', tab: activeTabId }, '', `#${activeTabId}/payment`);
    paymentHistoryActive = true;
}

function closePaymentOverlay(fromHistory = false) {
    if (paymentClosing) return;
    const hadHistory = paymentHistoryActive;
    paymentHistoryActive = false;
    if (paymentPollTimer) clearInterval(paymentPollTimer);
    paymentPollTimer = null;
    paymentCheckBusy = false;
    const overlay = paymentOverlayEl();
    if (hadHistory && fromHistory !== true) history.back();
    if (!overlay) return;
    paymentClosing = true;
    overlay.classList.add('is-closing');
    const finish = () => {
        overlay.hidden = true;
        overlay.classList.remove('is-closing');
        paymentClosing = false;
    };
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) finish();
    else setTimeout(finish, 190);
}

function openPaymentOverlay() {
    const overlay = paymentOverlayEl();
    if (!overlay) return null;
    overlay.classList.remove('is-closing');
    paymentClosing = false;
    overlay.hidden = false;
    return overlay;
}

function paymentMethodKind(code) {
    const value = String(code || '').trim().toLowerCase();
    return value.includes('ali') || value === 'zfb' ? 'alipay' : 'wechat';
}

function paymentMethodName(method) {
    const fallback = paymentMethodKind(method.code) === 'alipay' ? '支付宝' : '微信支付';
    return String(method.name || fallback);
}

function catalogArray(data, key) {
    if (Array.isArray(data)) return data;
    if (data && Array.isArray(data[key])) return data[key];
    return [];
}

async function loadPaymentCatalog(force = false) {
    if (paymentCatalog && !force) return paymentCatalog;
    const [productResponse, methodResponse] = await Promise.all([
        apiFetch('payment.php?action=products'),
        apiFetch('payment.php?action=payment_methods')
    ]);
    const products = catalogArray(productResponse.data, 'products');
    const methods = catalogArray(methodResponse.data, 'methods')
        .filter(method => method && String(method.code || '').trim())
        .sort((a, b) => (paymentMethodKind(a.code) === 'alipay' ? 0 : 1) - (paymentMethodKind(b.code) === 'alipay' ? 0 : 1));
    const product = products.find(item => item.product_code === 'display_oc_permanent' || item.delivery_type === 'display_cardkey_new');
    if (!product) throw new Error('显示增强商品未上架');
    if (!methods.length) throw new Error('当前没有可用支付方式');
    paymentCatalog = { product, methods };
    return paymentCatalog;
}

async function showPurchase() {
    if (!authToken) {
        const action = await showModalRaw('登录后购买', '使用慕容调度账号登录，支付成功后显示卡密会归属当前账号。', [
            { label: '取消', className: 'btn-secondary', value: 'cancel' },
            { label: '注册', className: 'btn-secondary', value: 'register' },
            { label: '登录', className: 'btn-primary', value: 'login' }
        ]);
        if (action === 'register') await showRegister();
        if (action === 'login' && await showLogin()) return showPurchase();
        return;
    }

    const overlay = paymentOverlayEl();
    const body = document.getElementById('payment-body');
    if (!overlay || !body) return;
    beginPaymentHistory();
    openPaymentOverlay();
    setPaymentTitle('购买授权');
    body.innerHTML = '<div class="loading">正在读取商品与支付方式…</div>';
    setPaymentActions([{ label: '关闭', className: 'btn-secondary', onClick: closePaymentOverlay }]);

    try {
        const catalog = await loadPaymentCatalog();
        renderPurchaseSheet(catalog);
    } catch (error) {
        body.innerHTML = `<div class="error-state">${esc(error.message)}</div>`;
        setPaymentActions([
            { label: '关闭', className: 'btn-secondary', onClick: closePaymentOverlay },
            { label: '重试', className: 'btn-primary', onClick: () => { paymentCatalog = null; showPurchase(); } }
        ]);
    }
}

function renderPurchaseSheet(catalog) {
    const body = document.getElementById('payment-body');
    const product = catalog.product;
    let selectedMethod = catalog.methods[0].code;
    const price = Number(product.price || 20).toFixed(2);
    const description = String(product.description || '永久解锁自制 LTPO、完美禁用 ADFR 与视频动态插帧。');
    body.innerHTML = `
        <div class="payment-price-row">
            <div class="payment-price"><small>¥</small>${esc(price)}</div>
            <span class="payment-permanent">永久授权 · 一机一码</span>
        </div>
        <div class="payment-benefits">
            <div class="payment-benefit">不限模块版本</div>
            <div class="payment-benefit">付费组件更新</div>
            <div class="payment-benefit">账号内可找回</div>
        </div>
        <p class="text-hint">${esc(description)}</p>
        <h4 class="payment-method-title">选择支付方式</h4>
        <div class="payment-methods">
            ${catalog.methods.map((method, index) => `
                <button class="payment-method pay-${paymentMethodKind(method.code)}${index === 0 ? ' active' : ''}" type="button" data-method="${esc(method.code)}">
                    <span class="payment-method-dot"></span>${esc(paymentMethodName(method))}
                </button>`).join('')}
        </div>`;
    body.querySelectorAll('.payment-method').forEach(button => {
        button.onclick = () => {
            selectedMethod = button.dataset.method;
            body.querySelectorAll('.payment-method').forEach(item => item.classList.toggle('active', item === button));
        };
    });
    setPaymentActions([
        { label: '稍后', className: 'btn-secondary', onClick: closePaymentOverlay },
        { label: `支付 ¥${price}`, className: 'btn-primary', onClick: () => createDisplayPaymentOrder(product, selectedMethod) }
    ]);
}

async function createDisplayPaymentOrder(product, methodCode) {
    if (!deviceInfo || (!deviceInfo.device_id && !deviceInfo.sn && !deviceInfo.device_id_hash)) {
        showToast('无法读取本机设备标识，不能创建未绑定授权');
        return;
    }
    setPaymentActions([
        { label: '正在创建订单…', className: 'btn-primary', disabled: true, onClick: () => {} }
    ]);
    try {
        const contact = authState.username || authState.user_id || 'module-webui';
        const response = await apiFetch('payment.php?action=create_order', {
            method: 'POST',
            auth: true,
            form: true,
            body: {
                product_id: String(product.id),
                payment_method: methodCode,
                contact_info: String(contact),
                order_kind: 'display_cardkey_new',
                device_info: JSON.stringify({
                    client: 'module-webui',
                    device_id: (deviceInfo && deviceInfo.device_id) || '',
                    sn: (deviceInfo && (deviceInfo.sn || deviceInfo.device_id)) || '',
                    imei1: (deviceInfo && deviceInfo.imei1) || '',
                    imei2: (deviceInfo && deviceInfo.imei2) || '',
                    order_kind: 'display_cardkey_new',
                    device_id_hash: (deviceInfo && deviceInfo.device_id_hash) || '',
                    device_model: (deviceInfo && deviceInfo.device_model) || '',
                    soc_model: (deviceInfo && deviceInfo.soc_model) || '',
                    build_fingerprint: (deviceInfo && deviceInfo.build_fingerprint) || ''
                })
            }
        });
        const data = response.data || {};
        const accessToken = String(data.order_access_token || data.order_token || data.access_token || '');
        if (!data.order_no || !accessToken) throw new Error('订单响应缺少访问凭据');
        paymentOrder = {
            order_no: String(data.order_no),
            order_access_token: accessToken,
            pay_amount: Number(data.pay_amount || product.price || 20),
            expired_at: String(data.expired_at || ''),
            product_name: String(product.name || '显示增强永久授权'),
            payment_method: methodCode,
            payment_url: String(data.payment_url || ''),
            status: 'pending'
        };
        rememberPaymentOrder(paymentOrder);
        renderPaymentOrder(paymentOrder);
        startPaymentPolling();
    } catch (error) {
        showToast('创建订单失败：' + error.message);
        renderPurchaseSheet(paymentCatalog);
    }
}

function rememberPaymentOrder(order) {
    try {
        sessionStorage.setItem(PAYMENT_ORDER_KEY, JSON.stringify({
            order_no: order.order_no,
            order_access_token: order.order_access_token,
            pay_amount: order.pay_amount,
            expired_at: order.expired_at,
            product_name: order.product_name,
            payment_method: order.payment_method,
            payment_url: order.payment_url || ''
        }));
    } catch (error) { /* ignore */ }
}

function forgetPaymentOrder() {
    try { sessionStorage.removeItem(PAYMENT_ORDER_KEY); } catch (error) { /* ignore */ }
}

function pendingPaymentActionHtml() {
    try {
        return sessionStorage.getItem(PAYMENT_ORDER_KEY)
            ? '<button class="btn btn-secondary btn-block" data-action="resumePayment">继续未完成订单</button>'
            : '';
    } catch (error) {
        return '';
    }
}

function renderPaymentOrder(order) {
    const body = document.getElementById('payment-body');
    const kind = paymentMethodKind(order.payment_method);
    const methodText = kind === 'alipay' ? '支付宝' : '微信支付';
    const assetType = kind === 'alipay' ? 'alipay' : 'wechat';
    setPaymentTitle('等待支付');
    body.innerHTML = `
        <div class="payment-order-meta">
            <div class="payment-order-line"><span>应付金额</span><strong>¥${Number(order.pay_amount || 0).toFixed(2)}</strong></div>
            <div class="payment-order-line"><span>支付方式</span><strong>${methodText}</strong></div>
            <div class="payment-order-line"><span>订单号</span><strong>${esc(order.order_no)}</strong></div>
            <div class="payment-order-line"><span>有效期</span><strong>${esc(order.expired_at || '以服务端为准')}</strong></div>
        </div>
        <div class="payment-qr-wrap">
            <img class="payment-qr" src="${BASE_API}/payment_asset?type=${assetType}" alt="${methodText}收款码">
        </div>
        <div id="payment-live-status" class="payment-live-status">
            <span class="payment-spinner"></span><span>等待到账，页面会自动确认并发放显示卡密</span>
        </div>`;
    setPaymentActions([
        { label: '关闭', className: 'btn-secondary', onClick: closePaymentOverlay },
        { label: `打开${methodText}`, className: 'btn-primary', onClick: () => launchPaymentApp(kind) }
    ]);
}

async function launchPaymentApp(kind) {
    if (kind === 'alipay') {
        const qr = encodeURIComponent('https://qr.alipay.com/fkx19856muvtznqt6onipea');
        await openUrl(`alipayqr://platformapi/startapp?saId=10000007&clientVersion=3.7.0.0718&qrcode=${qr}`);
    } else {
        const cmd = `am start -n com.tencent.mm/com.tencent.mm.plugin.remittance.ui.RemittanceAdapterUI --es 'receiver_name' 'wxp://f2f0Uk7YdwjnrBPrQ85ytbNuR1L4y1GRJz2wzm7cNgl2onU' --ei 'scene' '1' --ei 'pay_channel' '24' >/dev/null 2>&1`;
        await ksuExec(cmd, true);
    }
}

function startPaymentPolling() {
    if (paymentPollTimer) clearInterval(paymentPollTimer);
    checkPaymentOrder();
    paymentPollTimer = setInterval(checkPaymentOrder, 3000);
}

function setPaymentLiveStatus(message, state = 'pending') {
    const el = document.getElementById('payment-live-status');
    if (!el) return;
    el.className = `payment-live-status${state === 'success' ? ' success' : state === 'error' ? ' error' : ''}`;
    el.innerHTML = state === 'pending'
        ? `<span class="payment-spinner"></span><span>${esc(message)}</span>`
        : `<span>${esc(message)}</span>`;
}

async function checkPaymentOrder() {
    if (!paymentOrder || paymentCheckBusy) return;
    paymentCheckBusy = true;
    try {
        const query = new URLSearchParams({
            order_no: paymentOrder.order_no,
            order_access_token: paymentOrder.order_access_token
        });
        const response = await apiFetch(`payment.php?action=order_status&${query.toString()}`);
        const data = response.data || {};
        const status = String(data.status || 'pending').toLowerCase();
        paymentOrder.status = status;
        if (status === 'paid') {
            if (paymentPollTimer) clearInterval(paymentPollTimer);
            paymentPollTimer = null;
            forgetPaymentOrder();
            const paymentData = data.payment_data || {};
            const cardKey = String(paymentData.card_key || '');
            await refreshServerAuth();
            await refreshAuthState();
            renderMinePage();
            renderVideoPage();
            updatePaidMarkers();
            renderPaymentSuccess(cardKey);
        } else if (status === 'expired' || status === 'cancelled' || status === 'delivery_failed') {
            if (paymentPollTimer) clearInterval(paymentPollTimer);
            paymentPollTimer = null;
            forgetPaymentOrder();
            const message = status === 'expired' ? '订单已超时，请重新下单' : status === 'cancelled' ? '订单已取消' : '支付已确认，但卡密交付失败';
            setPaymentLiveStatus(message, 'error');
            setPaymentActions([
                { label: '关闭', className: 'btn-secondary', onClick: closePaymentOverlay },
                { label: '重新购买', className: 'btn-primary', onClick: () => { closePaymentOverlay(); showPurchase(); } }
            ]);
        } else {
            setPaymentLiveStatus('等待到账，页面会自动确认并发放显示卡密');
        }
    } catch (error) {
        setPaymentLiveStatus('网络暂时不可用，正在自动重试');
    } finally {
        paymentCheckBusy = false;
    }
}

function renderPaymentSuccess(cardKey) {
    const body = document.getElementById('payment-body');
    setPaymentTitle('支付成功');
    body.innerHTML = `
        <div class="auth-lock-hero">
            ${ICON.check(40)}
            <h3>显示授权已发放</h3>
            <p class="text-hint">卡密已在支付交付时绑定到本机，授权立即可用。</p>
        </div>
        ${cardKey ? `<div class="payment-license">${esc(cardKey)}</div>` : ''}`;
    setPaymentActions([
        { label: '完成', className: 'btn-primary', onClick: async () => { closePaymentOverlay(); await refreshAuthorizationView({ force: true }); } }
    ]);
}

function resumePendingPayment() {
    try {
        const raw = sessionStorage.getItem(PAYMENT_ORDER_KEY);
        if (!raw) return showPurchase();
        paymentOrder = JSON.parse(raw);
        beginPaymentHistory();
        openPaymentOverlay();
        renderPaymentOrder(paymentOrder);
        startPaymentPolling();
    } catch (error) {
        forgetPaymentOrder();
        showPurchase();
    }
}

// 统一授权面板（点击付费功能时弹出）
function openAuthPanel() {
    const body = document.createElement('div');
    body.innerHTML = `
        <div class="auth-lock-hero">
            ${ICON.lock(40)}
            <h3>需要永久授权</h3>
            <p class="text-hint">显示增强永久授权 · 20 元 · 一机一码</p>
        </div>`;
    const buttons = [];
    if (authState.account !== 'logged_in') {
        buttons.push({ label: '登录 / 注册', className: 'btn-secondary', value: 'login' });
    }
    buttons.push({ label: '输入卡密', className: 'btn-secondary', value: 'bind' });
    buttons.push({ label: '立即购买', className: 'btn-primary', value: 'purchase' });
    showModalRaw('显示增强授权', body, buttons).then(action => {
        if (action === 'login') showLogin();
        else if (action === 'bind') showBind();
        else if (action === 'purchase') showPurchase();
    });
}

// ============================================================
// 付费资源包（下载 / 分块上传 / 校验安装）
// ============================================================
function packagesQuery() {
    return new URLSearchParams({
        device_id: (deviceInfo && deviceInfo.device_id) || '',
        sn: (deviceInfo && (deviceInfo.sn || deviceInfo.device_id)) || '',
        imei1: (deviceInfo && deviceInfo.imei1) || '',
        imei2: (deviceInfo && deviceInfo.imei2) || '',
        device_id_hash: (deviceInfo && deviceInfo.device_id_hash) || '',
        device_model: (deviceInfo && deviceInfo.device_model) || '',
        soc_model: (deviceInfo && deviceInfo.soc_model) || '',
        build_fingerprint: (deviceInfo && deviceInfo.build_fingerprint) || '',
        base_version: (deviceInfo && deviceInfo.base_version) || '',
        kernel: (deviceInfo && deviceInfo.kernel) || '',
        backend: (deviceInfo && deviceInfo.backend) || '',
        channel: 'stable'
    });
}

async function fetchPackages() {
    if (!deviceInfo || (!deviceInfo.device_id && !deviceInfo.sn && !deviceInfo.device_id_hash)) return [];
    const resp = await apiFetch(`v1/display/packages?${packagesQuery().toString()}`, { auth: true });
    return (resp.data || []).filter(p => p.status !== 'disabled');
}

async function pickDownloadablePackage() {
    const pkgs = await fetchPackages();
    if (!pkgs.length) return null;
    const compatible = pkgs.filter(p => p.compatible !== false);
    if (compatible.length) {
        compatible.sort((a, b) => (b.version_code || 0) - (a.version_code || 0));
        return { pkg: compatible[0], compatible: true };
    }
    pkgs.sort((a, b) => (b.version_code || 0) - (a.version_code || 0));
    return { pkg: pkgs[0], compatible: false };
}

async function startPackageDownload(pkg) {
    const term = openFlowModal('下载付费组件');
    try {
        term.log(`资源版本：${pkg.version || '—'}`, 'info');
        term.log(`文件大小：${formatBytes(pkg.file_size)}`, 'info');
        const sha256 = String(pkg.file_sha256 || pkg.sha256 || '').toLowerCase();
        if (!/^[0-9a-f]{64}$/.test(sha256)) throw new Error('版本列表缺少有效 SHA-256');
        term.log('正在通过系统网络通道获取令牌并下载…', 'step');
        const staged = await ksuExec(
            handlerCmd('auth_package_download', String(pkg.id), sha256),
            true,
            210000
        );
        if (!staged.includes('Success:')) {
            throw new Error((staged || '下载后端无响应').replace(/^Error:\s*/, ''));
        }
        const stagedInfo = parseKeyValueOutput(staged);
        const downloadedBytes = Number(stagedInfo.downloaded_bytes || 0);
        term.log(`已下载并校验 ${formatBytes(downloadedBytes)}，开始原子安装…`, 'info');

        term.log('下载完成，正在校验哈希并原子安装…', 'step');
        const commit = await ksuExec(handlerCmd(
            'auth_package_commit',
            sha256,
            String(pkg.id),
            String(pkg.version || ''),
            String(pkg.version_code || '')
        ), true);
        if (!commit.includes('Success')) throw new Error(commit || '安装校验失败（签名/哈希/兼容性不符）');
        term.log('', '');
        term.log('安装成功！重启后生效。', 'done');
        term.setButtons([
            { id: 'reboot', label: '立即重启', cls: 'btn-danger' },
            { id: 'later', label: '稍后重启', cls: 'btn-secondary' }
        ]);
        const act = await term.waitButton();
        term.close();
        if (act === 'reboot') {
            showToast('正在重启设备…');
            await ksuExec('reboot');
        }
    } catch (e) {
        term.log('✖ 下载或安装失败：' + e.message, 'err');
        term.setButtons([{ id: 'ok', label: '知道了', cls: 'btn-secondary' }]);
        await term.waitButton();
        term.close();
    }
    await refreshAuthState();
    await renderMinePage();
    await renderVideoPage();
}

// ============================================================
// 插帧页（付费门禁）
// ============================================================
function renderVideoPage() {
    const authPanel = document.getElementById('video-auth-panel');
    const content = document.getElementById('video-content');
    if (!authPanel || !content) return;

    if (isPremium()) {
        authPanel.hidden = true;
        content.hidden = false;
        if (authState.package_installed === 1) {
            document.getElementById('video-installed').hidden = false;
            const info = document.getElementById('video-package-info');
            if (info) info.hidden = true;
        } else {
            document.getElementById('video-installed').hidden = true;
            const info = document.getElementById('video-package-info');
            if (info) info.hidden = false;
        }
    } else {
        content.hidden = true;
        authPanel.hidden = false;
        renderVideoAuthPanel();
    }
}

async function refreshVideoPageData({ force = false } = {}) {
    if (activeTabId !== 'tab-video' || !isPremium()) return false;
    if (!force && videoDataRefreshedAt > 0
        && Date.now() - videoDataRefreshedAt < VIDEO_DATA_TTL_MS) return true;
    if (videoDataRefreshPromise) return videoDataRefreshPromise;
    videoDataRefreshPromise = (async () => {
        if (authState.package_installed === 1) {
            await loadVideoMotionConfig();
        } else {
            await renderVideoPackageArea();
        }
        videoDataRefreshedAt = Date.now();
        return true;
    })().catch(error => {
        debugLog(`video page refresh failed: ${error.message}`);
        return false;
    }).finally(() => {
        videoDataRefreshPromise = null;
    });
    return videoDataRefreshPromise;
}

function renderVideoAuthPanel() {
    const el = document.getElementById('video-auth-panel');
    if (!el) return;
    el.innerHTML = `
        <h2 class="group-title">显示增强</h2>
        <div class="card auth-panel">
            <div class="auth-lock-hero">
                ${ICON.lock(40)}
                <h3>需要永久授权</h3>
                <p class="text-hint">视频动态插帧、自制 LTPO 与完美禁用 ADFR 属于“显示增强永久授权”（20 元）。</p>
            </div>
            <div class="btn-row">
                <button class="btn btn-primary" data-action="login">登录 / 注册</button>
                <button class="btn btn-secondary" data-action="bind">输入卡密绑定</button>
            </div>
            <button class="btn btn-primary btn-block" data-action="purchase">立即购买</button>
        </div>`;
    el.querySelectorAll('[data-action]').forEach(btn => {
        btn.addEventListener('click', () => {
            const action = btn.dataset.action;
            if (action === 'login') showLogin();
            else if (action === 'bind') showBind();
            else if (action === 'purchase') showPurchase();
        });
    });
}

async function renderVideoPackageArea() {
    const info = document.getElementById('video-package-info');
    if (!info) return;
    if (authState.package_installed === 1) {
        info.hidden = true;
        return;
    }
    info.hidden = false;
    const metaEl = document.getElementById('video-package-meta');
    const notesEl = document.getElementById('video-package-notes');
    metaEl.innerHTML = '<li><span class="kv-label">正在获取资源信息…</span><span class="kv-value"></span></li>';
    notesEl.innerHTML = '';
    try {
        const result = await pickDownloadablePackage();
        if (!result) {
            metaEl.innerHTML = '<li><span class="kv-label">资源</span><span class="kv-value">暂无可用付费组件</span></li>';
            return;
        }
        const pkg = result.pkg;
        const compat = result.compatible !== false;
        const models = (pkg.supported_models || []).join('、') || '—';
        const size = formatBytes(pkg.file_size);
        metaEl.innerHTML = `
            <li><span class="kv-label">版本</span><span class="kv-value">${esc(pkg.version || '—')}</span></li>
            <li><span class="kv-label">大小</span><span class="kv-value">${esc(size)}</span></li>
            <li><span class="kv-label">适配机型</span><span class="kv-value">${esc(models)}</span></li>
            <li><span class="kv-label">兼容性</span><span class="status-badge ${compat ? 'success' : 'error'}">${compat ? '兼容' : '不兼容'}</span></li>`;
        notesEl.innerHTML = `<div class="text-hint">${esc(pkg.release_notes || '')}</div>`;
        if (!compat) {
            notesEl.innerHTML += `<div class="notice notice-danger">当前设备或包不兼容，已拒绝下载。</div>`;
        }
    } catch (e) {
        metaEl.innerHTML = `<li><span class="kv-label">资源</span><span class="kv-value">获取失败：${esc(e.message)}</span></li>`;
    }
}

function setVideoMotionStatus(text, state = '') {
    const badge = document.getElementById('video-motion-status');
    if (!badge) return;
    badge.innerText = text;
    badge.className = 'status-badge';
    if (state) badge.classList.add(state);
}

async function loadVideoMotionConfig() {
    if (!isPremium()) return;
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    try {
        const result = await ksuExec(`sh "${scriptPath}" get_video_motion_config`, true);
        const values = {};
        result.split(/\r?\n/).forEach(line => {
            const separator = line.indexOf('=');
            if (separator > 0) values[line.slice(0, separator)] = line.slice(separator + 1);
        });
        const target = Number(values.target || 0);
        const rates = Array.from(new Set(displayModes
            .filter(mode => mode.width === currentResolutionWidth)
            .map(mode => mode.fps)))
            .filter(rate => Number.isInteger(rate) && rate >= 30)
            .sort((left, right) => left - right);
        const select = document.getElementById('video-motion-target');
        if (select) {
            select.innerHTML = '';
            [0, ...rates].forEach(rate => {
                const option = document.createElement('option');
                option.value = String(rate);
                option.innerText = videoMotionTargetLabel(rate);
                select.appendChild(option);
            });
            if (![0, ...rates].includes(target)) {
                const option = document.createElement('option');
                option.value = String(target);
                option.innerText = videoMotionTargetLabel(target);
                select.appendChild(option);
            }
            select.value = String(target);
        }
        const status = values.status || 'unknown';
        if (status.startsWith('error:')) setVideoMotionStatus('配置错误', 'error');
        else if (status.startsWith('applied:')) setVideoMotionStatus('已挂载', 'success');
        else setVideoMotionStatus('已启用', 'success');
        refreshVideoMotionTargetDetail();
        await loadVideoMotionApps();
    } catch (error) {
        setVideoMotionStatus('读取失败', 'error');
        debugLog(`Video motion load failed: ${error.message}`);
    }
}

function refreshVideoMotionTargetDetail() {
    const select = document.getElementById('video-motion-target');
    const detail = document.getElementById('video-motion-target-detail');
    if (!select || !detail) return;
    const target = Number(select.value);
    if (target === 0) {
        detail.innerText = '播放时读取 mode.txt 第一行，退出后安全恢复同一用户模式。';
    } else if (nativeMemcRates.has(target)) {
        detail.innerText = `${target}Hz 使用 Pixelworks/R1 对应输出路径。`;
    } else {
        detail.innerText = `${target}Hz 使用 R1 扩展输出路径；以真机帧率记录为准。`;
    }
}

async function loadVideoMotionApps() {
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" get_video_motion_apps`, true);
    videoMotionEntries = result.split(/\r?\n/).map(line => {
        const fields = line.split('|');
        if (fields.length !== 4) return null;
        return { packageName: fields[0], vendorRate: fields[1], activity: fields[2], command: fields[3] };
    }).filter(Boolean);
    renderVideoMotionApps();
}

function renderVideoMotionApps() {
    const list = document.getElementById('video-motion-app-list');
    if (!list) return;
    list.innerHTML = '';
    if (videoMotionEntries.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'empty-state';
        empty.innerText = '没有自定义插帧应用';
        list.appendChild(empty);
        return;
    }
    videoMotionEntries.forEach(entry => {
        const row = document.createElement('div');
        row.className = 'video-app-item';
        const info = document.createElement('div');
        const name = document.createElement('div');
        name.className = 'video-app-name';
        name.innerText = entry.packageName;
        const activity = document.createElement('div');
        activity.className = 'video-app-activity';
        activity.innerText = entry.activity;
        const meta = document.createElement('div');
        meta.className = 'video-app-meta';
        meta.innerText = `${entry.vendorRate} Hz · ${videoAppCommandLabel(entry.command)}`;
        info.append(name, activity, meta);
        const actions = document.createElement('div');
        actions.className = 'app-actions';
        const editBtn = document.createElement('button');
        editBtn.type = 'button';
        editBtn.className = 'icon-btn';
        editBtn.innerHTML = ICON.edit();
        editBtn.title = '编辑';
        editBtn.onclick = () => openVideoAppDialog(entry);
        const delBtn = document.createElement('button');
        delBtn.type = 'button';
        delBtn.className = 'icon-btn danger';
        delBtn.innerHTML = ICON.trash();
        delBtn.title = '移除';
        delBtn.onclick = () => removeVideoMotionApp(entry);
        actions.append(editBtn, delBtn);
        row.append(info, actions);
        list.appendChild(row);
    });
}

function videoAppCommandLabel(command) {
    if (command === '258-74-0-0') return 'Netflix HDR';
    return '通用 MEMC';
}

async function openVideoAppDialog(entry) {
    let vendorRate = Number(entry ? entry.vendorRate : 120);
    let command = entry ? entry.command : '258-10-0-0';
    const body = document.createElement('div');
    body.className = 'app-mode-picker';
    body.innerHTML = `
        <div class="form-group">
            <label for="video-edit-package">包名</label>
            <input id="video-edit-package" class="form-input" type="text" autocomplete="off" placeholder="com.example.player" value="${esc(entry ? entry.packageName : '')}">
        </div>
        <div class="form-group">
            <label for="video-edit-activity">播放 Activity</label>
            <input id="video-edit-activity" class="form-input" type="text" autocomplete="off" placeholder="com.example.player/.PlayerActivity" value="${esc(entry ? entry.activity : '')}">
        </div>
        <div class="picker-section">
            <div class="picker-title"><span>插帧刷新率</span><small>${esc(resolutionLabel(currentResolutionWidth))}</small></div>
            <div class="mode-grid app-mode-grid video-rate-grid"></div>
        </div>
        <div class="picker-section">
            <div class="picker-title"><span>R1 命令</span><small>按播放内容选择</small></div>
            <div class="seg seg-2 video-command-seg">
                <button class="seg-btn" type="button" data-command="258-10-0-0">通用 MEMC</button>
                <button class="seg-btn" type="button" data-command="258-74-0-0">Netflix HDR</button>
            </div>
        </div>`;
    renderVideoRateGrid(body.querySelector('.video-rate-grid'), vendorRate, rate => { vendorRate = rate; });
    body.querySelectorAll('[data-command]').forEach(button => {
        button.classList.toggle('active', button.dataset.command === command);
        button.onclick = () => {
            command = button.dataset.command;
            body.querySelectorAll('[data-command]').forEach(item => item.classList.toggle('active', item === button));
        };
    });
    const action = await showModalRaw('编辑插帧应用', body, [
        { label: '取消', className: 'btn-secondary', value: 'cancel' },
        { label: '保存', className: 'btn-primary', value: 'save' }
    ]);
    if (action !== 'save') return;
    const packageName = body.querySelector('#video-edit-package').value.trim();
    const activity = body.querySelector('#video-edit-activity').value.trim();
    if (!/^[A-Za-z0-9._]+\.[A-Za-z0-9._]+$/.test(packageName)
            || !activity.startsWith(`${packageName}/`)
            || !/^[A-Za-z0-9_.$]+$/.test(activity.slice(packageName.length + 1))) {
        showToast('包名或 Activity 格式不正确');
        return;
    }
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" add_video_motion_app ${shellQuote(packageName)} ${shellQuote(activity)} ${vendorRate} ${command}`);
    if (!result.includes('Success:')) {
        showToast(result || '保存自定义插帧应用失败');
        return;
    }
    await loadVideoMotionApps();
    showToast('应用已保存，重启后加载');
}

async function saveVideoMotionApp() {
    if (!isPremium()) { openAuthPanel(); return; }
    const packageName = document.getElementById('video-app-package').value.trim();
    const activity = document.getElementById('video-app-activity').value.trim();
    const vendorRate = Number(document.getElementById('video-app-rate').dataset.value || 0);
    const command = document.getElementById('video-app-command').value;
    if (!/^[A-Za-z0-9._]+\.[A-Za-z0-9._]+$/.test(packageName)
            || !activity.startsWith(`${packageName}/`)
            || !/^[A-Za-z0-9_.$]+$/.test(activity.slice(packageName.length + 1))) {
        showToast('包名或 Activity 格式不正确');
        return;
    }
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" add_video_motion_app ${shellQuote(packageName)} ${shellQuote(activity)} ${vendorRate} ${command}`);
    if (!result.includes('Success:')) {
        showToast(result || '保存自定义插帧应用失败');
        return;
    }
    document.getElementById('video-app-package').value = '';
    document.getElementById('video-app-activity').value = '';
    setVideoAppPickerValue('');
    await loadVideoMotionApps();
    showToast('应用已保存，重启后加载');
}

async function saveVideoMotionTarget() {
    if (!isPremium()) { openAuthPanel(); return; }
    const select = document.getElementById('video-motion-target');
    if (!select) return;
    const target = Number(select.value);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" set_video_motion_target ${target}`);
    if (result.includes('Success:')) {
        showToast('插帧目标已保存，播放时生效');
        await loadVideoMotionConfig();
    } else {
        showToast(result || '插帧目标保存失败');
    }
}

async function readForegroundVideoActivity() {
    if (!isPremium()) { openAuthPanel(); return; }
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const packageInput = document.getElementById('video-app-package');
    const selectedPackage = packageInput ? packageInput.value.trim() : '';
    const action = /^[A-Za-z0-9._]+\.[A-Za-z0-9._]+$/.test(selectedPackage)
        ? `get_recent_activity ${shellQuote(selectedPackage)}`
        : 'get_foreground_activity';
    const activity = (await ksuExec(`sh "${scriptPath}" ${action}`)).trim().split(/\s+/)[0];
    if (!activity.includes('/')) {
        showToast(selectedPackage ? '没有找到该应用最近的播放 Activity' : '没有读取到前台 Activity');
        return;
    }
    document.getElementById('video-app-package').value = activity.split('/')[0];
    document.getElementById('video-app-activity').value = activity;
    setVideoAppPickerValue(activity.split('/')[0]);
    showToast('已识别播放 Activity');
}

async function selectVideoApp(packageName) {
    const packageInput = document.getElementById('video-app-package');
    const activityInput = document.getElementById('video-app-activity');
    if (!packageInput || !packageName) return;
    packageInput.value = packageName;
    if (activityInput) activityInput.value = '';
    setVideoAppPickerValue(packageName);
    await readForegroundVideoActivity();
}

function renderVideoAppPicker() {
    const picker = document.getElementById('video-app-picker');
    if (!picker) return;
    const current = picker.dataset.value || document.getElementById('video-app-package')?.value.trim() || '';
    setVideoAppPickerValue(current);
}

function setVideoAppPickerValue(packageName) {
    const picker = document.getElementById('video-app-picker');
    const label = document.getElementById('video-app-picker-label');
    if (!picker || !label) return;
    picker.dataset.value = packageName || '';
    label.innerText = packageName ? `${appLabels[packageName] || packageName} · ${packageName}` : '选择应用';
}

function videoRateOptions(current = 0) {
    const rates = Array.from(new Set(displayModes
        .filter(mode => mode.width === currentResolutionWidth)
        .map(mode => Number(mode.fps))))
        .filter(rate => Number.isInteger(rate) && rate >= 30 && rate <= 1000);
    if (Number.isInteger(Number(current)) && Number(current) >= 30 && !rates.includes(Number(current))) {
        rates.push(Number(current));
    }
    return rates.sort((left, right) => left - right);
}

function renderVideoRateGrid(container, selectedRate, onSelect) {
    if (!container) return;
    const rates = videoRateOptions(selectedRate);
    container.innerHTML = rates.map(rate => {
        const native = rate !== 123 && rate <= 144;
        return `<button class="mode-item app-mode-item${Number(selectedRate) === rate ? ' selected' : ''}" type="button" data-video-rate="${rate}">
            <span class="mode-fps">${rate}<small>Hz</small></span>
            <span class="origin-badge ${native ? 'origin-native' : 'origin-overclock'}">${native ? '原生' : '超频'}</span>
        </button>`;
    }).join('');
    container.querySelectorAll('[data-video-rate]').forEach(button => {
        button.onclick = () => {
            const rate = Number(button.dataset.videoRate);
            container.querySelectorAll('[data-video-rate]').forEach(item => item.classList.toggle('selected', item === button));
            onSelect(rate);
        };
    });
}

function setVideoAppRate(rate) {
    const trigger = document.getElementById('video-app-rate');
    const label = document.getElementById('video-app-rate-label');
    if (!trigger || !label) return;
    trigger.dataset.value = String(rate);
    label.innerText = `${rate} Hz`;
}

async function openVideoRatePicker() {
    const trigger = document.getElementById('video-app-rate');
    let selected = Number(trigger?.dataset.value || 120);
    const body = document.createElement('div');
    body.className = 'selection-dialog';
    const grid = document.createElement('div');
    grid.className = 'mode-grid app-mode-grid video-rate-grid';
    body.appendChild(grid);
    renderVideoRateGrid(grid, selected, rate => {
        selected = rate;
        finishModal(String(rate));
    });
    const result = await showModalRaw('选择插帧刷新率', body, [
        { label: '取消', className: 'btn-secondary', value: null }
    ]);
    if (result) setVideoAppRate(Number(result));
}

async function openVideoAppPicker() {
    const body = document.createElement('div');
    body.className = 'selection-dialog';
    const search = document.createElement('input');
    search.className = 'form-input selection-search';
    search.type = 'search';
    search.placeholder = '搜索应用名或包名';
    search.autocomplete = 'off';
    const list = document.createElement('div');
    list.className = 'selection-list';
    body.append(search, list);

    const render = () => {
        const term = search.value.trim().toLowerCase();
        const packages = allPackages.filter(pkg => !term
            || pkg.toLowerCase().includes(term)
            || String(appLabels[pkg] || '').toLowerCase().includes(term));
        if (!packages.length) {
            list.innerHTML = '<div class="empty-state">未找到匹配的应用</div>';
            return;
        }
        list.innerHTML = packages.map(pkg => `
            <button class="selection-row" type="button" data-package="${esc(pkg)}">
                <img class="selection-app-icon" src="ksu://icon/${encodeURIComponent(pkg)}" alt="" loading="lazy">
                <span class="selection-app-copy">
                    <strong class="selection-app-name">${esc(appLabels[pkg] || pkg)}</strong>
                    <small>${esc(pkg)}</small>
                </span>
            </button>`).join('');
        list.querySelectorAll('[data-package]').forEach(button => {
            button.onclick = () => finishModal(button.dataset.package);
        });
    };
    search.addEventListener('input', render);
    render();
    const result = await showModalRaw('选择已安装应用', body, [
        { label: '取消', className: 'btn-secondary', value: null }
    ]);
    if (result) await selectVideoApp(result);
}

async function removeVideoMotionApp(entry) {
    const confirmed = await showConfirm('移除插帧应用', `${entry.packageName}\n${entry.activity}`, { danger: true });
    if (!confirmed) return;
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" remove_video_motion_app ${shellQuote(entry.packageName)} ${shellQuote(entry.activity)}`);
    if (!result.includes('Success:')) {
        showToast(result || '移除失败');
        return;
    }
    await loadVideoMotionApps();
    showToast('应用已移除，重启后加载');
}

async function rebootForVideoMotionConfig() {
    const confirmed = await showConfirm('重启加载插帧配置', 'ColorOS 将在重启后重新读取 Pixelworks 应用白名单。');
    if (!confirmed) return;
    showToast('正在重启设备…');
    await ksuExec('reboot');
}

// ============================================================
// 超频页：系统状态 / 显示策略 / 自定义超频
// ============================================================
async function loadSystemStatus() {
    // 槽位
    try {
        const slot = await ksuExec("getprop ro.boot.slot_suffix");
        const el = document.getElementById('sys-slot');
        if (el) el.innerText = slot || "未知";
    } catch (e) { /* ignore */ }

    // 当前刷新率
    try {
        const fpsRaw = await ksuExec("dumpsys display | grep -oE 'fps=[0-9.]+' | head -n1");
        const fps = fpsRaw.split('=')[1] || "未知";
        const el = document.getElementById('sys-fps');
        if (el) el.innerText = fps;
    } catch (e) { /* ignore */ }

    // 型号
    try {
        const model = await ksuExec("getprop ro.product.vendor.model");
        const el = document.getElementById('sys-model');
        if (el) el.innerText = model || "Unknown";
    } catch (e) { /* ignore */ }

    // 原厂备份
    const backupBadge = document.getElementById('sys-backup');
    const restoreBtn = document.getElementById('btn-restore');
    if (backupBadge) { backupBadge.innerText = "检查中…"; backupBadge.className = "status-badge"; }
    try {
        const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
        const checkBackup = await ksuExec(`sh "${scriptPath}" check_backup`);
        if (backupBadge && restoreBtn) {
            if (!checkBackup) {
                backupBadge.innerText = "未知";
                backupBadge.className = "status-badge warning";
            } else if (checkBackup.trim().startsWith("INVALID")) {
                backupBadge.innerText = "备份已损坏";
                backupBadge.className = "status-badge error";
                restoreBtn.disabled = true;
            } else if (checkBackup.trim().startsWith("VALID")) {
                backupBadge.innerText = "原厂校验通过";
                backupBadge.className = "status-badge success";
                restoreBtn.disabled = false;
            } else {
                backupBadge.innerText = "未找到";
                backupBadge.className = "status-badge error";
            }
        }
    } catch (e) {
        if (backupBadge) backupBadge.innerText = "出错";
    }
}

function renderDisplayPolicy(policy, activePolicy = policy, busy = false, profile = displayPolicyProfile) {
    displayPolicyProfile = profile === 'vendor_ltpo' ? 'vendor_ltpo' : 'rmx5200';
    const isRmx5200 = displayPolicyProfile === 'rmx5200';
    const policies = isRmx5200
        ? ['stock_ltps', 'custom_ltpo', 'adfr_off']
        : ['stock_ltpo', 'adfr_off'];
    const defaultPolicy = isRmx5200 ? 'stock_ltps' : 'stock_ltpo';
    const selected = policies.includes(policy) ? policy : defaultPolicy;
    const labels = {
        stock_ltps: '原厂 LTPS',
        stock_ltpo: '原厂 LTPO',
        custom_ltpo: '自制 LTPO',
        adfr_off: '完美禁用 ADFR'
    };
    const status = document.getElementById('policy-status');
    const stockButton = document.getElementById('btn-policy-stock');
    const customButton = document.getElementById('btn-policy-custom');
    const seg = document.querySelector('#policy-card .seg');

    if (stockButton) stockButton.innerText = labels[defaultPolicy];
    if (customButton) customButton.hidden = !isRmx5200;
    if (seg) seg.className = `seg ${isRmx5200 ? 'seg-3' : 'seg-2'}`;

    if (status) {
        const pending = policies.includes(activePolicy) && activePolicy !== selected;
        status.innerText = busy ? '保存中' : `${labels[selected]}${pending ? ' · 待重启' : ''}`;
        status.className = pending ? 'status-badge warning' : 'status-badge success';
    }

    const selectedButtonId = (selected === 'stock_ltpo' || selected === 'stock_ltps')
        ? 'btn-policy-stock'
        : (selected === 'custom_ltpo' ? 'btn-policy-custom' : 'btn-policy-adfr');
    document.querySelectorAll('#policy-card .seg-btn').forEach((button) => {
        button.classList.toggle('active', button.id === selectedButtonId);
        button.disabled = busy;
    });
}

async function loadAdfrPolicy() {
    const control = document.getElementById('policy-card');
    if (!control) return;
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" get_display_policy`, true);
    const state = parseKeyValueOutput(result);
    const supported = state.supported === '1'
        && ['rmx5200', 'vendor_ltpo'].includes(state.profile);
    control.hidden = !supported;
    if (!supported) return;
    renderDisplayPolicy(state.policy, state.active, false, state.profile);
}

async function setDisplayPolicy(policy) {
    const paidPolicies = ['custom_ltpo', 'adfr_off'];
    if (paidPolicies.includes(policy) && !isPremium()) {
        openAuthPanel();
        return;
    }
    const policies = displayPolicyProfile === 'rmx5200'
        ? ['stock_ltps', 'custom_ltpo', 'adfr_off']
        : ['stock_ltpo', 'adfr_off'];
    if (!policies.includes(policy)) return;
    if (adfrPolicyBusy) return;
    adfrPolicyBusy = true;
    renderDisplayPolicy(policy, policy, true);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    try {
        const result = await ksuExec(`sh "${scriptPath}" set_display_policy "${policy}"`);
        if (!result.includes('Success:')) {
            await showConfirm('刷新率策略', result || '保存失败', { okLabel: '知道了', single: true });
        } else {
            await showConfirm('需要重启', '刷新率策略已保存，重启设备后生效。', { okLabel: '知道了', single: true });
        }
    } finally {
        adfrPolicyBusy = false;
        await loadAdfrPolicy();
    }
}

function renderDtsBackend(backend, status = 'unknown') {
    currentDtsBackend = ['dtbo', 'drm'].includes(backend) ? backend : 'dtbo';
    document.querySelectorAll('#tab-oc .seg-2 .seg-btn').forEach((button) => {
        if (button.id === 'btn-backend-dtbo' || button.id === 'btn-backend-drm') {
            button.classList.toggle('active', button.id === `btn-backend-${currentDtsBackend}`);
        }
    });

    const badge = document.getElementById('dts-backend-status');
    if (!badge) return;
    const labels = { dtbo: 'DTBO', drm: 'DRM-KO' };
    let stateText = status;
    if (status === 'unknown') stateText = '未探测';
    else if (status === 'ready') stateText = '已准备';
    else if (status === 'applied' || status.startsWith('applied:')) stateText = '已应用';
    else if (status.startsWith('skipped:')) stateText = '使用 DTBO';
    else if (status.startsWith('unsupported:')) stateText = '不可用';
    else if (status.startsWith('error:')) stateText = '错误';
    badge.innerText = `${labels[currentDtsBackend]} · ${stateText}`;
    badge.className = 'status-badge';
    if (status === 'ready' || status === 'applied' || status.startsWith('applied:') || status.startsWith('skipped:')) {
        badge.classList.add('success');
    } else if (status.startsWith('unsupported:') || status.startsWith('error:')) {
        badge.classList.add('error');
    } else {
        badge.classList.add('warning');
    }
    renderOcCopy();
}

function renderOcCopy() {
    const isDrm = currentDtsBackend === 'drm';
    const set = (id, text) => { const el = document.getElementById(id); if (el) el.innerText = text; };
    set('btn-oc-scan', isDrm ? '读取当前 DRM 节点' : '扫描工作区');
    set('btn-oc-reextract', isDrm ? '重新读取运行配置' : '重新提取 DTBO');
    set('btn-oc-auto', isDrm ? '初始化 KO 默认节点' : '自动修改 DTBO');
    set('btn-oc-apply', isDrm ? '应用配置并整机重启' : '应用并写入 DTBO');
    set('btn-oc-smart', isDrm ? '按当前 KO 节点预设添加并应用' : '按机型预设添加并应用');
    const customHint = document.getElementById('oc-custom-hint');
    if (customHint) {
        customHint.innerText = isDrm
            ? '添加自定义档位写入 DRM-KO 运行规格；可选择原生基准 timing，并覆盖时钟与传输时间。'
            : '添加自定义档位可选基准节点，并可覆盖时钟与传输时间；留空时由模块按基准等比计算。';
    }
    const smartHint = document.getElementById('oc-smart-hint');
    if (smartHint) {
        smartHint.innerText = isDrm
            ? '按当前机型的常用高刷档补齐运行时节点，随后标记为重启加载；手动调试参数时请用“添加”。'
            : '按当前机型的常用高刷档补齐 DTBO 节点并直接执行应用；手动调试参数时请用“添加”。';
    }
    const hint = document.getElementById('oc-hint');
    if (hint) {
        hint.innerText = isDrm
            ? 'DRM-KO 通过运行时 mode_specs 复制 Qualcomm timing；DTBO 仅保留免费风驰兼容节点。'
            : '“扫描”仅读取现有工作区；“重新提取”会覆盖现有工作区（慎用）。';
    }
}

async function loadDtsBackend() {
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" get_dts_backend`);
    const backend = (result.match(/^backend=(dtbo|drm)$/m) || [])[1] || 'dtbo';
    const status = (result.match(/^status=(.+)$/m) || [])[1] || 'unknown';
    renderDtsBackend(backend, status.trim());
}

async function setDtsBackend(backend) {
    if (!['dtbo', 'drm'].includes(backend) || dtsBackendBusy) return;
    if (backend === currentDtsBackend) return;
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const buttons = ['btn-backend-dtbo', 'btn-backend-drm']
        .map(id => document.getElementById(id)).filter(Boolean);
    dtsBackendBusy = true;
    buttons.forEach(button => { button.disabled = true; });
    const badge = document.getElementById('dts-backend-status');
    if (badge) badge.innerText = '正在保存';
    try {
        const result = await ksuExec(`sh "${scriptPath}" set_dts_backend "${backend}"`, false, 15000);
        if (!result.includes('Success:')) {
            await showConfirm('设置失败', result || '后端设置无输出', { okLabel: '知道了', single: true });
            return;
        }
        renderDtsBackend(backend, 'ready');
        await showConfirm('后端已选择', '点击下方“应用”后写入配套 DTBO，整机重启后切换生效。', { okLabel: '知道了', single: true });
    } finally {
        dtsBackendBusy = false;
        buttons.forEach(button => { button.disabled = false; });
        await loadDtsBackend();
    }
}

// 扫描工作区 / 读取当前 DRM 节点
async function scanWorkspace() {
    showToast('正在扫描…');
    document.getElementById('oc-manager').hidden = false;
    await scanRates();
}

// 重新提取 DTBO / 重新读取运行配置
async function reextractWorkspace() {
    if (currentDtsBackend === 'drm') {
        showToast('正在重新读取运行配置…');
        const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
        await ksuExec(`sh "${scriptPath}" probe_display_backend`, true);
        await loadDtsBackend();
        await scanRates();
        return;
    }
    const confirmed = await showConfirm("重新提取确认", "确定要重新提取 DTBO 吗？\n\n这将会覆盖当前工作区的所有修改！\n请仅在需要重置或更新底包时使用。", { danger: true });
    if (!confirmed) return;
    await new Promise(resolve => setTimeout(resolve, 100));
    try {
        showToast("正在提取并解包 DTBO…");
        await new Promise(resolve => setTimeout(resolve, 50));
        const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
        const result = await ksuExec(`sh "${scriptPath}" init_workspace`);
        if (result.includes("Success")) {
            showToast("初始化成功！正在扫描…");
            document.getElementById('oc-manager').hidden = false;
            await scanRates();
        } else {
            await showConfirm("失败", "初始化失败:\n" + result, { okLabel: '知道了', single: true });
        }
    } catch (e) {
        await showConfirm("错误", "执行出错: " + e.message, { okLabel: '知道了', single: true });
    }
}

// 自动修改 DTBO / 生成更新 KO 模式配置
async function autoProcess() {
    if (currentDtsBackend === 'drm') {
        showToast('正在生成 / 更新 KO 模式配置…');
        const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
        await ksuExec(`sh "${scriptPath}" scan_rates`, true); // 触发 ensure_drm_specs_file 生成默认配置
        await scanRates();
        showToast('KO 模式配置已就绪');
        return;
    }
    const confirmed = await showConfirm("自动处理确认", "确定要执行自动超频处理吗？\n\n这将会根据您的机型自动生成高刷节点。\n建议在“重新提取”后执行一次。");
    if (!confirmed) return;
    await new Promise(resolve => setTimeout(resolve, 100));
    try {
        showToast("正在执行自动处理…");
        await new Promise(resolve => setTimeout(resolve, 50));
        const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
        const result = await ksuExec(`sh "${scriptPath}" auto_process`);
        if (result.includes("Success")) {
            showToast("处理完成！正在刷新列表…");
            await showConfirm("成功", "自动处理已完成！\n\n已根据检测到的机型生成了对应的高刷节点。\n您可以继续手动微调，或直接点击“应用更改”。", { okLabel: '知道了', single: true });
            document.getElementById('oc-manager').hidden = false;
            await scanRates();
        } else {
            await showConfirm("失败", "处理失败:\n" + result, { okLabel: '知道了', single: true });
        }
    } catch (e) {
        await showConfirm("错误", "执行出错: " + e.message, { okLabel: '知道了', single: true });
    }
}

// 一键智能超频（smart_add_rate + start_flash）
async function smartFlash() {
    const title = currentDtsBackend === 'drm' ? '添加节点并应用 DRM-KO' : '按机型预设添加并应用';
    const message = currentDtsBackend === 'drm'
        ? '输入一个额外刷新率后立即应用；留空则直接应用当前 KO 节点配置。'
        : '输入一个额外刷新率后执行机型预设和 DTBO 写入；留空使用机型默认预设。';
    const customRate = await showPrompt(title, message, { placeholder: '留空使用当前配置', type: 'number' });
    if (customRate === null || customRate === undefined) return;
    await flashDtbo(customRate || '');
}

// 扫描节点列表
async function scanRates() {
    const listEl = document.getElementById('rates-list');
    if (!listEl) return;

    listEl.innerHTML = '<div class="loading">正在扫描…</div>';
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" scan_rates`);

    try {
        const jsonStart = result.indexOf('[');
        const jsonEnd = result.lastIndexOf(']') + 1;
        if (jsonStart === -1 || jsonEnd === 0) throw new Error("Invalid JSON output");
        const rates = JSON.parse(result.substring(jsonStart, jsonEnd));
        ocNodes = rates;

        listEl.innerHTML = '';
        if (rates.length === 0) {
            listEl.innerHTML = '<div class="empty-state">未找到刷新率节点</div>';
            return;
        }
        rates.sort((a, b) => a.fps - b.fps);
        rates.forEach(rate => {
            renderNodeRow(listEl, rate);
        });
    } catch (e) {
        console.error("Scan failed:", e);
        listEl.innerHTML = `<div class="error-state">扫描失败: ${esc(e.message)}</div>`;
    }
}

function renderNodeRow(listEl, rate) {
    const row = document.createElement('div');
    row.className = 'node-row';
    const res = (rate.width && rate.height) ? `${rate.width}×${rate.height}` : '—';
    const stab = nodeStability(Number(rate.fps));
    const native = isNativeNode(rate);
    const source = currentDtsBackend === 'drm' && Number(rate.base) > 0
        ? `DRM · ${rate.base}Hz` : nodeOrigin(rate.file);
    const timing = `${rate.clock || '自动'} / ${rate.transfer ? rate.transfer + 'us' : '自动'}`;
    row.innerHTML = `
        <span class="node-cell">${esc(res)}</span>
        <span class="node-cell"><b>${esc(rate.fps)}</b> Hz</span>
        <span class="node-cell">${esc(source)}</span>
        <span class="node-cell">${esc(timing)}</span>
        <span class="node-cell">${esc(stab.text)}</span>
        <span class="node-actions"></span>`;
    const actions = row.querySelector('.node-actions');
    const editBtn = document.createElement('button');
    editBtn.type = 'button';
    editBtn.className = 'icon-btn';
    editBtn.innerHTML = ICON.edit();
    editBtn.title = '编辑';
    editBtn.onclick = () => modifyRate(rate);
    actions.appendChild(editBtn);
    if (!native) {
        const delBtn = document.createElement('button');
        delBtn.type = 'button';
        delBtn.className = 'icon-btn danger';
        delBtn.innerHTML = ICON.trash();
        delBtn.title = '删除';
        delBtn.onclick = () => removeRate(rate.node);
        actions.appendChild(delBtn);
    }
    listEl.appendChild(row);
}

// 添加节点：统一弹窗
async function openAddRateDialog() {
    if (currentDtsBackend === 'drm') {
        const baseOptions = [{ value: '0', label: '自动选择基准 timing' }];
        [...new Set(displayModes
            .filter(mode => mode.width === effectiveWidth() && [60, 90, 120, 144].includes(Number(mode.fps)))
            .map(mode => Number(mode.fps)))]
            .sort((a, b) => a - b)
            .forEach(rate => baseOptions.push({ value: String(rate), label: `${rate}Hz 原生 timing` }));
        const values = await showForm('添加 DRM 刷新率', '运行时复制选定的原生 timing，并可覆盖链路时钟和 MDP 传输时间。', [
            { id: 'base', label: '基准 timing', type: 'select', options: baseOptions, value: '0' },
            { id: 'fps', label: '目标刷新率 (Hz)', type: 'number', placeholder: '例如: 165', required: true },
            { id: 'clock', label: '时钟频率 (Hz, 可选)', type: 'number', placeholder: '自动计算' },
            { id: 'transfer', label: '传输时间 (us, 可选)', type: 'number', placeholder: '自动计算' }
        ], { okLabel: '添加' });
        if (!values) return;
        await addRate(values.base, values.fps, values.clock || '', values.transfer || '');
        return;
    }

    const baseOptions = ocNodes.map(n => ({ value: n.node, label: `${n.fps} Hz (${n.node})` }));
    if (!baseOptions.length) { showToast('请先扫描工作区'); return; }
    const values = await showForm('添加刷新率', '留空时钟/传输时间则由后端按基准节点等比换算。', [
        { id: 'base', label: '基准节点', type: 'select', options: baseOptions, required: true },
        { id: 'fps', label: '目标刷新率 (Hz)', type: 'number', placeholder: '例如: 165', required: true },
        { id: 'clock', label: '时钟频率 (Hz, 可选)', type: 'number', placeholder: '自动计算' },
        { id: 'transfer', label: '传输时间 (µs, 可选)', type: 'number', placeholder: '自动计算' }
    ], { okLabel: '添加' });
    if (!values) return;
    const clockArg = (values.clock && !isNaN(values.clock) && values.clock > 0) ? values.clock : '';
    const transferArg = (values.transfer && !isNaN(values.transfer) && values.transfer > 0) ? values.transfer : '';
    await addRate(values.base, values.fps, clockArg, transferArg);
}

async function addRate(baseNode, targetFps, clockArg = '', transferArg = '') {
    if (!targetFps || isNaN(targetFps) || targetFps <= 0) {
        showToast("请输入有效的目标刷新率");
        return;
    }
    showToast(`正在添加 ${targetFps}Hz…`);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" add_rate "${baseNode}" "${targetFps}" "${clockArg}" "${transferArg}"`);
    if (result.includes("Success") || result.includes("Added")) {
        showToast("添加成功！");
        await scanRates();
    } else {
        await showConfirm("失败", "添加失败:\n" + result, { okLabel: '知道了', single: true });
    }
}

async function modifyRate(rate) {
    const currentFps = Number(rate.fps);
    const currentClock = Number(rate.clock) || 0;
    const currentTransfer = Number(rate.transfer) || 0;
    const fields = [
        { id: 'fps', label: '目标刷新率 (Hz)', type: 'number', value: String(currentFps), required: true }
    ];
    if (currentDtsBackend === 'drm') {
        const baseOptions = [{ value: '0', label: '自动选择基准 timing' }];
        [...new Set(displayModes
            .filter(mode => mode.width === Number(rate.width) && [60, 90, 120, 144].includes(Number(mode.fps)))
            .map(mode => Number(mode.fps)))]
            .sort((a, b) => a - b)
            .forEach(fps => baseOptions.push({ value: String(fps), label: `${fps}Hz 原生 timing` }));
        fields.unshift({ id: 'base', label: '基准 timing', type: 'select', value: String(rate.base || 0), options: baseOptions });
        fields.push(
            { id: 'clock', label: '时钟频率 (Hz, 可选)', type: 'number', value: currentClock > 0 ? String(currentClock) : '' },
            { id: 'transfer', label: '传输时间 (us, 可选)', type: 'number', value: currentTransfer > 0 ? String(currentTransfer) : '' }
        );
    } else {
        fields.push(
            { id: 'clock', label: '时钟频率 (Hz, 可选)', type: 'number', value: currentClock > 0 ? String(currentClock) : '' },
            { id: 'transfer', label: '传输时间 (µs, 可选)', type: 'number', value: currentTransfer > 0 ? String(currentTransfer) : '' }
        );
    }
    const values = await showForm(`修改节点 ${rate.node}`, '修改会先添加新节点再删除旧节点。', fields, { okLabel: '修改' });
    if (!values) return;
    const newFps = values.fps;
    if (!newFps || isNaN(newFps)) return;
    const clockArg = (values.clock && !isNaN(values.clock) && values.clock > 0) ? values.clock : '';
    const transferArg = (values.transfer && !isNaN(values.transfer) && values.transfer > 0) ? values.transfer : '';

    showToast(`正在修改为 ${newFps}Hz…`);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const baseArg = currentDtsBackend === 'drm' ? (values.base || '0') : rate.node;
    const resultAdd = await ksuExec(`sh "${scriptPath}" add_rate "${baseArg}" "${newFps}" "${clockArg}" "${transferArg}"`);
    if (resultAdd.includes("Success") || resultAdd.includes("Added")) {
        if (Number(newFps) === currentFps) {
            showToast('参数已更新，重启后加载');
            await scanRates();
            return;
        }
        showToast(`添加成功，正在删除旧节点…`);
        const resultRem = await ksuExec(`sh "${scriptPath}" remove_rate "${rate.node}"`);
        if (resultRem.includes("Success") || resultRem.includes("Removed")) {
            showToast("修改成功！");
            await scanRates();
        } else {
            await showConfirm("部分完成", "修改部分完成（新节点已添加，但旧节点删除失败）:\n" + resultRem, { okLabel: '知道了', single: true });
            await scanRates();
        }
    } else {
        await showConfirm("失败", "修改失败（添加新节点失败）:\n" + resultAdd, { okLabel: '知道了', single: true });
    }
}

async function removeRate(nodeName) {
    const confirmed = await showConfirm("删除确认", `确定要删除节点 ${nodeName} 吗？`, { danger: true });
    if (!confirmed) return;
    showToast(`正在删除 ${nodeName}…`);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" remove_rate "${nodeName}"`);
    if (result.includes("Success") || result.includes("Removed")) {
        showToast("删除成功！");
        await scanRates();
    } else {
        await showConfirm("失败", "删除失败:\n" + result, { okLabel: '知道了', single: true });
    }
}

// 应用更改（start_apply 后台流式）
async function runApplyChanges() {
    await loadDtsBackend();
    const term = openFlowModal("应用 DTS 更改");
    term.log(`应用后端: ${currentDtsBackend}`, 'step');
    if (currentDtsBackend === 'drm') {
        term.log("  1. 校验 RMX5200 Qualcomm DRM injector", 'info');
        term.log("  2. 重启时按运行时档位自动加载 DRM-KO", 'info');
        term.log("  3. 从原厂基线写入仅含风驰节点的兼容 DTBO", 'info');
        term.log("  4. DTBO 不写高刷 timing；1080p 144Hz 与 WQHD 保留", 'info');
    } else {
        term.log("  1. 打包 new_dtbo.img（合并所有修改）", 'info');
        term.log("  2. 合并官方 AVB 信息", 'info');
        term.log("  3. 写入 DTBO 分区并回读校验", 'info');
    }
    term.log("操作完成后需要重启生效。", 'warn');

    term.setButtons([
        { id: 'start', label: '开始执行', cls: 'btn-danger' },
        { id: 'cancel', label: '取消', cls: 'btn-secondary' }
    ]);
    const action = await term.waitButton();
    if (action !== 'start') { term.close(); return; }

    term.log(""); term.log("========== 开始执行 ==========", 'step');
    await nextPaint();

    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const logPath = `${MOD_DIR}/apply.log`;
    const statusPath = `${MOD_DIR}/apply.status`;

    try {
        const started = await ksuExec(`sh "${scriptPath}" start_apply`);
        term.log(started || "(已启动)", 'info');
        if (!started.includes('Started')) {
            term.log("✖ 无法启动后台任务", 'err');
            term.setButtons([{ id: 'ok', label: '知道了', cls: 'btn-secondary' }]);
            await term.waitButton(); term.close();
            return;
        }
        term.log("⏳ 后台执行中，日志实时刷新…", 'info');
        const status = await pollProcessLog(logPath, statusPath, term);
        if (status === 'SUCCESS') {
            term.log(""); term.log("全部完成，重启后生效。", 'done');
            term.setButtons([
                { id: 'reboot', label: '立即重启', cls: 'btn-danger' },
                { id: 'later', label: '稍后重启', cls: 'btn-secondary' }
            ]);
            const act = await term.waitButton();
            term.close();
            if (act === 'reboot') {
                showToast("正在重启设备…");
                await ksuExec("reboot");
            }
        } else {
            term.log("流程失败，已在安全检查点中止。", 'err');
            term.setButtons([{ id: 'ok', label: '知道了', cls: 'btn-secondary' }]);
            await term.waitButton(); term.close();
        }
    } catch (e) {
        term.log("✖ 异常: " + e.message, 'err');
        term.setButtons([{ id: 'ok', label: '知道了', cls: 'btn-secondary' }]);
        await term.waitButton(); term.close();
    }
    await loadSystemStatus();
}

// 一键智能超频（smart_add_rate + start_flash）
async function runFlashDtbo(customRate) {
    await loadDtsBackend();
    const backendLabels = { dtbo: 'DTBO', drm: 'DRM-KO' };
    const backendLabel = backendLabels[currentDtsBackend] || 'DTBO';
    const term = openFlowModal(`应用超频 (${backendLabel})`);

    term.log("⚠️ 即将执行以下操作：", 'warn');
    term.log("  1. 智能添加刷新率（提取 → 解包 → 补丁）", 'info');
    if (currentDtsBackend === 'drm') {
        term.log("  2. 校验 RMX5200 Qualcomm DRM injector", 'info');
        term.log("  3. 重启时按运行时档位自动加载 DRM-KO", 'info');
        term.log("  4. 从原厂基线写入仅含风驰节点的兼容 DTBO", 'info');
        term.log("  5. DTBO 不写高刷 timing；1080p 144Hz 与 WQHD 保留", 'info');
    } else {
        term.log("  2. 打包 new_dtbo.img", 'info');
        term.log("  3. 合并官方 AVB 签名（免解锁）", 'info');
        term.log("  4. 写入 DTBO 分区并回读校验", 'info');
    }
    if (customRate) {
        term.log(`⚠️ 检测到自定义刷新率: ${customRate}Hz（实验性，可能导致不稳定）`, 'warn');
    }
    term.log("刷入后需要重启生效。请确保已有救砖备份。", 'warn');

    term.setButtons([
        { id: 'start', label: '开始刷写', cls: 'btn-danger' },
        { id: 'cancel', label: '取消', cls: 'btn-secondary' }
    ]);
    const action = await term.waitButton();
    if (action !== 'start') { term.close(); return; }

    term.log(""); term.log("========== 开始执行 ==========", 'step');
    await nextPaint();

    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const logPath = `${MOD_DIR}/apply.log`;
    const statusPath = `${MOD_DIR}/apply.status`;

    try {
        const started = await ksuExec(`sh "${scriptPath}" start_flash "${customRate || ''}"`);
        term.log(started || "(已启动)", 'info');
        if (!started.includes('Started')) {
            term.log("✖ 无法启动后台任务", 'err');
            term.setButtons([{ id: 'ok', label: '知道了', cls: 'btn-secondary' }]);
            await term.waitButton(); term.close();
            return;
        }
        term.log("⏳ 后台执行中，日志实时刷新…", 'info');
        const status = await pollProcessLog(logPath, statusPath, term);
        if (status === 'SUCCESS') {
            term.log(""); term.log("✔ 全部完成！刷写成功，重启后生效。", 'done');
            term.setButtons([
                { id: 'reboot', label: '立即重启', cls: 'btn-danger' },
                { id: 'later', label: '稍后重启', cls: 'btn-secondary' }
            ]);
            const act = await term.waitButton();
            term.close();
            if (act === 'reboot') {
                showToast("正在重启设备…");
                await ksuExec("reboot");
            }
        } else {
            term.log("✖ 流程失败，已中止（DTBO 分区未被修改）", 'err');
            term.setButtons([{ id: 'ok', label: '知道了', cls: 'btn-secondary' }]);
            await term.waitButton(); term.close();
        }
    } catch (e) {
        term.log("✖ 异常: " + e.message, 'err');
        term.setButtons([{ id: 'ok', label: '知道了', cls: 'btn-secondary' }]);
        await term.waitButton(); term.close();
    }
    await loadSystemStatus();
}

// A touch can be delivered twice by some KSU WebUI hosts. Keep one flow per
// page so a duplicate event cannot create a second backend task or replace the
// user's successful log with the lock rejection from the duplicate request.
let displayFlowInFlight = false;
async function applyChanges() {
    if (displayFlowInFlight) {
        showToast('应用任务已在运行，请等待当前流程完成');
        return;
    }
    displayFlowInFlight = true;
    try {
        return await runApplyChanges();
    } finally {
        displayFlowInFlight = false;
    }
}

async function flashDtbo(customRate) {
    if (displayFlowInFlight) {
        showToast('应用任务已在运行，请等待当前流程完成');
        return;
    }
    displayFlowInFlight = true;
    try {
        return await runFlashDtbo(customRate);
    } finally {
        displayFlowInFlight = false;
    }
}

async function restoreDtbo() {
    const confirmed = await showConfirm("恢复确认", "确定要恢复原厂 DTBO 吗？\n\n请确保您有备份文件。", { danger: true });
    if (!confirmed) return;
    await new Promise(resolve => setTimeout(resolve, 100));
    showToast("正在恢复 DTBO，请稍候…");
    await new Promise(resolve => setTimeout(resolve, 50));
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    try {
        const result = await ksuExec(`sh "${scriptPath}" restore_dtbo`);
        if (result.includes("Success")) {
            await showRebootModal("恢复成功", "原厂 DTBO 已恢复。\n请重启设备以生效。");
        } else {
            await showConfirm("失败", "恢复失败:\n" + result, { okLabel: '知道了', single: true });
        }
    } catch (e) {
        await showConfirm("错误", "执行出错: " + e.message, { okLabel: '知道了', single: true });
    }
    await loadSystemStatus();
}

async function uninstallModule() {
    const confirmed = await showConfirm("卸载确认", "确定要卸载此模块吗？\n\n这将会：\n1. 恢复原厂 DTBO（如果存在备份）\n2. 删除模块文件\n3. 重启设备（建议手动重启）\n\n卸载会删除本地 Token、租约与付费资源，但不会自动解绑服务器永久授权。", { danger: true });
    if (!confirmed) return;
    showToast("正在卸载模块…");
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" uninstall_module`);
    if (result.includes("Success")) {
        await showConfirm("成功", "卸载成功！\n模块已移除，请重启设备。", { okLabel: '知道了', single: true });
    } else {
        await showConfirm("失败", "卸载失败:\n" + result, { okLabel: '知道了', single: true });
    }
}

// ============================================================
// 刷新率页：分辨率 / 模式 / 应用独立配置
// ============================================================
function changeResolution(width) {
    currentResolutionWidth = Number(width) === 1440 ? 1440 : 1080;
    renderResolutionSeg();
    const current = displayModes.find(mode => mode.id === currentMode);
    const preferred = current && current.width === currentResolutionWidth
        ? current.fps : 120;
    const target = modeForChoice(currentResolutionWidth, preferred)
        || displayModes.find(mode => mode.width === currentResolutionWidth);
    currentMode = target ? target.id : -1;
    renderDisplayModes();
}

function renderResolutionSeg() {
    ['1080', '1440'].forEach(w => {
        const btn = document.getElementById(`btn-res-${w}`);
        if (btn) btn.classList.toggle('active', currentResolutionWidth === Number(w));
    });
}

function switchRes(res) {
    changeResolution(res === '2k' || res === 1440 ? 1440 : 1080);
}

async function loadDisplayModes() {
    const listEl = document.getElementById('mode-list');
    if (!listEl) return;
    listEl.innerHTML = '<div class="loading">加载显示模式中…</div>';

    const cmd = "dumpsys SurfaceFlinger";
    const raw = await ksuExec(cmd);
    if (!raw) {
        listEl.innerHTML = '<div class="error-state">无法获取显示模式</div>';
        return;
    }

    const lines = raw.split('\n');
    const modeMap = new Map();
    lines.forEach(line => {
        if (line.includes('id=') && line.includes('resolution=') && line.includes('vsyncRate=')) {
            try {
                const idMatch = line.match(/id=(\d+)/);
                if (!idMatch) return;
                const id = parseInt(idMatch[1]);
                const resMatch = line.match(/resolution=(\d+)x(\d+)/);
                if (!resMatch) return;
                const width = parseInt(resMatch[1]);
                const height = parseInt(resMatch[2]);
                const fpsMatch = line.match(/vsyncRate=([0-9.]+)/);
                if (!fpsMatch) return;
                const rawFps = parseFloat(fpsMatch[1]);
                const fps = Math.round(rawFps);
                if (!modeMap.has(id)) {
                    modeMap.set(id, { id, width, height, fps, rawFps });
                }
            } catch (e) { /* ignore */ }
        }
    });

    displayModes = Array.from(modeMap.values());
    displayModes.sort((a, b) => a.fps - b.fps || a.width - b.width);

    const configRaw = await ksuExec(`cat "${CONFIG_FILE}"`);
    const configLines = configRaw.split('\n');
    const globalChoice = parseModeChoice(configLines[0], 1440);
    const globalModeId = globalChoice.modeId;

    appConfigs = {};
    for (let i = 1; i < configLines.length; i++) {
        const line = configLines[i].trim();
        if (!line) continue;
        if (line.includes('=')) {
            const eq = line.indexOf('=');
            const pkg = line.slice(0, eq);
            const choice = parseModeChoice(line.slice(eq + 1), globalChoice.width);
            appConfigs[pkg] = { modeId: choice.modeId, width: choice.width, fps: choice.fps };
            continue;
        }
        const fields = line.split(/\s+/);
        if (fields.length < 2) continue;
        const pkg = fields[0];
        const choice = parseModeChoice(fields.slice(1).join(' '), globalChoice.width);
        if (choice.fps >= 30) {
            appConfigs[pkg] = { modeId: choice.modeId, width: choice.width, fps: choice.fps };
        }
    }

    appliedMode = globalModeId;
    currentMode = globalModeId;

    const currentModeObj = displayModes.find(m => m.id === currentMode);
    currentResolutionWidth = currentModeObj ? currentModeObj.width : (globalChoice.width > 0 ? globalChoice.width : 1080);
    renderResolutionSeg();
    renderDisplayModes();
}

function renderDisplayModes() {
    const listEl = document.getElementById('mode-list');
    if (!listEl) return;
    listEl.innerHTML = '';

    const filteredModes = displayModes.filter(mode => mode.width === currentResolutionWidth);
    const statusEl = document.getElementById('global-status');
    const currentModeObj = displayModes.find(m => m.id === currentMode);
    if (statusEl) {
        if (currentModeObj) {
            statusEl.innerText = `${currentModeObj.fps} Hz`;
            statusEl.className = 'status-badge success';
        } else {
            statusEl.innerText = '未选择';
            statusEl.className = 'status-badge';
        }
    }

    if (filteredModes.length === 0) {
        listEl.innerHTML = '<div class="empty-state">该分辨率下无可用模式</div>';
        return;
    }

    filteredModes.forEach(mode => {
        const item = document.createElement('div');
        const isSelected = mode.id === currentMode;
        const isApplied = mode.id === appliedMode;
        const risk = mode.fps >= 180
            ? '严重风险：RMX5200 样机实测大面积花屏'
            : mode.fps >= 175
                ? '边缘档：RMX5200 样机实测有细线花屏'
                : mode.fps >= 170
                    ? '超出原厂档位：请按屏幕体质测试'
                    : '';
        item.className = `mode-item ${isSelected ? 'selected' : ''}`;
        item.onclick = () => selectMode(mode.id);
        const origin = mode.fps === 123 || mode.fps > 144 ? '超频' : '原生';
        item.innerHTML = `
            <div class="mode-fps">${mode.fps}Hz</div>
            ${risk ? `<div class="mode-risk">${risk}</div>` : ''}
            <div class="mode-meta">
                <span class="origin-badge ${origin === '超频' ? 'origin-overclock' : 'origin-native'}">${origin}</span>
                ${isApplied ? '<span class="status-badge success">当前</span>' : ''}
            </div>`;
        listEl.appendChild(item);
    });
}

function selectMode(id) {
    currentMode = id;
    renderDisplayModes();
}

async function saveGlobalMode() {
    if (currentMode === -1) {
        showToast("请先选择一个模式");
        return;
    }
    showToast("正在保存全局模式…");
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" set_config "${currentMode}"`);
    if (result.includes("Success")) {
        showToast("保存成功！");
        await loadDisplayModes();
    } else {
        showToast("保存失败：" + result);
    }
}

async function refreshAppliedMode() {
    if (document.hidden || activeTabId !== 'tab-rates' || appliedModePollBusy) return;
    appliedModePollBusy = true;
    try {
        const raw = await ksuExec(`head -n 1 "${CONFIG_FILE}"`, true);
        const configuredMode = parseModeChoice(raw.trim(), currentResolutionWidth).modeId;
        if (!Number.isInteger(configuredMode) || configuredMode === appliedMode) return;
        if (!displayModes.some(mode => mode.id === configuredMode)) return;
        const selectionFollowedApplied = currentMode === appliedMode || currentMode === -1;
        appliedMode = configuredMode;
        if (selectionFollowedApplied) {
            currentMode = configuredMode;
            const configuredModeObj = displayModes.find(mode => mode.id === configuredMode);
            if (configuredModeObj) {
                currentResolutionWidth = configuredModeObj.width;
                renderResolutionSeg();
            }
            renderDisplayModes();
        } else {
            renderDisplayModes();
        }
    } finally {
        appliedModePollBusy = false;
    }
}

function startAppliedModePolling() {
    if (appliedModePoll !== null || document.hidden || activeTabId !== 'tab-rates') return;
    appliedModePoll = setInterval(refreshAppliedMode, APPLIED_MODE_POLL_MS);
}

function stopAppliedModePolling() {
    if (appliedModePoll === null) return;
    clearInterval(appliedModePoll);
    appliedModePoll = null;
}

function syncAppliedModePolling() {
    if (!document.hidden && activeTabId === 'tab-rates') startAppliedModePolling();
    else stopAppliedModePolling();
}

function setupLiveRefresh() {
    document.addEventListener('visibilitychange', () => {
        syncAppliedModePolling();
        if (document.hidden) return;
        if (activeTabId === 'tab-rates') refreshAppliedMode();
        if (activeTabId === 'tab-video') refreshVideoPageData({ force: true });
    });
}

// 应用列表
async function loadAppListNow() {
    const listEl = document.getElementById('app-list');
    if (!listEl) return;
    listEl.innerHTML = '<div class="loading">正在加载应用列表…</div>';

    const showSystem = (() => {
        try { return localStorage.getItem(SHOW_SYSTEM_APPS_KEY) === '1'; } catch (e) { return false; }
    })();
    const toggle = document.getElementById('show-system-apps');
    if (toggle) toggle.checked = showSystem;
    const cmd = showSystem
        ? "pm list packages | cut -d: -f2"
        : "pm list packages -3 | cut -d: -f2";
    const raw = await ksuExec(cmd);
    const packages = [...new Set(raw.split('\n').map(p => p.trim()).filter(Boolean))].sort();
    if (packages.length === 0) {
        listEl.innerHTML = `<div class="empty-state">${showSystem ? '未找到应用' : '未找到第三方应用'}</div>`;
        return;
    }
    allPackages = packages;

    if (typeof ksu !== 'undefined' && typeof ksu.getPackagesInfo !== 'undefined') {
        try {
            const batchSize = 50;
            for (let i = 0; i < packages.length; i += batchSize) {
                const batch = packages.slice(i, i + batchSize);
                const infoJson = ksu.getPackagesInfo(JSON.stringify(batch));
                const infoArray = JSON.parse(infoJson);
                if (Array.isArray(infoArray)) {
                    infoArray.forEach(info => {
                        const pkg = info.packageName;
                        const label = info.appLabel || info.label || pkg;
                        if (pkg) appLabels[pkg] = label;
                    });
                }
            }
        } catch (e) { /* ignore */ }
    }

    renderAppList(allPackages);
    renderVideoAppPicker();
    setTimeout(() => {
        if (activeTabId !== 'tab-rates' && activeTabId !== 'tab-video') return;
        allPackages.forEach(pkg => {
            if (!appLabels[pkg]) queueAppLabelFetch(pkg);
        });
    }, 1000);
}

async function ensureAppListLoaded({ force = false } = {}) {
    if (appListLoaded && !force) return true;
    if (appListLoadPromise) return appListLoadPromise;
    appListLoadPromise = loadAppListNow().then(() => {
        appListLoaded = true;
        return true;
    }).catch(error => {
        debugLog(`application list load failed: ${error.message}`);
        return false;
    }).finally(() => {
        appListLoadPromise = null;
    });
    return appListLoadPromise;
}

async function loadAppList() {
    return ensureAppListLoaded();
}

async function toggleSystemApps() {
    const toggle = document.getElementById('show-system-apps');
    try { localStorage.setItem(SHOW_SYSTEM_APPS_KEY, toggle && toggle.checked ? '1' : '0'); } catch (e) { /* ignore */ }
    appListLoaded = false;
    await ensureAppListLoaded({ force: true });
}

function filterAppList() {
    const input = document.getElementById('app-search');
    if (!input) return;
    const term = input.value.trim().toLowerCase();
    if (!term) {
        renderAppList(allPackages);
        return;
    }
    const filtered = allPackages.filter(pkg => {
        if (pkg.toLowerCase().includes(term)) return true;
        if (appLabels[pkg] && appLabels[pkg].toLowerCase().includes(term)) return true;
        const config = appConfigs[pkg];
        if (config) {
            if (String(config.fps).includes(term)
                    || resolutionLabel(config.width || currentResolutionWidth).toLowerCase().includes(term)) {
                return true;
            }
        }
        return false;
    });
    renderAppList(filtered);
}

async function getPackageInfoNewKernelSU(packageName) {
    try {
        if (typeof ksu !== 'undefined' && typeof ksu.getPackageInfo !== 'undefined') {
            const info = ksu.getPackageInfo(packageName);
            if (info && typeof info === 'object') {
                return { appLabel: info.appLabel || info.label || packageName, packageName };
            }
        }
        if (typeof ksu !== 'undefined' && typeof ksu.getPackagesInfo !== 'undefined') {
            try {
                const infoJson = ksu.getPackagesInfo(JSON.stringify([packageName]));
                const infoArray = JSON.parse(infoJson);
                if (infoArray && infoArray[0]) {
                    return { appLabel: infoArray[0].appLabel || infoArray[0].label || packageName, packageName };
                }
            } catch (parseError) { /* ignore */ }
        }
        if (typeof $packageManager !== 'undefined') {
            const info = $packageManager.getApplicationInfo(packageName, 0, 0);
            if (info) {
                return { appLabel: info.getLabel() || packageName, packageName };
            }
        }
        return null;
    } catch (error) {
        return null;
    }
}

async function fetchAppLabel(pkg) {
    if (appLabels[pkg]) return appLabels[pkg];
    const ksuInfo = await getPackageInfoNewKernelSU(pkg);
    if (ksuInfo && ksuInfo.appLabel) {
        appLabels[pkg] = ksuInfo.appLabel;
        updateLabelUI(pkg, ksuInfo.appLabel);
        return ksuInfo.appLabel;
    }
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const label = await ksuExec(`sh "${scriptPath}" get_app_info "${pkg}"`);
    if (label && label.trim()) {
        const cleanLabel = label.trim();
        appLabels[pkg] = cleanLabel;
        updateLabelUI(pkg, cleanLabel);
    } else {
        appLabels[pkg] = pkg;
    }
}

function updateLabelUI(pkg, label) {
    const labelEl = document.getElementById(`label-${pkg}`);
    if (labelEl) labelEl.innerText = label;
    const picker = document.getElementById('video-app-picker');
    if (picker && picker.dataset.value === pkg) setVideoAppPickerValue(pkg);
    document.querySelectorAll('.selection-row[data-package]').forEach(row => {
        if (row.dataset.package !== pkg) return;
        const name = row.querySelector('.selection-app-name');
        if (name) name.innerText = label;
    });
}

async function processLabelQueue() {
    if (processingQueue) return;
    processingQueue = true;
    while (labelQueue.length > 0
        && (activeTabId === 'tab-rates' || activeTabId === 'tab-video')
        && !document.hidden) {
        const batch = labelQueue.splice(0, 3);
        await Promise.all(batch.map(pkg => fetchAppLabel(pkg)));
        await new Promise(r => setTimeout(r, 50));
    }
    processingQueue = false;
}

function queueAppLabelFetch(pkg) {
    if (appLabels[pkg]) return;
    if (!labelQueue.includes(pkg)) {
        labelQueue.push(pkg);
        processLabelQueue();
    }
}

function renderAppList(packages) {
    const listEl = document.getElementById('app-list');
    if (!listEl) return;
    if (!packages.length) {
        listEl.innerHTML = '<div class="empty-state">未找到匹配的应用</div>';
        return;
    }
    listEl.innerHTML = '';
    const fragment = document.createDocumentFragment();
    packages.forEach(pkg => {
        const item = document.createElement('div');
        item.className = 'app-item';

        const config = appConfigs[pkg] || { modeId: -1, width: null, fps: -1 };
        const configuredMode = config.modeId >= 0 ? displayModes.find(mode => mode.id === config.modeId) : null;
        const selectedWidth = config.width || (configuredMode && configuredMode.width) || currentResolutionWidth;
        const selectedFps = config.fps >= 30 ? config.fps : (configuredMode ? configuredMode.fps : -1);
        const policyText = (configuredMode || selectedFps >= 30)
            ? `${resolutionLabel(selectedWidth)} · ${selectedFps >= 30 ? selectedFps + 'Hz' : '默认刷新率'}`
            : '跟随全局';

        const parts = pkg.split('.');
        let displayName = pkg;
        if (parts.length > 1) {
            const last = parts.pop();
            displayName = `${parts.join('.')}.<b>${esc(last)}</b>`;
        } else {
            displayName = esc(displayName);
        }
        if (!appLabels[pkg]) queueAppLabelFetch(pkg);
        const label = esc(appLabels[pkg] || "加载中…");

        item.innerHTML = `
            <div class="app-info">
                <div class="app-name" id="label-${esc(pkg)}">${label}</div>
                <div class="app-pkg">${displayName}</div>
            </div>
            <div class="app-policy">${esc(policyText)}</div>
            <div class="app-actions">
                <button class="icon-btn" title="配置">${ICON.edit()}</button>
                <button class="icon-btn danger" title="删除">${ICON.trash()}</button>
            </div>`;
        const [editBtn, delBtn] = item.querySelectorAll('.icon-btn');
        editBtn.onclick = () => openAppConfigDialog(pkg);
        delBtn.onclick = () => removeAppConfig(pkg);
        fragment.appendChild(item);
    });
    listEl.appendChild(fragment);
}

async function openAppConfigDialog(pkg) {
    const config = appConfigs[pkg] || { modeId: -1, width: null, fps: -1 };
    const configuredMode = config.modeId >= 0 ? displayModes.find(mode => mode.id === config.modeId) : null;
    let resolution = config.width ? String(config.width) : 'default';
    let fps = config.fps >= 30 ? config.fps : (configuredMode ? configuredMode.fps : -1);
    const body = document.createElement('div');
    body.className = 'app-mode-picker';

    const effectiveWidth = () => resolution === 'default' ? currentResolutionWidth : Number(resolution);
    const availableRates = () => Array.from(new Set(displayModes
        .filter(mode => mode.width === effectiveWidth())
        .map(mode => Number(mode.fps))))
        .filter(value => value >= 30)
        .sort((left, right) => left - right);

    const renderPicker = () => {
        const width = effectiveWidth();
        const rates = availableRates();
        if (fps >= 30 && !rates.includes(fps)) fps = -1;
        body.innerHTML = `
            <div class="picker-section">
                <div class="picker-title"><span>分辨率</span><small>${resolution === 'default' ? '继承全局' : '独立设置'}</small></div>
                <div class="seg seg-3 app-resolution-seg">
                    <button class="seg-btn${resolution === 'default' ? ' active' : ''}" type="button" data-resolution="default">跟随全局</button>
                    <button class="seg-btn${resolution === '1080' ? ' active' : ''}" type="button" data-resolution="1080">FHD+</button>
                    <button class="seg-btn${resolution === '1440' ? ' active' : ''}" type="button" data-resolution="1440">QHD+</button>
                </div>
            </div>
            <div class="picker-section">
                <div class="picker-title"><span>刷新率</span><small>${esc(resolutionLabel(width))}</small></div>
                <div class="mode-grid app-mode-grid">
                    <button class="mode-item app-mode-item${fps < 30 ? ' selected' : ''}" type="button" data-fps="-1">
                        <span class="app-mode-main">跟随全局</span>
                        <span class="origin-badge">默认</span>
                    </button>
                    ${rates.map(rate => {
                        const origin = rate === 123 || rate > 144 ? '超频' : '原生';
                        return `<button class="mode-item app-mode-item${fps === rate ? ' selected' : ''}" type="button" data-fps="${rate}">
                            <span class="mode-fps">${rate}<small>Hz</small></span>
                            <span class="origin-badge ${origin === '超频' ? 'origin-overclock' : 'origin-native'}">${origin}</span>
                        </button>`;
                    }).join('')}
                </div>
            </div>`;
        body.querySelectorAll('[data-resolution]').forEach(button => {
            button.onclick = () => {
                resolution = button.dataset.resolution;
                renderPicker();
            };
        });
        body.querySelectorAll('[data-fps]').forEach(button => {
            button.onclick = () => {
                fps = Number(button.dataset.fps);
                body.querySelectorAll('[data-fps]').forEach(item => item.classList.toggle('selected', item === button));
            };
        });
    };

    renderPicker();
    const action = await showModalRaw(appLabels[pkg] || '应用刷新率', body, [
        { label: '取消', className: 'btn-secondary', value: 'cancel' },
        { label: '保存', className: 'btn-primary', value: 'save' }
    ]);
    if (action !== 'save') return;

    if (fps < 30) {
        await saveAppConfig(pkg, -1, resolution);
        return;
    }
    const mode = modeForChoice(effectiveWidth(), fps);
    if (mode) await saveAppConfig(pkg, mode.id, resolution);
    else showToast('未找到对应模式');
}

async function saveAppConfig(pkg, modeId, resolution) {
    showToast(`正在保存 ${pkg} 配置…`);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const mode = displayModes.find(item => item.id === Number(modeId));
    const resolutionArg = resolution && resolution !== 'default'
        ? (resolutionLabel(Number(resolution)).startsWith('2K') ? 'QHD+' : 'FHD+')
        : 'default';
    const result = await ksuExec(`sh "${scriptPath}" set_app_config "${pkg}" "${modeId}" "${resolutionArg}"`);
    if (result.includes("Success")) {
        showToast("保存成功");
        if (modeId == -1) {
            delete appConfigs[pkg];
        } else {
            appConfigs[pkg] = {
                modeId: Number(modeId),
                width: resolutionArg === 'QHD+' ? 1440 : resolutionArg === 'FHD+' ? 1080 : null,
                fps: mode ? mode.fps : -1
            };
        }
        renderAppList(allPackages);
    } else {
        showToast("保存失败");
    }
}

async function removeAppConfig(pkg) {
    const confirmed = await showConfirm('删除应用配置', `确定删除 ${pkg} 的独立配置吗？`, { danger: true });
    if (!confirmed) return;
    await saveAppConfig(pkg, -1, 'default');
}

// ============================================================
// 日志页
// ============================================================
async function refreshLogs() {
    const viewer = document.getElementById('log-viewer');
    if (!viewer) return;
    viewer.value = "正在读取日志…";
    const content = await ksuExec(`tail -n 1000 "${LOG_FILE}"`);
    if (!content || content.trim() === "") {
        viewer.value = "暂无日志或读取失败";
    } else {
        viewer.value = content;
        viewer.scrollTop = viewer.scrollHeight;
    }
}

async function clearLogs() {
    const confirmed = await showConfirm("清空日志", "确定要清空日志吗？");
    if (!confirmed) return;
    await ksuExec(`echo "" > "${LOG_FILE}"`);
    showToast("日志已清空");
    refreshLogs();
}

// ============================================================
// 关于 / 打赏
// ============================================================
async function openUrl(url) {
    await ksuExec(`am start -a android.intent.action.VIEW -d "${url}"`);
}

async function donateWechat() {
    const cmd = `am start -n com.tencent.mm/com.tencent.mm.plugin.remittance.ui.RemittanceAdapterUI \
    --es 'receiver_name' 'wxp://f2f0Uk7YdwjnrBPrQ85ytbNuR1L4y1GRJz2wzm7cNgl2onU' \
    --ei 'scene' '1' \
    --ei 'pay_channel' '24' >/dev/null 2>&1`;
    await ksuExec(cmd);
}

// ============================================================
// 事件绑定与初始化
// ============================================================
function safeBind(id, event, handler) {
    const el = document.getElementById(id);
    if (el) {
        el[event] = handler;
    } else {
        console.warn(`Element #${id} not found for ${event} binding`);
    }
}

function bindStaticEvents() {
    safeBind('btn-restore', 'onclick', restoreDtbo);
    safeBind('btn-uninstall', 'onclick', uninstallModule);
    safeBind('btn-policy-stock', 'onclick', () => setDisplayPolicy(displayPolicyProfile === 'rmx5200' ? 'stock_ltps' : 'stock_ltpo'));
    safeBind('btn-policy-custom', 'onclick', () => setDisplayPolicy('custom_ltpo'));
    safeBind('btn-policy-adfr', 'onclick', () => setDisplayPolicy('adfr_off'));
    safeBind('btn-backend-dtbo', 'onclick', () => setDtsBackend('dtbo'));
    safeBind('btn-backend-drm', 'onclick', () => setDtsBackend('drm'));
    safeBind('btn-oc-scan', 'onclick', scanWorkspace);
    safeBind('btn-oc-reextract', 'onclick', reextractWorkspace);
    safeBind('btn-oc-auto', 'onclick', autoProcess);
    safeBind('btn-oc-apply', 'onclick', applyChanges);
    safeBind('btn-oc-smart', 'onclick', smartFlash);
    safeBind('btn-add-rate', 'onclick', openAddRateDialog);
    safeBind('btn-res-1080', 'onclick', () => changeResolution(1080));
    safeBind('btn-res-1440', 'onclick', () => changeResolution(1440));
    safeBind('btn-save-global', 'onclick', saveGlobalMode);
    safeBind('app-search', 'oninput', filterAppList);
    safeBind('show-system-apps', 'onchange', toggleSystemApps);
    safeBind('btn-save-video-target', 'onclick', saveVideoMotionTarget);
    safeBind('btn-read-video-activity', 'onclick', readForegroundVideoActivity);
    safeBind('video-app-picker', 'onclick', openVideoAppPicker);
    safeBind('video-app-rate', 'onclick', openVideoRatePicker);
    safeBind('btn-save-video-app', 'onclick', saveVideoMotionApp);
    safeBind('btn-reboot-video-config', 'onclick', rebootForVideoMotionConfig);
    safeBind('video-motion-target', 'onchange', refreshVideoMotionTargetDetail);
    safeBind('btn-refresh-logs', 'onclick', refreshLogs);
    safeBind('btn-clear-logs', 'onclick', clearLogs);
    safeBind('btn-toggle-debug', 'onclick', toggleDebug);
    safeBind('theme-system', 'onclick', () => applyTheme('system'));
    safeBind('theme-light', 'onclick', () => applyTheme('light'));
    safeBind('theme-dark', 'onclick', () => applyTheme('dark'));
    safeBind('btn-donate-wechat', 'onclick', donateWechat);
    safeBind('btn-download-package', 'onclick', doDownload);
    safeBind('btn-check-update', 'onclick', doCheckUpdate);
    safeBind('btn-payment-close', 'onclick', closePaymentOverlay);

    const paymentOverlay = paymentOverlayEl();
    if (paymentOverlay) {
        paymentOverlay.addEventListener('click', event => {
            if (event.target === paymentOverlay) closePaymentOverlay();
        });
    }

    // 关于页链接 / 打赏（data-url）
    document.querySelectorAll('a[data-url]').forEach(a => {
        a.addEventListener('click', (e) => {
            e.preventDefault();
            openUrl(a.dataset.url);
        });
    });

    // 我的页动作委托
    const authSection = document.getElementById('auth-section');
    if (authSection) {
        authSection.addEventListener('click', (e) => {
            const btn = e.target.closest('[data-action]');
            if (!btn) return;
            const action = btn.dataset.action;
            if (mineActions[action]) mineActions[action]();
        });
    }
}

function runAfterFirstPaint(task) {
    requestAnimationFrame(() => {
        requestAnimationFrame(() => setTimeout(task, 0));
    });
}

async function initializeModuleData() {
    try {
        await Promise.all([refreshAuthState(), refreshDeviceInfo()]);
        updatePaidMarkers();

        await loadSystemStatus();
        await loadAdfrPolicy();
        await loadDtsBackend();
        await loadDisplayModes();
        renderVideoPage();
        renderMinePage();
        syncAppliedModePolling();
        if (activeTabId === 'tab-rates' || activeTabId === 'tab-video') {
            ensureAppListLoaded();
        }

        // 后台同步服务端授权（不阻塞免费流程）
        if (authToken || authState.account === 'logged_in') {
            refreshAuthorizationView({ force: true }).catch(error => {
                debugLog(`initial authorization sync failed: ${error.message}`);
            });
        }
        if (activeTabId === 'tab-video') refreshVideoPageData({ force: true });
        scheduleAutomaticUpdateCheck();
    } catch (e) {
        console.error("Init failed:", e);
        showToast("初始化失败: " + e.message);
        const listEl = document.getElementById('mode-list');
        if (listEl) {
            listEl.innerHTML = `<div class="error-state">初始化错误：${esc(e.message)}</div>`;
        }
    }
}

function init() {
    try {
        setupTheme();
        setupTabs();
        setupAuthorizationPullRefresh();
        setupLiveRefresh();
        bindStaticEvents();

        // Restore only in-memory state before the first frame. Root bridge and
        // network work starts after two paints so WebUIActivity never enters on
        // a translucent or unresponsive WebView frame.
        try {
            const saved = sessionStorage.getItem(TOKEN_KEY);
            if (saved) authToken = saved;
        } catch (e) { /* ignore */ }

        renderMinePage();
        renderVideoPage();
        updatePaidMarkers();
        runAfterFirstPaint(initializeModuleData);
    } catch (e) {
        console.error("First-frame init failed:", e);
        showToast("初始化失败: " + e.message);
    }
}

// 全局错误捕获
window.onerror = function (msg, url, line, col, error) {
    showToast(`Error: ${msg}`);
    return false;
};

// 兼容旧 WebUI 调用入口
window.switchRes = switchRes;
window.filterAppList = filterAppList;
window.saveAppConfig = saveAppConfig;
window.refreshLogs = refreshLogs;
window.clearLogs = clearLogs;
window.openUrl = openUrl;
window.donateWechat = donateWechat;
window.scanWorkspace = scanWorkspace;
window.reextractWorkspace = reextractWorkspace;
window.scanRates = scanRates;
window.addRate = addRate;
window.modifyRate = modifyRate;
window.removeRate = removeRate;
window.applyChanges = applyChanges;
window.uninstallModule = uninstallModule;
window.restoreDtbo = restoreDtbo;
window.flashDtbo = flashDtbo;
window.toggleDebug = toggleDebug;

window.addEventListener('load', init, { once: true });
