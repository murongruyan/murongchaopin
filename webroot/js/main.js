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

// 兼容 KSU 的 exec 封装
async function ksuExec(cmd) {
    debugLog(`[Exec] ${cmd}`);
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
                        debugLog(`[Res] length=${res.length}`);
                        resolve(res);
                    } else {
                        debugLog(`[Res] stdout length=${res.stdout ? res.stdout.length : 0}`);
                        resolve(res.stdout || "");
                    }
                }).catch(err => {
                    debugLog(`[Err] ${err}`);
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

// 刷写 DTBO
async function flashDtbo() {
    const customRateInput = document.getElementById('custom-rate');
    const customRate = customRateInput ? customRateInput.value.trim() : "";
    
    let msg = "确定要刷入超频 DTBO 吗？\n这可能导致设备无法启动。请确保已有备份。";
    if (customRate) {
        msg = `⚠️ 警告：您设置了自定义刷新率 ${customRate}Hz。\n\n这是一个实验性功能，可能导致黑屏或系统不稳定。\n请务必确认您有救砖能力。\n\n确定要继续吗？`;
    }

    // if (!confirm(msg)) return;
    const confirmed = await showModal("刷写确认", msg);
    if (!confirmed) return;
    
    // Give UI a chance to close modal
    await new Promise(resolve => setTimeout(resolve, 100));

    showToast("正在刷写 DTBO，请稍候...");
    
    // Give Toast a chance to render
    await new Promise(resolve => setTimeout(resolve, 50));

    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    
    // Pass custom rate as 2nd argument (empty string if not set)
    try {
        const result = await ksuExec(`sh "${scriptPath}" flash_dtbo "${customRate}"`);
        if (result.includes("Success") || result.includes("操作完成")) {
             await showModal("成功", "刷写成功！\n" + result);
        } else {
             await showModal("失败", "刷写失败:\n" + result);
        }
    } catch (e) {
        await showModal("错误", "执行出错: " + e.message);
    }

    await loadSystemStatus();
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
            await showModal("成功", "恢复成功！请重启设备。");
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
                    <button class="btn btn-sm btn-primary" style="margin-right:5px;" onclick="modifyRate('${rate.node}', ${rate.fps})">修改</button>
                    <button class="btn btn-sm btn-danger" onclick="removeRate('${rate.node}')">删除</button>
                </td>
            `;
            tableBody.appendChild(row);

            // Add to Select
            const option = document.createElement('option');
            option.value = rate.node;
            option.text = `${rate.fps} Hz (${rate.node})`;
            if (rate.fps === 120) option.selected = true;
            select.appendChild(option);
        });

    } catch (e) {
        console.error("Scan failed:", e);
        tableBody.innerHTML = `<tr><td colspan="4" style="color:red;">扫描失败: ${e.message}<br><small>${result.substring(0, 100)}...</small></td></tr>`;
    }
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

    showToast(`正在添加 ${targetFps}Hz...`);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    
    const result = await ksuExec(`sh "${scriptPath}" add_rate "${baseNode}" "${targetFps}"`);
    
    if (result.includes("Success") || result.includes("Added")) {
        showToast("添加成功！");
        document.getElementById('target-fps').value = '';
        await scanRates();
    } else {
        await showModal("失败", "添加失败:\n" + result);
    }
}

// --- Modal Helper ---
let modalResolve = null;

function closeModal(result) {
    document.getElementById('custom-modal').style.display = 'none';
    if (modalResolve) {
        // If result is provided, use it; otherwise default to false (cancel)
        modalResolve(result !== undefined ? result : false);
        modalResolve = null;
    }
}
window.closeModal = closeModal;

function showModal(title, message, isInput = false, inputPlaceholder = "", inputValue = "") {
    return new Promise((resolve) => {
        // If there's an existing modal pending, cancel it first
        if (modalResolve) {
            modalResolve(false);
        }
        modalResolve = resolve;
        
        document.getElementById('modal-title').innerText = title;
        document.getElementById('modal-message').innerText = message;
        
        const inputContainer = document.getElementById('modal-input-container');
        const input = document.getElementById('modal-input');
        
        if (isInput) {
            inputContainer.style.display = 'block';
            input.placeholder = inputPlaceholder;
            input.value = inputValue;
            input.focus();
        } else {
            inputContainer.style.display = 'none';
        }
        
        document.getElementById('custom-modal').style.display = 'flex';
        
        // Unbind previous listener by cloning
        const btn = document.getElementById('modal-confirm-btn');
        const newBtn = btn.cloneNode(true);
        btn.parentNode.replaceChild(newBtn, btn);
        
        newBtn.onclick = () => {
            const val = isInput ? document.getElementById('modal-input').value : true;
            closeModal(val);
        };
    });
}

// 3.5 Modify Rate
async function modifyRate(nodeName, currentFps) {
    debugLog(`Clicked Modify: ${nodeName}, ${currentFps}`);
    
    // Use custom modal instead of prompt
    const newFps = await showModal(`修改 ${nodeName}`, "请输入新的刷新率:", true, "例如: 150", currentFps);
    
    if (!newFps || isNaN(newFps) || newFps == currentFps) return;
    
    // 1. Add new node based on old node
    showToast(`正在添加 ${newFps}Hz...`);
    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    
    // Use the nodeName as the base for the new node
    const resultAdd = await ksuExec(`sh "${scriptPath}" add_rate "${nodeName}" "${newFps}"`);
    
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
async function applyChanges() {
    // if (!confirm("确定要应用更改并刷入设备吗？\n\n这将会重新打包 DTBO 并刷入分区。\n请确保所有修改都已确认无误。")) return;
    const confirmed = await showModal("应用确认", "确定要应用更改并刷入设备吗？\n\n这将会重新打包 DTBO 并刷入分区。\n请确保所有修改都已确认无误。");
    if (!confirmed) return;

    // Give UI a chance to close modal
    await new Promise(resolve => setTimeout(resolve, 100));

    showToast("正在应用更改并刷入...");
    
    // Give Toast a chance to render
    await new Promise(resolve => setTimeout(resolve, 50));

    const scriptPath = `${MOD_DIR}/scripts/web_handler.sh`;
    
    const result = await ksuExec(`sh "${scriptPath}" apply_changes`);
    
    if (result.includes("Success")) {
        await showModal("成功", "成功！DTBO 已刷入。\n请重启设备以生效。");
    } else {
        await showModal("失败", "操作失败:\n" + result);
    }
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
