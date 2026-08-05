// main.js

const MODULE_ID = "murongchaopin";
const MOD_DIR = `/data/adb/modules/${MODULE_ID}`;
// 配置文件路径
const CONFIG_FILE = `${MOD_DIR}/config/mode.txt`;
const LOG_FILE = `${MOD_DIR}/daemon.log`;

// 全局状态
let currentMode = 1;
let displayModes = [];
let appList = [];
let appConfigs = {};
let allPackages = []; // Store all packages for search
let appLabels = {}; // Store app labels
let currentResFilter = '1080p'; // '1080p' or '2k'
const labelQueue = [];
let processingQueue = false;

// 调试日志
function debugLog(msg) {
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
    if (el) el.style.display = el.style.display === 'none' ? 'block' : 'none';
}

window.toggleDebug = toggleDebug;

// 兼容 KSU 的 exec 封装（quiet=true 时不刷 debug，用于高频轮询）
async function ksuExec(cmd, quiet = false) {
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
                // 新版 KSU 支持 Promise
                result.then(res => {
                    if (typeof res === 'string') {
                        if (!quiet) debugLog(`[Res] length=${res.length}`);
                        resolve(res);
                    } else {
                        if (!quiet) debugLog(`[Res] stdout length=${res.stdout ? res.stdout.length : 0}`);
                        resolve(res.stdout || "");
                    }
                }).catch(err => {
                    if (!quiet) debugLog(`[Err] ${err}`);
                    console.error("KSU Promise Error:", err);
                    resolve("");
                });
            } else {
                // 旧版 KSU 需要回调
                const callbackName = `cb_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
                
                const timeout = setTimeout(() => {
                    delete window[callbackName];
                    debugLog(`[Timeout] ${cmd}`);
                    console.warn(`Command timed out: ${cmd}`);
                    resolve("Error: Command timed out"); 
                }, 15000); // Increase timeout to 15s for stability

                window[callbackName] = (code, stdout, stderr) => {
                    clearTimeout(timeout);
                    delete window[callbackName];
                    debugLog(`[CB] code=${code} out_len=${stdout ? stdout.length : 0}`);
                    if (code !== 0) {
                         console.error(`Command failed with code ${code}: ${stderr}`);
                         // Return stderr if stdout is empty so we see the error
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

// Toast 提示
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
    setTimeout(() => {
        toast.className = 'ui-toast';
    }, 3000);
}

// 暴露给全局
window.switchRes = switchRes;
window.filterAppList = filterAppList;
window.saveAppConfig = saveAppConfig;

// 全局错误捕获
window.onerror = function(msg, url, line, col, error) {
    showToast(`Error: ${msg}`);
    return false;
};

function safeBind(id, event, handler) {
    const el = document.getElementById(id);
    if (el) {
        el[event] = handler;
    } else {
        console.warn(`Element #${id} not found for ${event} binding`);
    }
}

// 初始化
async function init() {
    try {
        // 绑定 Tab 切换
        setupTabs();
        
        // 绑定功能按钮
        safeBind('btn-flash', 'onclick', flashDtbo);
        safeBind('btn-restore', 'onclick', restoreDtbo);
        safeBind('btn-save-mode', 'onclick', saveGlobalMode);
        
        // 绑定 DTS 管理按钮
        // safeBind('btn-init-workspace', 'onclick', initWorkspace);
        safeBind('btn-scan-dts', 'onclick', scanWorkspace);
        safeBind('btn-reextract', 'onclick', reextractWorkspace);
        safeBind('btn-auto-process', 'onclick', autoProcess);
        safeBind('btn-add-rate', 'onclick', addRate);
        safeBind('btn-apply-changes', 'onclick', applyChanges);

        // 加载数据
        showToast("正在加载模块数据...");
        
        await loadSystemStatus();
        await loadDisplayModes();
        
        // 延迟加载应用列表
        setTimeout(loadAppList, 500);

    } catch (e) {
        console.error("Init failed:", e);
        showToast("初始化失败: " + e.message);
        const listEl = document.getElementById('mode-list');
        if (listEl) {
            listEl.innerHTML = `<div class="error">
                <h3>初始化错误</h3>
                <p>${e.message}</p>
                <pre style="font-size:10px; text-align:left; overflow:auto;">${e.stack || "No stack trace"}</pre>
            </div>`;
        }
    }
}

function setupTabs() {
    const tabs = document.querySelectorAll('.tab-btn');
    const contents = document.querySelectorAll('.tab-content');

    tabs.forEach(tab => {
        tab.addEventListener('click', () => {
            tabs.forEach(t => t.classList.remove('active'));
            contents.forEach(c => c.classList.remove('active'));
            
            tab.classList.add('active');
            const targetId = tab.getAttribute('data-tab');
            document.getElementById(targetId).classList.add('active');

            // 自动刷新日志
            if (targetId === 'tab-logs') {
                refreshLogs();
            }

            // FAB visibility
            const fab = document.getElementById('btn-save-mode');
            if (fab) {
                if (targetId === 'tab-rates') {
                    fab.style.display = 'flex';
                } else {
                    fab.style.display = 'none';
                }
            }
        });
    });
}

// 加载系统状态
async function loadSystemStatus() {
    debugLog("loadSystemStatus: start");
    
    // 1. Slot
    try {
        const slot = await ksuExec("getprop ro.boot.slot_suffix");
        const slotEl = document.getElementById('slot-info');
        if (slotEl) slotEl.innerText = slot || "未知";
        debugLog(`Slot loaded: ${slot}`);
    } catch (e) {
        debugLog(`Slot error: ${e.message}`);
    }

    // 2. FPS
    try {
        const fpsRaw = await ksuExec("dumpsys display | grep -oE 'fps=[0-9.]+' | head -n1");
        const fps = fpsRaw.split('=')[1] || "未知";
        const fpsEl = document.getElementById('fps-info');
        if (fpsEl) fpsEl.innerText = fps;
        debugLog(`FPS loaded: ${fps}`);
    } catch (e) {
        debugLog(`FPS error: ${e.message}`);
    }

    // Model Detection
    try {
        const model = await ksuExec("getprop ro.product.vendor.model");
        const modelEl = document.getElementById('model-info');
        if (modelEl) modelEl.innerText = model || "Unknown";
        debugLog(`Model loaded: ${model}`);
    } catch (e) {
        debugLog(`Model error: ${e.message}`);
    }

    // 3. Backup Check
    const backupBadge = document.getElementById('backup-info');
    if (backupBadge) backupBadge.innerText = "检查中..."; 

    try {
        debugLog("Starting backup check...");
        const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
        
        // Use web_handler which is safer than complex shell commands
        const checkBackup = await ksuExec(`sh "${scriptPath}" check_backup`);
        debugLog(`Backup raw result: '${checkBackup}'`);
        
        const restoreBtn = document.getElementById('btn-restore');
        
        if (backupBadge && restoreBtn) {
            if (!checkBackup) {
                 // Empty result usually means command failed or timed out
                 backupBadge.innerText = "未知";
                 backupBadge.className = "status-badge warning";
                 // restoreBtn.disabled = true; // 改为点击时提示
            } else if (checkBackup.includes("EXIST")) {
                backupBadge.innerText = "已存在";
                backupBadge.className = "status-badge success";
                restoreBtn.disabled = false;
            } else {
                // Includes NONE or anything else
                backupBadge.innerText = "未找到";
                backupBadge.className = "status-badge error";
                // restoreBtn.disabled = true; // 改为点击时提示
            }
        }
    } catch (e) {
        console.error("Backup check error:", e);
        debugLog(`Backup error: ${e.message}`);
        if (backupBadge) backupBadge.innerText = "出错";
    }
    debugLog("loadSystemStatus: end");
}

// 切换分辨率筛选
function switchRes(res) {
    currentResFilter = res;
    
    // 更新按钮状态
    document.querySelectorAll('.res-btn').forEach(btn => {
        if (btn.id === `btn-res-${res}`) btn.classList.add('active');
        else btn.classList.remove('active');
    });

    renderDisplayModes();
}

// 加载显示模式
async function loadDisplayModes() {
    const listEl = document.getElementById('mode-list');
    if (!listEl) return;
    
    listEl.innerHTML = '<div class="loading">加载显示模式中...</div>';

    // 使用 dumpsys SurfaceFlinger 解析模式 (HWC)
    // 匹配格式: id=0, ... resolution=1264x2780 ... vsyncRate=120.000000
    const cmd = "dumpsys SurfaceFlinger";
    const raw = await ksuExec(cmd);
    
    if (!raw) {
        listEl.innerHTML = '<div class="error">无法获取显示模式</div>';
        return;
    }

    const lines = raw.split('\n');
    const modeMap = new Map();

    lines.forEach(line => {
        // 筛选包含关键信息的行
        if (line.includes('id=') && line.includes('resolution=') && line.includes('vsyncRate=')) {
            try {
                // 提取 id
                const idMatch = line.match(/id=(\d+)/);
                if (!idMatch) return;
                const id = parseInt(idMatch[1]);

                // 提取分辨率 resolution=WxH
                const resMatch = line.match(/resolution=(\d+)x(\d+)/);
                if (!resMatch) return;
                const width = parseInt(resMatch[1]);
                const height = parseInt(resMatch[2]);

                // 提取刷新率 vsyncRate=120.000000
                const fpsMatch = line.match(/vsyncRate=([0-9.]+)/);
                if (!fpsMatch) return;
                const rawFps = parseFloat(fpsMatch[1]);
                const fps = Math.round(rawFps);

                // 存入 Map 去重 (Key: id)
                // 某些系统可能有重复行，或不同 group，这里以 ID 为准
                if (!modeMap.has(id)) {
                    modeMap.set(id, {
                        id: id,
                        width: width,
                        height: height,
                        fps: fps,
                        rawFps: rawFps
                    });
                }
            } catch (e) {
                console.warn("Parse error line:", line, e);
            }
        }
    });

    displayModes = Array.from(modeMap.values());

    // 排序
    displayModes.sort((a, b) => a.fps - b.fps || a.width - b.width);

    // 读取当前配置
    const configRaw = await ksuExec(`cat "${CONFIG_FILE}"`);
    const configLines = configRaw.split('\n');
    const globalModeId = configLines[0] ? parseInt(configLines[0].trim()) : -1;

    // 解析应用配置
    appConfigs = {};
    for (let i = 1; i < configLines.length; i++) {
        const line = configLines[i].trim();
        if (line.includes('=')) {
            const [pkg, modeId] = line.split('=');
            appConfigs[pkg] = parseInt(modeId);
        }
    }
    
    currentMode = globalModeId;

    // 自动判断当前分辨率筛选
    const currentModeObj = displayModes.find(m => m.id === currentMode);
    if (currentModeObj && currentModeObj.width > 1200) {
        switchRes('2k');
    } else {
        switchRes('1080p');
    }
}

function renderDisplayModes() {
    const listEl = document.getElementById('mode-list');
    if (!listEl) return;

    listEl.innerHTML = '';
    
    const filteredModes = displayModes.filter(mode => {
        if (currentResFilter === '1080p') return mode.width < 1200;
        if (currentResFilter === '2k') return mode.width >= 1200;
        return true;
    });

    if (filteredModes.length === 0) {
        listEl.innerHTML = '<div class="empty-hint">该分辨率下无可用模式</div>';
        return;
    }

    filteredModes.forEach(mode => {
        const item = document.createElement('div');
        item.className = `mode-item ${mode.id === currentMode ? 'active' : ''}`;
        item.onclick = () => selectMode(mode.id);
        item.innerHTML = `
            <div class="mode-info">
                <div class="mode-fps">${mode.fps}Hz</div>
                <div class="mode-res">ID: ${mode.id} | ${mode.width}x${mode.height}</div>
            </div>
            ${mode.id === currentMode ? '<div class="status-badge success">当前</div>' : ''}
        `;
        listEl.appendChild(item);
    });
}

function selectMode(id) {
    currentMode = id;
    const items = document.querySelectorAll('.mode-item');
    items.forEach(item => {
        if (item.innerHTML.includes(`ID: ${id} |`)) {
            item.classList.add('active');
        } else {
            item.classList.remove('active');
        }
    });
}

// 保存全局模式
async function saveGlobalMode() {
    if (currentMode === -1) {
        showToast("请先选择一个模式");
        return;
    }
    
    showToast("正在保存全局模式...");
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" set_config "${currentMode}"`);
    
    if (result.includes("Success")) {
        showToast("保存成功！");
        await loadDisplayModes(); // 刷新
    } else {
        showToast("保存失败：" + result);
    }
}

// 刷写 DTBO（后台执行 + 流式日志：立即弹出 → 确认 → setsid 后台跑 → 轮询日志 → 重启按钮）
async function flashDtbo() {
    const customRateInput = document.getElementById('custom-rate');
    const customRate = customRateInput ? customRateInput.value.trim() : "";

    // 立即打开流程弹窗（同步显示，不等命令，解决"等5秒才弹窗"）
    const term = openFlowModal("刷写超频 DTBO");

    // 确认步骤
    term.log("⚠️ 即将执行以下操作：", 'warn');
    term.log("  1. 智能添加刷新率（提取 → 解包 → 补丁）", 'info');
    term.log("  2. 打包 new_dtbo.img", 'info');
    term.log("  3. 合并官方 AVB 签名（免解锁）", 'info');
    term.log("  4. 写入 DTBO 分区并回读校验", 'info');
    if (customRate) {
        term.log(`⚠️ 检测到自定义刷新率: ${customRate}Hz（实验性，可能导致不稳定）`, 'warn');
    }
    term.log("刷入后需要重启生效。请确保已有救砖备份。", 'warn');

    term.setButtons([
        { id: 'start', label: '▶ 开始刷写', cls: 'btn-danger' },
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
        // 启动后台任务（setsid 立即返回，不阻塞 UI；日志流式写入 apply.log）
        const started = await ksuExec(`sh "${scriptPath}" start_flash "${customRate}"`);
        term.log(started || "(已启动)", 'info');
        if (!started.includes('Started')) {
            term.log("✖ 无法启动后台任务", 'err');
            term.setButtons([{ id: 'ok', label: '知道了', cls: 'btn-secondary' }]);
            await term.waitButton(); term.close();
            return;
        }

        term.log("⏳ 后台执行中，日志实时刷新...", 'info');
        const status = await pollProcessLog(logPath, statusPath, term);

        if (status === 'SUCCESS') {
            term.log(""); term.log("✔ 全部完成！刷写成功，重启后生效。", 'done');
            term.setButtons([
                { id: 'reboot', label: '🔄 立即重启', cls: 'btn-danger' },
                { id: 'later', label: '⏰ 稍后重启', cls: 'btn-secondary' }
            ]);
            const act = await term.waitButton();
            term.close();
            if (act === 'reboot') {
                showToast("正在重启设备...");
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

// 刷入成功弹窗：立即重启 / 稍后重启
async function showRebootModal(title, message) {
    const action = await showModal(title, message, {
        buttons: [
            { id: 'reboot', label: '🔄 立即重启', className: 'btn-danger' },
            { id: 'later', label: '⏰ 稍后重启', className: 'btn-secondary' }
        ]
    });
    if (action === 'reboot') {
        showToast("正在重启设备...");
        await ksuExec("reboot");
    }
}

// 恢复 DTBO
async function restoreDtbo() {
    // if (!confirm("确定要恢复原厂 DTBO 吗？")) return;
    const confirmed = await showModal("恢复确认", "确定要恢复原厂 DTBO 吗？\n\n请确保您有备份文件。");
    if (!confirmed) return;
    
    // Give UI a chance to close modal
    await new Promise(resolve => setTimeout(resolve, 100));

    showToast("正在恢复 DTBO，请稍候...");
    
    // Give Toast a chance to render
    await new Promise(resolve => setTimeout(resolve, 50));

    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    
    try {
        debugLog(`Restore calling: sh "${scriptPath}" restore_dtbo`);
        const result = await ksuExec(`sh "${scriptPath}" restore_dtbo`);
        debugLog(`Restore result: ${result}`);
        
        if (result.includes("Success")) {
            await showRebootModal("恢复成功", "原厂 DTBO 已恢复。\n请重启设备以生效。");
        } else {
            await showModal("失败", "恢复失败:\n" + result);
        }
    } catch (e) {
        debugLog(`Restore exception: ${e.message}`);
        await showModal("错误", "执行出错: " + e.message);
    }
    
    await loadSystemStatus();
}

// COPG 风格的应用信息获取 (KernelSU API)
async function getPackageInfoNewKernelSU(packageName) {
    try {
        // Method 1: ksu.getPackageInfo (Single)
        if (typeof ksu !== 'undefined' && typeof ksu.getPackageInfo !== 'undefined') {
            const info = ksu.getPackageInfo(packageName);
            if (info && typeof info === 'object') {
                return {
                    appLabel: info.appLabel || info.label || packageName,
                    packageName: packageName
                };
            }
        }
        
        // Method 2: ksu.getPackagesInfo (Array)
        if (typeof ksu !== 'undefined' && typeof ksu.getPackagesInfo !== 'undefined') {
            try {
                const infoJson = ksu.getPackagesInfo(JSON.stringify([packageName]));
                const infoArray = JSON.parse(infoJson);
                if (infoArray && infoArray[0]) {
                    return {
                        appLabel: infoArray[0].appLabel || infoArray[0].label || packageName,
                        packageName: packageName
                    };
                }
            } catch (parseError) {
                console.error('Failed to parse getPackagesInfo JSON:', parseError);
            }
        }
        
        // Method 3: $packageManager (WebView Object)
        if (typeof $packageManager !== 'undefined') {
            const info = $packageManager.getApplicationInfo(packageName, 0, 0);
            if (info) {
                return {
                    appLabel: info.getLabel() || packageName,
                    packageName: packageName
                };
            }
        }
        
        return null; // Fallback to shell
    } catch (error) {
        console.error(`Error getting package info for ${packageName}:`, error);
        return null;
    }
}

// 加载应用列表
async function loadAppList() {
    const listEl = document.getElementById('app-list');
    if (!listEl) return;
    
    listEl.innerHTML = '<div class="loading">正在加载应用列表...</div>';

    // 获取第三方应用包名
    const cmd = "pm list packages -3 | cut -d: -f2";
    const raw = await ksuExec(cmd);
    const packages = raw.split('\n').filter(p => p.trim());
    
    if (packages.length === 0) {
        listEl.innerHTML = '<div class="empty-hint">未找到第三方应用</div>';
        return;
    }

    // 存储所有包名，用于搜索
    allPackages = packages;
    
    // 1. 尝试使用 KSU 批量 API 获取标签 (COPG 方式)
    if (typeof ksu !== 'undefined' && typeof ksu.getPackagesInfo !== 'undefined') {
        try {
            debugLog("Using KSU Bulk API for labels...");
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
        } catch (e) {
            console.error("Bulk fetch failed", e);
            debugLog(`Bulk fetch error: ${e.message}`);
        }
    }

    // 2. 渲染完整列表 (此时如果有 API，appLabels 应该已经填充了大半)
    renderAppList(allPackages);

    // 3. 后台补充加载 (针对 API 失败或未覆盖的)
    setTimeout(() => {
        allPackages.forEach(pkg => {
            if (!appLabels[pkg]) queueAppLabelFetch(pkg);
        });
    }, 1000);
}

// 筛选应用列表
function filterAppList() {
    const input = document.getElementById('app-search');
    if (!input) return;
    
    const term = input.value.trim().toLowerCase();
    
    if (!term) {
        renderAppList(allPackages);
        return;
    }
    
    const filtered = allPackages.filter(pkg => {
        // 匹配包名
        if (pkg.toLowerCase().includes(term)) return true;
        
        // 匹配应用名
        if (appLabels[pkg] && appLabels[pkg].toLowerCase().includes(term)) return true;
        
        // 匹配已配置的刷新率 (如 "120")
        const modeId = appConfigs[pkg];
        if (modeId) {
            const mode = displayModes.find(m => m.id === modeId);
            if (mode && mode.fps.toString().includes(term)) return true;
        }
        
        return false;
    });
    
    renderAppList(filtered);
}

// 获取应用名称
async function fetchAppLabel(pkg) {
    if (appLabels[pkg]) return appLabels[pkg];

    // 1. 尝试使用 KSU API (COPG 方式)
    const ksuInfo = await getPackageInfoNewKernelSU(pkg);
    if (ksuInfo && ksuInfo.appLabel) {
        appLabels[pkg] = ksuInfo.appLabel;
        updateLabelUI(pkg, ksuInfo.appLabel);
        return ksuInfo.appLabel;
    }

    // 2. Fallback: Shell script
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const label = await ksuExec(`sh "${scriptPath}" get_app_info "${pkg}"`);
    
    if (label && label.trim()) {
        const cleanLabel = label.trim();
        appLabels[pkg] = cleanLabel;
        updateLabelUI(pkg, cleanLabel);
    } else {
        appLabels[pkg] = pkg; // 标记已获取
    }
}

function updateLabelUI(pkg, label) {
    const labelEl = document.getElementById(`label-${pkg}`);
    if (labelEl) {
         labelEl.innerText = label;
    }
}

async function processLabelQueue() {
    if (processingQueue) return;
    processingQueue = true;
    
    while (labelQueue.length > 0) {
        const batch = labelQueue.splice(0, 3); // 3并发
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

// 渲染应用列表
function renderAppList(packages) {
    const listEl = document.getElementById('app-list');
    if (!listEl) return;
    
    if (packages.length === 0) {
        listEl.innerHTML = '<div class="empty-hint">未找到匹配的应用</div>';
        return;
    }

    listEl.innerHTML = '';
    
    // 创建文档片段以提高性能
    const fragment = document.createDocumentFragment();
    
    // 优化：如果有搜索词，全部显示；如果没有，只显示前 50 个 + 滚动加载 (简化版：只显示前100个以防卡顿)
    // 但为了搜索体验，这里暂不限制，因为包名列表通常几百个还能接受
    
    packages.forEach(pkg => {
        const item = document.createElement('div');
        item.className = 'app-item';
        
        // 当前应用的配置模式
        const modeId = appConfigs[pkg] || -1;
        
        // 构建下拉选项
        let optionsHtml = '<option value="-1">默认</option>';
        displayModes.forEach(m => {
            const selected = m.id === modeId ? 'selected' : '';
            optionsHtml += `<option value="${m.id}" ${selected}>${m.fps}Hz (${m.width < 1200 ? '1080P' : '2K'})</option>`;
        });

        // 格式化包名显示：高亮最后一段
        const parts = pkg.split('.');
        let displayName = pkg;
        if (parts.length > 1) {
            const last = parts.pop();
            displayName = `<span style="color:#666">${parts.join('.')}</span>.<b>${last}</b>`;
        }

        // 触发获取应用名
        if (!appLabels[pkg]) {
            queueAppLabelFetch(pkg);
        }
        const label = appLabels[pkg] || "加载中...";

        item.innerHTML = `
            <div class="app-info">
                <div class="app-name" id="label-${pkg}" style="font-weight:bold; margin-bottom:2px;">${label}</div>
                <div class="app-pkg" style="font-size:12px;">${displayName}</div>
            </div>
            <div class="app-control">
                <select onchange="saveAppConfig('${pkg}', this.value)">
                    ${optionsHtml}
                </select>
            </div>
        `;
        fragment.appendChild(item);
    });
    
    listEl.appendChild(fragment);
}

// 保存应用配置
async function saveAppConfig(pkg, modeId) {
    showToast(`正在保存 ${pkg} 配置...`);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" set_app_config "${pkg}" "${modeId}"`);
    
    if (result.includes("Success")) {
        showToast("保存成功");
        // 更新本地缓存
        if (modeId == -1) {
            delete appConfigs[pkg];
        } else {
            appConfigs[pkg] = parseInt(modeId);
        }
    } else {
        showToast("保存失败");
    }
}

// 刷新日志
async function refreshLogs() {
    const viewer = document.getElementById('log-viewer');
    if (!viewer) return;

    viewer.value = "正在读取日志...";
    
    // 读取最后 1000 行
    const content = await ksuExec(`tail -n 1000 "${LOG_FILE}"`);
    
    if (!content || content.trim() === "") {
        viewer.value = "暂无日志或读取失败";
    } else {
        viewer.value = content;
        // 自动滚动到底部
        viewer.scrollTop = viewer.scrollHeight;
    }
}

// 清空日志
async function clearLogs() {
    // if (!confirm("确定要清空日志吗？")) return;
    const confirmed = await showModal("清空日志", "确定要清空日志吗？");
    if (!confirmed) return;
    
    await ksuExec(`echo "" > "${LOG_FILE}"`);
    showToast("日志已清空");
    refreshLogs();
}

// 打开链接
async function openUrl(url) {
    // 使用 am start 调用外部浏览器打开
    await ksuExec(`am start -a android.intent.action.VIEW -d "${url}"`);
}

// 微信打赏
async function donateWechat() {
    const cmd = `am start -n com.tencent.mm/com.tencent.mm.plugin.remittance.ui.RemittanceAdapterUI \
    --es 'receiver_name' 'wxp://f2f0Uk7YdwjnrBPrQ85ytbNuR1L4y1GRJz2wzm7cNgl2onU' \
    --ei 'scene' '1' \
    --ei 'pay_channel' '24' >/dev/null 2>&1`;
    
    await ksuExec(cmd);
}

// 暴露给全局
window.refreshLogs = refreshLogs;
window.clearLogs = clearLogs;
window.openUrl = openUrl;
window.donateWechat = donateWechat;

// --- DTS Management Functions ---

// 1. Scan Workspace (Existing DTS)
async function scanWorkspace() {
    debugLog("scanWorkspace called");
    showToast("正在扫描工作区...");
    document.getElementById('dts-manager').style.display = 'block';
    await scanRates();
}

// 2. Re-extract Workspace (Init)
async function reextractWorkspace() {
    debugLog("reextractWorkspace called");
    
    // if (!confirm("确定要重新提取 DTBO 吗？\n\n这将会覆盖当前工作区的所有修改！\n请仅在需要重置或更新底包时使用。")) return;
    const confirmed = await showModal("重新提取确认", "确定要重新提取 DTBO 吗？\n\n这将会覆盖当前工作区的所有修改！\n请仅在需要重置或更新底包时使用。");
    if (!confirmed) return;

    // Give UI a chance to close modal
    await new Promise(resolve => setTimeout(resolve, 100));

    try {
        showToast("正在提取并解包 DTBO...");
        
        // Give Toast a chance to render
        await new Promise(resolve => setTimeout(resolve, 50));
        
        const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
        
        debugLog("Calling init_workspace...");
        const result = await ksuExec(`sh "${scriptPath}" init_workspace`);
        debugLog(`init result: ${result}`);
        
        if (result.includes("Success")) {
            showToast("初始化成功！正在扫描...");
            document.getElementById('dts-manager').style.display = 'block';
            await scanRates();
        } else {
            await showModal("失败", "初始化失败:\n" + result);
        }
    } catch (e) {
        debugLog(`init error: ${e.message}`);
        console.error("initWorkspace error:", e);
        await showModal("错误", "执行出错: " + e.message);
    }
}

// 2.1 Auto Process (Auto Patch)
async function autoProcess() {
    debugLog("autoProcess called");
    
    const confirmed = await showModal("自动处理确认", "确定要执行自动超频处理吗？\n\n这将会根据您的机型自动生成高刷节点。\n建议在'重新提取'后执行一次。");
    if (!confirmed) return;

    // Give UI a chance to close modal
    await new Promise(resolve => setTimeout(resolve, 100));

    try {
        showToast("正在执行自动处理...");
        
        // Give Toast a chance to render
        await new Promise(resolve => setTimeout(resolve, 50));
        
        const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
        
        debugLog("Calling auto_process...");
        const result = await ksuExec(`sh "${scriptPath}" auto_process`);
        debugLog(`auto_process result: ${result}`);
        
        if (result.includes("Success")) {
            showToast("处理完成！正在刷新列表...");
            await showModal("成功", "自动处理已完成！\n\n已根据检测到的机型生成了对应的高刷节点。\n您可以继续手动微调，或直接点击'应用更改'。");
            document.getElementById('dts-manager').style.display = 'block';
            await scanRates();
        } else {
            await showModal("失败", "处理失败:\n" + result);
        }
    } catch (e) {
        debugLog(`auto_process error: ${e.message}`);
        console.error("autoProcess error:", e);
        await showModal("错误", "执行出错: " + e.message);
    }
}

// 3. Scan Rates (Internal Helper)
async function scanRates() {
    const tableBody = document.getElementById('rates-list');
    const select = document.getElementById('base-node-select');
    if (!tableBody || !select) return;

    tableBody.innerHTML = '<tr><td colspan="4" style="text-align:center;">正在扫描...</td></tr>';
    
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    const result = await ksuExec(`sh "${scriptPath}" scan_rates`);

    try {
        // Find JSON part in output
        const jsonStart = result.indexOf('[');
        const jsonEnd = result.lastIndexOf(']') + 1;
        
        if (jsonStart === -1 || jsonEnd === 0) {
            throw new Error("Invalid JSON output");
        }
        
        const jsonStr = result.substring(jsonStart, jsonEnd);
        const rates = JSON.parse(jsonStr);
        
        // Render Table
        tableBody.innerHTML = '';
        select.innerHTML = '';
        
        if (rates.length === 0) {
            tableBody.innerHTML = '<tr><td colspan="4" style="text-align:center;">未找到刷新率节点</td></tr>';
            return;
        }

        rates.sort((a, b) => a.fps - b.fps);

        rates.forEach(rate => {
            // Add to Table
            const row = document.createElement('tr');
            row.innerHTML = `
                <td><b>${rate.fps}</b> Hz</td>
                <td>${rate.clock}</td>
                <td>${rate.file}</td>
                <td>
                    <div class="row-actions">
                        <button class="btn btn-rate-edit" onclick="modifyRate('${rate.node}', ${rate.fps}, ${rate.clock || 0}, ${rate.transfer || 0})">✏️ 修改</button>
                        <button class="btn btn-rate-del" onclick="removeRate('${rate.node}')">🗑️ 删除</button>
                    </div>
                </td>
            `;
            tableBody.appendChild(row);

            // Add to Select
            const option = document.createElement('option');
            option.value = rate.node;
            option.text = `${rate.fps} Hz (${rate.node})`;
            option.dataset.fps = rate.fps;
            option.dataset.clock = rate.clock || 0;
            option.dataset.transfer = rate.transfer || 0;
            if (rate.fps === 120) option.selected = true;
            select.appendChild(option);
        });

        // 绑定高级选项默认值实时回填（option 已重建，需重新绑定）
        setupRateDefaults();

    } catch (e) {
        console.error("Scan failed:", e);
        tableBody.innerHTML = `<tr><td colspan="4" style="color:red;">扫描失败: ${e.message}<br><small>${result.substring(0, 100)}...</small></td></tr>`;
    }
}

// 3.0 Auto Calc Helper
// 与后端 dts_tool.c 公式保持一致（C 整数除法 = 截断）：
//   new_clock   = base_clock   * target_fps / base_fps
//   new_transfer = base_transfer * base_fps  / target_fps
function calcAuto(fps, clock, transfer, targetFps) {
    if (!fps || fps <= 0 || !targetFps || targetFps <= 0) return null;
    return {
        clock: clock > 0 ? Math.floor(clock * targetFps / fps) : 0,
        transfer: transfer > 0 ? Math.floor(transfer * fps / targetFps) : 0
    };
}

// 3.0.1 添加区块：基准节点 / 目标 FPS 变化时，实时把默认值回填到高级选项输入框
// 默认值 = 有原值则按目标 FPS 自动换算；无原值(0)则留空并提示。
// 用户手动编辑过则不再覆盖；清空后恢复自动回填。
function setupRateDefaults() {
    const baseSelect = document.getElementById('base-node-select');
    const targetInput = document.getElementById('target-fps');
    const clockInput = document.getElementById('custom-clock');
    const transferInput = document.getElementById('custom-transfer');
    if (!baseSelect || !targetInput || !clockInput || !transferInput) return;

    function refreshDefaults() {
        const opt = baseSelect.options[baseSelect.selectedIndex];
        const fps = opt ? parseFloat(opt.dataset.fps) : 0;
        const clock = opt ? parseFloat(opt.dataset.clock) : 0;
        const transfer = opt ? parseFloat(opt.dataset.transfer) : 0;
        const targetFps = parseFloat(targetInput.value);
        const auto = calcAuto(fps, clock, transfer, targetFps);

        if (!clockInput.dataset.touched) {
            if (auto && auto.clock > 0) {
                clockInput.value = auto.clock;
                clockInput.placeholder = `自动计算: ${auto.clock}`;
            } else {
                clockInput.value = '';
                clockInput.placeholder = clock > 0 ? '自动计算' : '该节点无原值，留空由后端自动计算';
            }
        }
        if (!transferInput.dataset.touched) {
            if (auto && auto.transfer > 0) {
                transferInput.value = auto.transfer;
                transferInput.placeholder = `自动计算: ${auto.transfer}`;
            } else {
                transferInput.value = '';
                transferInput.placeholder = transfer > 0 ? '自动计算' : '该节点无原值，留空由后端自动计算';
            }
        }
    }

    // 解绑旧监听（scanRates 每次重建 option 后都会重新调用本函数）
    if (baseSelect._onRateDefaultsChange) baseSelect.removeEventListener('change', baseSelect._onRateDefaultsChange);
    if (targetInput._onRateDefaultsInput) targetInput.removeEventListener('input', targetInput._onRateDefaultsInput);
    if (clockInput._onRateDefaultsManual) clockInput.removeEventListener('input', clockInput._onRateDefaultsManual);
    if (transferInput._onRateDefaultsManual) transferInput.removeEventListener('input', transferInput._onRateDefaultsManual);

    baseSelect._onRateDefaultsChange = refreshDefaults;
    targetInput._onRateDefaultsInput = refreshDefaults;
    clockInput._onRateDefaultsManual = () => { clockInput.dataset.touched = clockInput.value !== '' ? '1' : ''; };
    transferInput._onRateDefaultsManual = () => { transferInput.dataset.touched = transferInput.value !== '' ? '1' : ''; };

    baseSelect.addEventListener('change', baseSelect._onRateDefaultsChange);
    targetInput.addEventListener('input', targetInput._onRateDefaultsInput);
    clockInput.addEventListener('input', clockInput._onRateDefaultsManual);
    transferInput.addEventListener('input', transferInput._onRateDefaultsManual);

    // 初始回填一次
    refreshDefaults();
}

// 3. Add Rate
async function addRate() {
    const baseNode = document.getElementById('base-node-select').value;
    const targetFps = document.getElementById('target-fps').value.trim();

    if (!baseNode) {
        showToast("请先选择基准节点");
        return;
    }
    if (!targetFps || isNaN(targetFps) || targetFps <= 0) {
        showToast("请输入有效的目标刷新率");
        return;
    }

    // 高级选项：自定义时钟 / 传输时间（留空 = 自动计算）
    const customClock = document.getElementById('custom-clock').value.trim();
    const customTransfer = document.getElementById('custom-transfer').value.trim();
    const clockArg = (customClock && !isNaN(customClock) && customClock > 0) ? customClock : "";
    const transferArg = (customTransfer && !isNaN(customTransfer) && customTransfer > 0) ? customTransfer : "";

    let extra = "";
    if (clockArg || transferArg) {
        extra = `（自定义 clock=${clockArg || "自动"} transfer=${transferArg || "自动"}）`;
    }
    showToast(`正在添加 ${targetFps}Hz ${extra}...`);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    
    const result = await ksuExec(`sh "${scriptPath}" add_rate "${baseNode}" "${targetFps}" "${clockArg}" "${transferArg}"`);
    
    if (result.includes("Success") || result.includes("Added")) {
        showToast("添加成功！");
        document.getElementById('target-fps').value = '';
        const clockEl = document.getElementById('custom-clock');
        const transferEl = document.getElementById('custom-transfer');
        if (clockEl) { clockEl.value = ''; clockEl.dataset.touched = ''; }
        if (transferEl) { transferEl.value = ''; transferEl.dataset.touched = ''; }
        await scanRates();
    } else {
        await showModal("失败", "添加失败:\n" + result);
    }
}

// --- Modal Helper ---
let modalResolve = null;

function closeModal(result) {
    document.getElementById('custom-modal').style.display = 'none';
    document.getElementById('modal-log').style.display = 'none';
    if (modalResolve) {
        // If result is provided, use it; otherwise default to false (cancel)
        modalResolve(result !== undefined ? result : false);
        modalResolve = null;
    }
}
window.closeModal = closeModal;

// 可复用弹窗
// 用法:
//   showModal(title, msg)                          → 确定/取消，resolve true/false
//   showModal(title, msg, true, placeholder, val)  → 输入框，resolve 输入值
//   showModal(title, msg, {buttons:[{id,label,className}]}) → 自定义按钮，resolve 按钮 id
//   openLogModal(title) → 返回 {append(text), close()}，用于流程日志弹窗
function showModal(title, message, opts = false, inputPlaceholder = "", inputValue = "") {
    if (typeof opts === 'boolean') {
        opts = { isInput: opts, inputPlaceholder, inputValue };
    }
    return new Promise((resolve) => {
        // If there's an existing modal pending, cancel it first
        if (modalResolve) {
            modalResolve(false);
        }
        modalResolve = resolve;
        
        document.getElementById('modal-title').innerText = title;
        document.getElementById('modal-message').innerText = message;
        document.getElementById('modal-log').style.display = 'none';
        
        const inputContainer = document.getElementById('modal-input-container');
        const input = document.getElementById('modal-input');
        
        if (opts.isInput) {
            inputContainer.style.display = 'block';
            input.placeholder = opts.inputPlaceholder;
            input.value = opts.inputValue;
            input.focus();
        } else {
            inputContainer.style.display = 'none';
        }
        
        // 多字段表单 (fields: [{id,label,value,placeholder,type,onInput}])
        const fieldsContainer = document.getElementById('modal-fields');
        if (opts.fields && opts.fields.length) {
            fieldsContainer.style.display = 'block';
            fieldsContainer.innerHTML = '';
            opts.fields.forEach(f => {
                const group = document.createElement('div');
                group.className = 'form-group modal-field';
                const label = document.createElement('label');
                label.innerText = f.label;
                const fieldInput = document.createElement('input');
                fieldInput.type = f.type || 'number';
                fieldInput.className = 'form-input';
                fieldInput.placeholder = f.placeholder || '';
                fieldInput.value = f.value || '';
                fieldInput.dataset.fieldId = f.id;
                if (typeof f.onInput === 'function') {
                    fieldInput.addEventListener('input', () => f.onInput(fieldInput, fieldsContainer));
                }
                group.appendChild(label);
                group.appendChild(fieldInput);
                fieldsContainer.appendChild(group);
            });
        } else {
            fieldsContainer.style.display = 'none';
            fieldsContainer.innerHTML = '';
        }
        
        // 构建按钮
        const actionsEl = document.querySelector('.modal-actions');
        actionsEl.innerHTML = '';
        let buttons;
        if (opts.buttons && opts.buttons.length) {
            buttons = opts.buttons;
        } else if (opts.isInput) {
            buttons = [{ id: 'ok', label: '确定', className: 'btn-primary' }];
        } else if (opts.fields && opts.fields.length) {
            buttons = [
                { id: 'cancel', label: '取消', className: 'btn-secondary' },
                { id: 'ok', label: '确定', className: 'btn-primary' }
            ];
        } else {
            buttons = [
                { id: 'cancel', label: '取消', className: 'btn-secondary' },
                { id: 'ok', label: '确定', className: 'btn-primary' }
            ];
        }
        buttons.forEach(b => {
            const btn = document.createElement('button');
            btn.className = `btn ${b.className || 'btn-primary'}`;
            btn.innerText = b.label;
            btn.onclick = () => {
                let val;
                if (opts.isInput && b.id === 'ok') {
                    val = input.value;
                } else if (opts.fields && opts.fields.length && b.id === 'ok') {
                    // 收集所有字段值
                    val = {};
                    fieldsContainer.querySelectorAll('input[data-field-id]').forEach(fi => {
                        val[fi.dataset.fieldId] = fi.value.trim();
                    });
                } else {
                    val = b.id === 'ok' ? true : (b.id === 'cancel' ? false : b.id);
                }
                closeModal(val);
            };
            actionsEl.appendChild(btn);
        });
        
        document.getElementById('custom-modal').style.display = 'flex';
    });
}

// ===== 流程日志弹窗（亮色主题：合并确认 + 分步日志） =====
let flowButtonsResolve = null;

// 打开流程弹窗：同步立即显示（不等命令，保持亮色主题）
// 返回 {log(text, cls), setButtons([...]), waitButton(), close()}
function openFlowModal(title) {
    // 关闭可能残留的弹窗
    if (modalResolve) { modalResolve(false); modalResolve = null; }
    if (flowButtonsResolve) { flowButtonsResolve(null); flowButtonsResolve = null; }

    const modal = document.getElementById('custom-modal');
    const content = modal.querySelector('.modal-content');
    content.classList.add('modal-lg');
    document.getElementById('modal-title').innerText = title;
    document.getElementById('modal-message').innerText = '';
    document.getElementById('modal-input-container').style.display = 'none';
    document.getElementById('modal-fields').style.display = 'none';
    const logEl = document.getElementById('modal-log');
    logEl.style.display = 'block';
    logEl.innerHTML = '';
    const actionsEl = document.querySelector('.modal-actions');
    actionsEl.innerHTML = '';
    modal.style.display = 'flex';

    return {
        // cls: step / ok / err / warn / info / cmd / done（对应 CSS .log-* 着色）
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
        setButtons(buttons) { // [{id,label,cls}]
            const act = document.querySelector('.modal-actions');
            act.innerHTML = '';
            buttons.forEach(b => {
                const btn = document.createElement('button');
                btn.className = `btn ${b.cls || 'btn-secondary'}`;
                btn.innerText = b.label;
                btn.onclick = () => {
                    act.innerHTML = '';
                    if (flowButtonsResolve) {
                        const r = flowButtonsResolve;
                        flowButtonsResolve = null;
                        r(b.id);
                    }
                };
                act.appendChild(btn);
            });
        },
        waitButton() {
            return new Promise(resolve => { flowButtonsResolve = resolve; });
        },
        close() {
            if (flowButtonsResolve) { flowButtonsResolve(null); flowButtonsResolve = null; }
            content.classList.remove('modal-lg');
            modal.style.display = 'none';
            logEl.style.display = 'none';
        }
    };
}

// 让浏览器先渲染再执行命令（避免主线程忙导致弹窗延迟出现）
const nextPaint = () => new Promise(r => setTimeout(r, 30));

// 3.5 Modify Rate
async function modifyRate(nodeName, currentFps, currentClock, currentTransfer) {
    debugLog(`Clicked Modify: ${nodeName}, ${currentFps}`);
    
    currentClock = currentClock || 0;
    currentTransfer = currentTransfer || 0;
    
    // 修改弹窗：FPS + 高级选项（默认值 = 原值；改 FPS 时自动按公式换算）
    // 时钟/传输时间输入框预填原值；若手动修改过则不再被自动换算覆盖；清空后恢复自动。
    const values = await showModal(`修改 ${nodeName}`, "以下为默认值（原值或按目标 FPS 自动换算），可直接修改；留空则按基准节点自动计算。", {
        fields: [
            {
                id: 'fps',
                label: '目标刷新率 (FPS):',
                value: currentFps,
                placeholder: '例如: 150',
                onInput: (input, container) => {
                    const targetFps = parseFloat(input.value);
                    const auto = calcAuto(currentFps, currentClock, currentTransfer, targetFps);
                    if (!auto) return;
                    const clockIn = container.querySelector('input[data-field-id="clock"]');
                    const transferIn = container.querySelector('input[data-field-id="transfer"]');
                    if (clockIn && !clockIn.dataset.touched) {
                        if (auto.clock > 0) {
                            clockIn.value = auto.clock;
                            clockIn.placeholder = `自动计算: ${auto.clock}`;
                        } else {
                            clockIn.value = '';
                            clockIn.placeholder = currentClock > 0 ? '自动计算' : '该节点无原值，留空由后端自动计算';
                        }
                    }
                    if (transferIn && !transferIn.dataset.touched) {
                        if (auto.transfer > 0) {
                            transferIn.value = auto.transfer;
                            transferIn.placeholder = `自动计算: ${auto.transfer}`;
                        } else {
                            transferIn.value = '';
                            transferIn.placeholder = currentTransfer > 0 ? '自动计算' : '该节点无原值，留空由后端自动计算';
                        }
                    }
                }
            },
            {
                id: 'clock',
                label: '时钟频率 (clockrate, Hz):',
                value: currentClock > 0 ? currentClock : '',
                placeholder: currentClock > 0 ? `原值: ${currentClock}` : '该节点无原值，留空由后端自动计算',
                onInput: (input) => { input.dataset.touched = input.value !== '' ? '1' : ''; }
            },
            {
                id: 'transfer',
                label: '传输时间 (transfer-time-us, µs):',
                value: currentTransfer > 0 ? currentTransfer : '',
                placeholder: currentTransfer > 0 ? `原值: ${currentTransfer}` : '该节点无原值，留空由后端自动计算',
                onInput: (input) => { input.dataset.touched = input.value !== '' ? '1' : ''; }
            }
        ]
    });
    
    if (!values) return;
    
    const newFps = values.fps;
    if (!newFps || isNaN(newFps) || newFps == currentFps) return;
    
    const clockArg = (values.clock && !isNaN(values.clock) && values.clock > 0) ? values.clock : "";
    const transferArg = (values.transfer && !isNaN(values.transfer) && values.transfer > 0) ? values.transfer : "";
    
    // 1. Add new node based on old node
    showToast(`正在添加 ${newFps}Hz...`);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    
    // Use the nodeName as the base for the new node
    const resultAdd = await ksuExec(`sh "${scriptPath}" add_rate "${nodeName}" "${newFps}" "${clockArg}" "${transferArg}"`);
    
    if (resultAdd.includes("Success") || resultAdd.includes("Added")) {
        // 2. Remove old node
        showToast(`添加成功，正在删除旧节点 ${nodeName}...`);
        const resultRem = await ksuExec(`sh "${scriptPath}" remove_rate "${nodeName}"`);
        
        if (resultRem.includes("Success") || resultRem.includes("Removed")) {
            showToast("修改成功！");
            await scanRates();
        } else {
            await showModal("部分完成", "修改部分完成 (新节点已添加，但旧节点删除失败):\n" + resultRem);
            await scanRates();
        }
    } else {
        await showModal("失败", "修改失败 (添加新节点失败):\n" + resultAdd);
    }
}

// 4. Remove Rate
async function removeRate(nodeName) {
    debugLog(`Clicked Remove: ${nodeName}`);
    
    // Use custom modal instead of confirm
    const confirmed = await showModal("删除确认", `确定要删除节点 ${nodeName} 吗？`);
    if (!confirmed) {
        debugLog("Remove cancelled by user");
        return;
    }

    showToast(`正在删除 ${nodeName}...`);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    
    const result = await ksuExec(`sh "${scriptPath}" remove_rate "${nodeName}"`);
    debugLog(`Remove result: ${result}`);
    
    if (result.includes("Success") || result.includes("Removed")) {
        showToast("删除成功！");
        await scanRates();
    } else {
        await showModal("失败", "删除失败:\n" + result);
    }
}

// 5. Apply Changes
// 判断刷入类命令是否成功：
//   后端阶段命令（pack_only / merge_avb / flash_final / smart_add_rate）
//   成功时统一输出 "Success: ..." 前缀，错误时输出 "错误：/Error:"。
//   因此只要输出包含 Success 标记即为成功，不再用失败关键词正则误伤
//   （例如 smart_add_rate 中 process_dts 的"提示：…发生错误"只是警告，不应判失败）。
function isFlashSuccess(result) {
    if (!result) return false;
    if (result.includes("Success")) return true;
    if (result.includes("刷入成功") || result.includes("操作完成")) return true;
    return false;
}

// 提取明确的错误信息用于提示
function extractFlashError(result) {
    if (!result) return "无输出";
    const m = result.match(/错误：[^\n]*|警告:[^\n]*|失败[：:][^\n]*/);
    return m ? m[0] : result;
}

// 后台任务日志流式轮询：
//   后端已用 setsid 把流程放到后台执行，输出实时写入 logPath，
//   完成时写入 statusPath（SUCCESS / FAIL）。
//   这里每 interval 毫秒读取一次增量并追加到流程弹窗，实现真正的流式显示，
//   同时主线程不阻塞（不再 await 长命令），解决刷入卡顿。
// 返回 Promise<'SUCCESS' | 'FAIL'>，并给每行日志着色。
function pollProcessLog(logPath, statusPath, term, interval = 500) {
    return new Promise((resolve) => {
        let lastLen = 0;
        let pending = '';
        const timer = setInterval(async () => {
            try {
                // 增量读取日志（从上次读到的字节偏移继续）
                const chunk = await ksuExec(`tail -c +${lastLen + 1} "${logPath}" 2>/dev/null`, true);
                if (chunk) {
                    lastLen += chunk.length;
                    const all = pending + chunk;
                    const lines = all.split('\n');
                    pending = lines.pop() || ''; // 可能是不完整行，留到下次拼接
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
                // 检查状态文件
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

// 应用更改并刷入（后台执行 + 流式日志：立即弹出 → 确认 → setsid 后台跑 → 轮询日志 → 重启按钮）
async function applyChanges() {
    // 立即打开流程弹窗（同步显示，不等命令，解决"等5秒才弹窗"）
    const term = openFlowModal("应用更改 & 刷入 DTBO");

    // 确认步骤
    term.log("⚠️ 即将执行以下操作：", 'warn');
    term.log("  1. 打包 new_dtbo.img（合并你的所有修改）", 'info');
    term.log("  2. 合并官方 AVB 签名（免解锁方案）", 'info');
    term.log("  3. 写入 DTBO 分区并回读校验", 'info');
    term.log("刷入后需要重启生效。请确保已有救砖备份。", 'warn');

    term.setButtons([
        { id: 'start', label: '▶ 开始执行', cls: 'btn-danger' },
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
        // 启动后台任务（setsid 立即返回，不阻塞 UI；日志流式写入 apply.log）
        const started = await ksuExec(`sh "${scriptPath}" start_apply`);
        term.log(started || "(已启动)", 'info');
        if (!started.includes('Started')) {
            term.log("✖ 无法启动后台任务", 'err');
            term.setButtons([{ id: 'ok', label: '知道了', cls: 'btn-secondary' }]);
            await term.waitButton(); term.close();
            return;
        }

        term.log("⏳ 后台执行中，日志实时刷新...", 'info');
        const status = await pollProcessLog(logPath, statusPath, term);

        if (status === 'SUCCESS') {
            term.log(""); term.log("✔ 全部完成！刷入成功，重启后生效。", 'done');
            term.setButtons([
                { id: 'reboot', label: '🔄 立即重启', cls: 'btn-danger' },
                { id: 'later', label: '⏰ 稍后重启', cls: 'btn-secondary' }
            ]);
            const act = await term.waitButton();
            term.close();
            if (act === 'reboot') {
                showToast("正在重启设备...");
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

// 6. Uninstall Module
async function uninstallModule() {
    // Use custom modal for confirmation
    const confirmed = await showModal("卸载确认", "确定要卸载此模块吗？\n\n这将会：\n1. 恢复原厂 DTBO (如果存在备份)\n2. 删除模块文件\n3. 重启设备 (建议手动重启)");
    if (!confirmed) return;

    showToast("正在卸载模块...");
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    
    // Call uninstall_module in web_handler
    const result = await ksuExec(`sh "${scriptPath}" uninstall_module`);
    
    if (result.includes("Success")) {
        await showModal("成功", "卸载成功！\n模块已移除，请重启设备。");
    } else {
        await showModal("失败", "卸载失败:\n" + result);
    }
}

// 7. Toggle ADFR
async function toggleAdfr(enable) {
    const action = enable ? "enable" : "disable";
    const msg = enable 
        ? "确定要还原 ADFR 设置吗？\n这将会恢复之前的系统属性。" 
        : "确定要禁用 ADFR 吗？\n这将会强制关闭可变刷新率，可能导致耗电增加。";
        
    // if (!confirm(msg)) return;
    const confirmed = await showModal(enable ? "还原确认" : "禁用确认", msg);
    if (!confirmed) return;

    showToast(enable ? "正在还原 ADFR..." : "正在禁用 ADFR...");
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    
    const result = await ksuExec(`sh "${scriptPath}" toggle_adfr "${action}"`);
    
    if (result.includes("Success")) {
        showToast(enable ? "已还原默认设置" : "ADFR 已禁用");
        // alert(result);
    } else {
        await showModal("失败", "操作失败:\n" + result);
    }
}

// Expose DTS functions
window.scanWorkspace = scanWorkspace;
window.reextractWorkspace = reextractWorkspace;
window.scanRates = scanRates;
window.addRate = addRate;
window.modifyRate = modifyRate;
window.removeRate = removeRate;
window.applyChanges = applyChanges;
window.uninstallModule = uninstallModule;
window.toggleAdfr = toggleAdfr;
window.restoreDtbo = restoreDtbo;
window.flashDtbo = flashDtbo;

// 启动
window.addEventListener('load', init);
