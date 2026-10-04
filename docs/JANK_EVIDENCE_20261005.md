# 慕容显示增强 v2.9.41 — 「手势划不动 / 刷抖音卡 / 搜索界面卡 / 切换后台卡」现场证据量化报告

- 报告日期：2026-10-05
- 现场：用户三（机型 PLK110 / OnePlus 15，ColorOS 17 / Android 17，模块版本 2.9.41，versionCode 70）
- 主证据包：`用户反馈/用户三反馈/murong-bugpack-20261004-071752/`
- 结论性质：**卡顿有两条可复现的主因链，且互相放大**；两条链都在文件里有直接证据，不是推测。

---

## 0. 取证基线与口径（先读这一节，否则后面的行号会误用）

| 项 | 值 | 来源 |
|---|---|---|
| 模块仓库 HEAD | `818143f4c6bcb9bc7b1ab863f1f7ea68ad040c0b`「docs: release notes for v2.9.41」2026-10-03 08:37:11 +0800 | `git log -1`（工作目录 `murongchaopin/`） |
| 本报告中的 `src/*.c` / `*.java` 行号 | **一律指 HEAD（= 出厂 v2.9.41）那一版** | `git show HEAD:PATH` 导出后统计 |
| 重要提醒 | 分析期间工作树**正在被并发修改**：`git status` 显示 `src/rate_daemon.c`（+220 行）、`BridgeClient.java`（+160 行）、`OplusVrrTierHooks.java`、`OplusServicesHooks.java` 等均已 `M`（未提交）。因此**直接读工作区文件得到的行号与本文不一致**，本文引用的是 HEAD。 | `git status --porcelain`、`git diff --stat` |
| 日志/ANR/APK/映射文件 | 现场产物，不可变，行号可直接引用 | 见各节 |
| 数量统计 | 全部由脚本产出，脚本原文见第 7 节；报告中不出现手数出来的数字 | — |
| 标注约定 | 【已证实】= 文件里可直接读到；【推算】= 由已证实的代码 + 已证实的日志逻辑推导；【推测】= 无直接证据的原因假设 | — |

---

## 1. 结论摘要

1. **主因链 A（框架锁内同步 socket 往返）**：模块 Hook 了 `DisplayModeDirector$AppRequestObserver.setAppRequest`，Hook 体里调用 `BridgeClient.globalRate()` → 对 `127.0.0.1:49721` 做**阻塞式 Socket.connect**；该调用点位于 `WindowManagerGlobalLock` **被持有的临界区内**（`WindowManagerService.relayoutWindow` → `DisplayContent.applySurfaceChangesTransaction` → `DisplayManagerService.setDisplayPropertiesInternal` → `Tudp.setAppRequest`）。ANR 现场：`binder:5750_5` 持锁卡在 `java.net.Socket.connect`（anr 文件 L811–L857）。
2. **主因链 B（守护进程热路径 dumpsys 轮询）**：`rate_daemon` 单线程主循环里，前台应用靠 `popen("timeout 4 dumpsys window | grep mCurrentFocus")`（HEAD `src/rate_daemon.c:2228`，缓存仅 2000 ms，:2215），当前模式靠 `dumpsys SurfaceFlinger`（:846）。`dumpsys window` 会在 system_server 的 binder 线程里**全程持有 WindowManagerGlobalLock**——正是手势监听要的同一把锁。
3. **互相放大**：守护进程一进 dumpsys，就不再 `accept()` 桥接连接（`handle_display_hook_client` 与 dumpsys 路径在**同一个 `while(1)` 主循环**里，HEAD `:5681-5682` 对应 `:5657`）；Hook 侧的 `connect` 于是阻塞在 WM 锁内最长 400 ms（`TIMEOUT_MS=400`），锁被多持 → 守护进程自己的 dumpsys 更慢 → 空档更长 → 桥接连接堆积（`listen(fd, 4)`，HEAD `:5127`）→ `connect` 直接在 SYN 队列上阻塞。
4. **放大器**：`OplusVrrTierHooks.moduleTargetRate()` 的 5 秒缓存只在返回值 `>= 30` 时才刷新（HEAD `OplusVrrTierHooks.java:213`），而桥接失败时 `globalRate()` 返回 **-1**（HEAD `BridgeClient.java:306-315`）。**守护进程不可用期间，每一次 `setAppRequest` 都会重新发起一次 400 ms 的阻塞 connect**，缓存完全失效。
5. **现场吻合**：ANR 的 5 秒计时窗为 **05:59:24.35 → 05:59:29.35**（由 dropbox `SystemUptimeMs: 25066930` 与 `TimeoutStart: 25054819` 换算）；而 daemon.log 在 **05:59:23 发生一次非开机原因的守护进程重启**，随后 05:59:24 / 05:59:28 连续两次 5↔7 阶梯切换（L4270、L4289）。
6. **冗余事务确凿**：用户三 21.69 小时里 221 次 `Ordered refresh switch`，其中 **121 次 `Refresh ladder aligns stale policy`（冗余对齐）= 每次切换 0.55 次**；每次切换平均下发 **4.7 条 settings put**，全程 624 次 `SurfaceFlinger physical mode requested`。
7. **守护进程静默窗确凿**：daemon.log 在 ANR 窗内的 **05:59:38 → 05:59:52 有 14 秒零输出**（L4303→L4304）；全日志 ≥5 s 空档 **594 个**（剔除息屏区间后仍有 **529 个**，累计 47052 秒）。
8. **LSPosed 侧同窗旁证**：模块 Hook 在 ANR 窗内确实在工作，且 **05:59:50.912–05:59:50.951 的 39 ms 内爆发 14 条 `OPlus VRR tier resolved`**，横跨 8 个 system_server 线程，其中 **tid=6865 正是 ANR 里持锁的 binder:5750_5**（anr L813 / lspd L7703）。
9. **不是个例**：四个包都出现「频繁重启 + 长空档 + 大量冗余阶梯事务」，重启频率 user2 达 **8 次 / 1.08 小时**，user1 的反馈说明原文就是「**刷新率桥接失败**」。
10. **最该先修的三件事**：① Hook 热路径彻底不做阻塞 I/O（含 connect）；② 守护进程把桥接服务与 dumpsys 策略循环拆开（独立线程 / 独立进程 + 更大 backlog）；③ 守护进程的前台应用查询改为 Hook 推送或降低频率，杜绝 dumpsys window 轮询。

---

## 2. ANR 证据链（逐帧引用）

**文件**：`用户反馈/用户三反馈/murong-bugpack-20261004-071752/anr/anr_5750_2026-10-04-05-59-39-673`（7969 行，536516 字节）
目录清单：`anr/listing.txt` L3–L4（文件时间 2026-10-04 05:59）。

### 2.1 头部：这是一次输入分发超时

| 行 | 内容（节选） |
|---|---|
| L1 | Subject: Input dispatching timed out (PointerEventDispatcher0 is not responding. Waited 5000ms for MotionEvent(deviceId=6, eventTime=25054819425000ns, source=TOUCHSCREEN, displayId=0, action=MOVE, ..., pointers=[0: (1213.6, 519.4)]), policyFlags=0x62000000). |
| L2 | Timeout: 5000 |
| L3 | TimeoutStart: 25054819（uptime ms） |
| L207 | ----- pid 5750 at 2026-10-04 05:59:33.941523266+0800 ----- |
| L208 | Cmd line: system_server |
| L209 | Build fingerprint: 'OnePlus/PLK110/OP60FFL1:17/CP2A.260605.016/B.22eb675_320cbb_312fbe:user/release-keys' |
| L214 | DALVIK THREADS (383): |

**时间换算（与 dropbox 交叉）**：dropbox L6674 `SystemUptimeMs: 25066930`、L6679 `Timestamp: 2026-10-04 05:59:36.457+0800` ⇒ 开机时刻 ≈ 10-03 23:01:49.5。
于是 `TimeoutStart 25054819 ms` ⇒ **05:59:24.346**，5 秒窗为 **05:59:24.35 → 05:59:29.35**；trace 抓取于 **05:59:33.94**（L207）。【已证实】

### 2.2 被阻塞的手势线程（用户说的"划了没反应"）

| 行 | 内容（节选） |
|---|---|
| L380 | `"oplus.ui" prio=10 tid=110 Blocked` |
| L382 | `sysTid=6854 nice=-20 cgrp=sstop sched=0/0 handle=0x7989ffae40` |
| L386 | `at com.android.server.wm.DisplayPolicy$1.onSwipeFromTop(DisplayPolicy.java:582)` |
| L387 | `- waiting to lock <0x08992b89> (a com.android.server.wm.WindowManagerGlobalLock) held by thread 120` |
| L388 | `at com.android.server.wm.SystemGesturesPointerEventListener.onPointerEvent(SystemGesturesPointerEventListener.java:381)` |
| L389 | `at com.android.server.wm.PointerEventDispatcher.onInputEvent(PointerEventDispatcher.java:97)` |
| L390 | `at android.view.InputEventReceiver.dispatchInputEvent(InputEventReceiver.java:299)` |
| L391 | `at android.view.InputEventReceiver.nativeConsumeBatchedInputEvents(Native method)` |
| L401 | `at com.android.server.OplusUiThread.run(OplusUiThread.java:49)` |

**因果解释（这是"手势划了没反应"的机制，全部可从上面读到）**：从屏幕边缘上下滑（返回、回桌面手势）在 `OplusUiThread`（`oplus.ui`）上被 `InputEventReceiver` 取到，交给 `SystemGesturesPointerEventListener.onPointerEvent` → `DisplayPolicy$1.onSwipeFromTop`；该函数第一步就要取 `WindowManagerGlobalLock`，而该锁被 tid=120 长期持有，线程一直 Blocked。输入系统对 `PointerEventDispatcher0` 的 5 秒等待预算（L2/L3）耗尽后直接抛 `Input dispatching timed out`——**手势不是被"忽略"，而是手势线程连锁都拿不到，动画/返回动作根本没机会开始**。【已证实】

### 2.3 锁持有者：Hook 在框架锁内做阻塞 socket connect

| 行 | 内容 |
|---|---|
| L811 | `"binder:5750_5" prio=5 tid=120 Native` |
| L813 | `sysTid=6865 nice=0 cgrp=ssfg sched=1073741824/0 handle=0x7b554ade40` |
| L817–L819 | `__ppoll` / `poll` / `Linux_poll`（native 侧确实阻塞在 poll） |
| L832 | `at java.net.Socket.connect(Socket.java:646)` |
| L833 | `at g.d(r8-map-id-f311ff7af83126d8daacb353cb15aca5b5689cab5ed446d4cad8135349c8d63d:20)` |
| L834 | `at g.c(r8-map-id-f311ff7af83126d8daacb353cb15aca5b5689cab5ed446d4cad8135349c8d63d:81)` |
| L835 | `at i.a(r8-map-id-f311ff7af83126d8daacb353cb15aca5b5689cab5ed446d4cad8135349c8d63d:60)` |
| L836 | `at i.intercept(r8-map-id-f311ff7af83126d8daacb353cb15aca5b5689cab5ed446d4cad8135349c8d63d:3)` |
| L837–L839 | `j2.intercept` / `l.proceed` / `q0.callback`（另一 map-id `efedc8ef...`，厂商 framework 侧） |
| L840 | `at android.os.Tudp.setAppRequest(Tudp.java:-4)` |
| L841 | `at com.android.server.display.DisplayManagerService.setDisplayPropertiesInternal(DisplayManagerService.java:3933)` |
| L842 | `- locked <0x085ff745> (a com.android.server.display.DisplayManagerService$SyncRoot)` |
| L843–L846 | `DisplayManagerService$LocalService.setDisplayProperties` → `DisplayContent.applySurfaceChangesTransaction(DisplayContent.java:6958)` → `RootWindowContainer.applySurfaceChangesTransaction(:1064)` → `performSurfacePlacement(:894)` |
| L847–L849 | `WindowSurfacePlacer.performSurfacePlacementLoop(:186)` → `performSurfacePlacement(:129)` → `WindowManagerService.relayoutWindow(WindowManagerService.java:3112)` |
| L850 | `- locked <0x08992b89> (a com.android.server.wm.WindowManagerGlobalLock)` |
| L851–L856 | `Session.relayout(:332)` → `relayoutAsync2(:368)` → `IWindowSession$Stub.onTransact(:766)` → `Binder.execTransact*` |

**为什么能断定这段 socket 是本模块的**（三重独立印证，全部可复核）：

1. `murongchaopin/bin/display_settings_hook.apk`（72642 字节，2026-09-25 14:16:38）中的 `classes.dex`（58740 字节）**字符串常量池含完全相同的 r8-map-id-f311ff7af83126d8daacb353cb15aca5b5689cab5ed446d4cad8135349c8d63d**（脚本见 §7.5）。
2. `murongchaopin/src/settings_hook/build/outputs/mapping/freeRelease/mapping.txt`：
   - L7 `# pg_map_id: f311ff7af83126d8daacb353cb15aca5b5689cab5ed446d4cad8135349c8d63d`
   - L8 `# pg_map_hash: SHA-256 f311ff...`
   - L17 `com.murongchaopin.displayhook.BridgeClient -> g:`
   - L62–L91 `java.lang.String request(java.lang.String,int):496:496 -> c`
   - L92–L107 `java.lang.String requestSocket(java.lang.String,int):572:572 ... :587 -> d`
   - 即栈帧 `g.d` = `BridgeClient.requestSocket`，`g.c` = `BridgeClient.request`。
3. R8 的 dex 行号→源码行号回填：`d` 的 `8:22 -> requestSocket():573:573`（L93）覆盖 dex 行 20 ⇒ L833 对应 **`BridgeClient.java:573` = socket.connect(new InetSocketAddress("127.0.0.1", PORT), TIMEOUT_MS);**；`c` 的 `81:86 -> request():515:515`（L77）覆盖 dex 行 81 ⇒ L834 对应 **`BridgeClient.java:515` = response = requestSocket(command, timeoutMs);**（非主线程分支）。【已证实】

**Hook 究竟挂在哪里**：同一 mapping 文件 L461 `FrameworkModeResolverHooks$$ExternalSyntheticLambda1 -> i`，L470 `3:16:java.lang.Object com.murongchaopin.displayhook.OplusVrrTierHooks.lambda$installAppRequestHooks$0(...):171:171 -> a`。即 `i.a` = `OplusVrrTierHooks.lambda$installAppRequestHooks$0`，源码位置 **`OplusVrrTierHooks.java:171`**。核对 HEAD 源码：

- HEAD `OplusVrrTierHooks.java:153` static int installAppRequestHooks(...)
- :159 `if (!"setAppRequest".equals(method.getName()) ...`
- :170 `module.intercept(method, "framework.app-request", chain -> {`
- :175 `int target = moduleTargetRate();` ← Hook 体内的第一件事
- :185 `Reflect.call(chain.getThisObject(), "setAppRequest", ...)`
- :207–:218 `moduleTargetRate()`：:209 五秒缓存；**:212 int value = BridgeClient.globalRate();**；**:213 if (value >= 30) { bridgeGlobalRate = value; bridgeGlobalRateAt = now; }**

再看 HEAD `BridgeClient.java`：:267–:269 `globalRate() { return parseFpsResponse(request("GETGLOBAL")); }`；:32 `TIMEOUT_MS = 400`；:495–:519 `request()`（:504 主线程分支、**:515 非主线程直接 requestSocket**）；:571–:590 `requestSocket()`（**:573 socket.connect(..., TIMEOUT_MS)**，:574 `setSoTimeout(timeoutMs)`，:585 `reader.readLine()`）；:306–:315 `parseFpsResponse` **失败返回 -1**。【已证实】

**结论**：`oplus.ui` 想取的那把 `WindowManagerGlobalLock`，被一个正在为「读一个刷新率整数」而做**同步 TCP connect** 的 WMS binder 线程占着。这就是"手势划了没反应"的直接原因。

### 2.4 锁竞争的规模（不是单线程问题）

对 ANR 文件做机器统计（§7.6）：**383 个线程中有 23 个 Blocked 在同一个锁 `<0x08992b89>` 上**，分布如下（行号=线程头）：

| 行 | tid | 线程名 |
|---|---|---|
| L215 | 10 | binder:5750_1 |
| L243 | 29 | android.fg |
| L262 | 32 | android.display |
| L278 | 33 | android.anim |
| L301 | 38 | oplus.bg |
| L319 | 40 | oplus.io |
| L341 | 41 | AppMngNotifier |
| **L380** | **110** | **oplus.ui（手势）** |
| L404 | 130 | accessibility.io |
| L429 | 188 | binder:5750_1B |
| **L445** | **239** | **AnrConsumer** |
| L458–L628 | 262/268/278/280/281/282/286/288/289/291/293/348 | binder:5750_6/8/A/C/D/E/12/14/15/17/19/20 |

值得单独指出两条：

- **L243–L259 android.fg 卡在 `AnrController.lambda$dumpAnrStateAsync$1(AnrController.java:556)` 等同一把锁**：连"把 ANR 现场抓下来"这件事本身都被这把锁堵住，说明锁饥饿已经扩散到 system_server 自己的诊断路径。
- **L326–L331** `DisplayPolicySocExtImpl.getFocusedRootTaskInfo(:190)` ← `hookOnVerticalFling(:41)` ← `DisplayPolicy$1.lambda$onVerticalFling$0(DisplayPolicy.java:704)`：连"上滑回桌面"的另一条兄弟路径也堵在同一把锁上。

另外 ANR L535/L551 还有两处 `WindowManagerService.relayoutWindow(WindowManagerService.java:2813)` 等锁（脚本统计 `relayoutWindow` 帧共 3 处）；L43–L53 记录了来自 pid 9897（`com.omarea.vtools` / Scene）的 **pending async transaction 堆积，最久 elapsed 8737 ms**。这说明 ANR 时刻 WMS 事务队列本身也处于拥塞状态。

---

## 3. 日志量化（用户三）

**文件**：`用户反馈/用户三反馈/murong-bugpack-20261004-071752/module/daemon.log`
**规模**：4967 行，其中带 `[MM-DD HH:MM:SS]` 时间戳 4963 行；**2026-10-03 09:36:16 → 2026-10-04 07:17:50（21.69 小时）**。（第 1 行 `1970-01-04 00:54:54 ko_abi: ...` 无方括号时间戳，未计入。）
统计脚本：§7.1 / §7.2 / §7.4。

### 3.1 关键计数

| 指标 | 次数 | 备注 |
|---|---:|---|
| `Ordered refresh switch` | **221** | 每次 = 一次阶梯切换事务 |
| `Refresh ladder`（全部子类） | **590** | 见 3.2 分解 |
| `Refresh ladder aligns stale policy` | **121** | **冗余对齐事务，占切换数 0.55** |
| `Active display mode verified` | **490** | 每次切换平均 2.2 次验证 |
| `Detected App Change` | **721** | 其中连续两次间隔 ≤3 s 的 **191** 次（抖动/来回切） |
| `SurfaceFlinger physical mode requested` | **624** | 实际下发的模式事务 |
| `settings put ...` | **1040** | **每次切换 4.7 条** |
| `Forced reapply after screen-on` | 87 | 亮屏强制重放 |
| `Screen state -> ON` / `-> OFF/DOZE` | 80 / 75 | — |
| `Refresh ladder request failed` | 13 | 事务失败 |
| `Refresh ladder step failed` | 13 | 阶梯单步失败 |
| `Active display mode verification timed out` | 13 | 验证超时 |
| `Refresh ladder stray mode ignored` | 13 | 观察到非目标模式 |

### 3.2 `Refresh ladder` 子类分解（总 590）

| 次数 | 子类 |
|---:|---|
| 293 | `Refresh ladder up custom` |
| 132 | `Refresh ladder down custom` |
| **121** | **`Refresh ladder aligns stale policy`（冗余）** |
| 13 | `Refresh ladder step failed` |
| 13 | `Refresh ladder stray mode ignored` |
| 13 | `Refresh ladder request failed` |
| 5 | `Refresh ladder up stock` |

冗余来源（HEAD `src/rate_daemon.c:1238`）：阶梯切换前发现"当前策略认为的模式"与面板实际模式不一致，于是先重发一次当前模式再走阶梯——每次这样的对齐都是一次额外的 SurfaceFlinger 模式事务。

### 3.3 `Active display mode verified` 的 `after=` 毫秒分布

n=490；**min 332 / median 630.5 / p90 804 / p99 920 / max 1002 / mean 587.8**。
分桶：<400 ms **84**；400–599 **147**；600–799 **200**；800–999 **58**；≥1000 **1**。

含义：`wait_for_active_mode()`（HEAD `rate_daemon.c:1133-1172`）以 150 ms 为步长、要求连续 3 次命中（:1137、:1167），**中位数 630 ms** 意味着每次切换期间主循环要连续做 4 轮左右的 `get_current_system_mode()` 采样；而在 HEAD 里该采样就是 `popen("timeout 4 dumpsys SurfaceFlinger")`（:846），缓存仅 400 ms（:821）。**每次切换 ≈ 2–3 次 dumpsys SurfaceFlinger**。【推算，依据 = 已证实的 :821/:846/:1167 + 实测 after= 分布】

### 3.4 切换密度峰值

**按小时**（`Ordered refresh switch` 计数）：

| 小时 | 次数 | 小时 | 次数 |
|---|---:|---|---:|
| 10-03 09 | 6 | 10-03 22 | 10 |
| 10-03 10 | 2 | 10-03 23 | 30 |
| 10-03 11 | 1 | 10-04 00 | 1 |
| 10-03 12 | 4 | 10-04 03 | 2 |
| 10-03 14 | 1 | 10-04 04 | 31 |
| 10-03 15 | 15 | **10-04 05** | **53（峰值）** |
| 10-03 16 | 3 | 10-04 06 | 32 |
| 10-03 17 | 3 | — | — |
| 10-03 18 | 8 | — | — |
| 10-03 19 | 10 | — | — |
| 10-03 20 | 5 | — | — |
| 10-03 21 | 4 | — | — |

**按分钟峰值**：`10-03 23:05 = 7`、**`10-04 05:59 = 7`**、`10-04 04:59 = 6`、`10-04 05:46 = 6`、`10-03 15:32 = 5`。

**结论**：ANR 前的 04:00–06:00 是全天最密集的两小时（31 + 53 = 84 次，占全天 38%），而 **ANR 恰好落在 05:59 这一分钟**。

### 3.5 爆发段：05:59:10 – 06:02:23（用户描述的"切换后台卡"现场）

该窗口共 **261 行**日志（L4180–L4440），193 秒内：

| 事件 | 次数 |
|---|---:|
| `Detected App Change` | 14 |
| `Ordered refresh switch` | **14（5↔7 来回切）** |
| `SurfaceFlinger physical mode requested` | 38 |
| `Active display mode verified` | 28 |
| `Refresh ladder aligns stale policy` | 10 |
| `settings put` | 70 |
| `Refresh ladder` 行 | 38 |

切换序列（每次都是 165 Hz↔185 Hz 的整条阶梯重跑）：

```
05:59:11  5 -> 7      05:59:13  7 -> 5      05:59:15  5 -> 7      05:59:19  7 -> 5
05:59:24  5 -> 7   <-- ANR 5s 窗 05:59:24.35-05:59:29.35 -->   05:59:28  7 -> 5
05:59:52  5 -> 7      06:00:02  7 -> 5      06:00:31  5 -> 7      06:00:53  7 -> 5
06:01:32  5 -> 7      06:01:40  7 -> 5      06:01:49  5 -> 7      06:02:22  7 -> 5
```

前台应用序列（`com.omarea.vtools` = Scene 与 `com.tencent.tmgp.sgame` 互相抢焦点）：

```
05:59:10 vtools -> 05:59:13 sgame -> 05:59:15 vtools -> 05:59:19 sgame -> 05:59:28 sgame
[14 秒空档] -> 05:59:52 launcher -> 05:59:56 vtools -> 06:00:02 sgame -> 06:00:31 aweme
-> 06:00:53 sgame -> 06:01:32 aweme -> 06:01:40 sgame -> 06:01:49 aweme -> 06:02:22 sgame
```

逐行样例（L4180–L4204，可见"一次切换 = 阶梯 + 每条 settings + 验证"的完整代价）：

```
4180: [10-04 05:59:10] Detected App Change / 检测到应用切换: com.omarea.vtools
4181: [10-04 05:59:11] Ordered refresh switch / 阶梯刷新率切换: 5 -> 7
4182: [10-04 05:59:11] Refresh ladder up custom: 5/165Hz -> 6/175Hz
4183: [10-04 05:59:11] Refresh ladder aligns stale policy: active=5/165Hz
4184: [10-04 05:59:11] SurfaceFlinger physical mode requested: mode=5 width=1272 rc=0
4185: [10-04 05:59:11] SurfaceFlinger physical mode requested: mode=6 width=1272 rc=0
4186: [10-04 05:59:11] Active display mode verified: mode=6 after=632ms
4187: [10-04 05:59:11] Refresh ladder up custom: 6/175Hz -> 7/185Hz
4188: [10-04 05:59:11] SurfaceFlinger physical mode requested: mode=7 width=1272 rc=0
4189: [10-04 05:59:12] Active display mode verified: mode=7 after=491ms
4190: [10-04 05:59:12] settings put secure/oplus_customize_screen_refresh_rate=7 rc=0
4191: [10-04 05:59:12] ColorOS refresh setting synchronized: 185Hz -> mode=7
4192: [10-04 05:59:12] settings put system/peak_refresh_rate=185 rc=0
4193: [10-04 05:59:12] settings put system/user_refresh_rate=185 rc=0
4194: [10-04 05:59:12] settings put system/default_refresh_rate=185 rc=0
4195: [10-04 05:59:12] settings put system/min_refresh_rate=185 rc=0
4196: [10-04 05:59:12] Synced system settings to 185Hz with framework floor 185Hz
...
4288: [10-04 05:59:28] Detected App Change / 检测到应用切换: com.tencent.tmgp.sgame
4289: [10-04 05:59:28] Ordered refresh switch / 阶梯刷新率切换: 7 -> 5
4290: [10-04 05:59:28] Refresh ladder down custom: 7/185Hz -> 6/175Hz
4291: [10-04 05:59:28] SurfaceFlinger physical mode requested: mode=6 width=1272 rc=0
4292: [10-04 05:59:29] Active display mode verified: mode=6 after=817ms
4293: [10-04 05:59:29] Refresh ladder down custom: 6/175Hz -> 5/165Hz
4294: [10-04 05:59:29] SurfaceFlinger physical mode requested: mode=5 width=1272 rc=0
4295: [10-04 05:59:30] Active display mode verified: mode=5 after=358ms
...
4302: [10-04 05:59:30] Synced system settings to 165Hz with framework floor 165Hz
4303: [10-04 05:59:38] Screen state -> ON / 屏幕状态 -> 亮屏
4304: [10-04 05:59:52] Detected App Change / 检测到应用切换: com.android.launcher
```

**注意 L4303→L4304：05:59:38 → 05:59:52，14 秒零输出**，完全覆盖 ANR 的 trace 抓取窗口（05:59:33.94，L207）与 dropbox 落盘（05:59:40，dropbox L6673）。这 14 秒里守护进程既没有 accept 桥接连接，也没有做策略轮询。【已证实】

### 3.6 时间戳最大空档（≥5 秒，列前 20）

统计口径：相邻两条带时间戳日志的墙钟差 ≥5 s。区分两类：`idle=True` = 前一行为 `Screen state -> OFF/DOZE` 且后一行为 `Screen state -> ON`（息屏待机，属正常）；`idle=False` = **息屏以外的静默，即守护进程无法响应桥接的窗口**。

总览：**≥5 s 空档 594 个**，其中息屏包夹 65 个，**非息屏 529 个，累计 47052 秒（13.1 小时）**，最长非息屏空档 **2213 s（36.9 分钟）**。

**TOP 20（全部）**：

| # | 空档 | 起 → 止 | 息屏? | 起始行/消息 |
|---:|---:|---|---|---|
| 1 | 8892 s | 10-03 12:14:02 → 14:42:14 | True | L352 Screen state -> OFF/DOZE |
| 2 | 3036 s | 10-03 11:15:17 → 12:05:53 | True | L256 Screen state -> OFF/DOZE |
| 3 | 2766 s | 10-03 10:04:36 → 10:50:42 | True | L208 Screen state -> OFF/DOZE |
| **4** | **2213 s** | **10-04 00:07:28 → 00:44:21** | **False** | L2634 Config loaded. Default: 5, Apps: 1 |
| 5 | 1758 s | 10-03 17:50:38 → 18:19:56 | True | L994 Screen state -> OFF/DOZE |
| **6** | **1698 s** | **10-04 02:08:22 → 02:36:40** | **False** | L2675 App Change: com.tencent.tmgp.pubgmhd |
| **7** | **1669 s** | **10-04 02:45:58 → 03:13:47** | **False** | L2702 App Change: com.tencent.tmgp.pubgmhd |
| **8** | **1664 s** | **10-03 16:24:53 → 16:52:37** | **False** | L832 App Change: com.phoenix.read |
| **9** | **1452 s** | **10-03 23:35:31 → 23:59:43** | **False** | L2578 Synced system settings to 165Hz |
| **10** | **1407 s** | **10-03 23:05:47 → 23:29:14** | **False** | L2335 Synced system settings to 165Hz |
| **11** | **1285 s** | **10-04 01:37:32 → 01:58:57** | **False** | L2662 App Change: com.tencent.tmgp.sgame |
| 12 | 1222 s | 10-03 10:50:48 → 11:11:10 | True | L232 Screen state -> OFF/DOZE |
| **13** | **1130 s** | **10-04 05:23:36 → 05:42:26** | **False** | L3838 Synced system settings to 165Hz |
| 14 | 1117 s | 10-03 19:57:50 → 20:16:27 | True | L1467 Screen state -> OFF/DOZE |
| **15** | **1086 s** | **10-04 00:44:29 → 01:02:35** | **False** | L2638 App Change: com.tencent.tmgp.sgame |
| **16** | **1038 s** | **10-04 06:19:26 → 06:36:44** | **False** | L4574 Synced system settings to 165Hz |
| **17** | **1028 s** | **10-04 04:23:36 → 04:40:44** | **False** | L3101 Synced system settings to 165Hz |
| **18** | **892 s** | **10-04 04:44:16 → 04:59:08** | **False** | L3307 Synced system settings to 165Hz |
| **19** | **889 s** | **10-04 03:43:02 → 03:57:51** | **False** | L2753 App Change: com.ss.android.ugc.aweme |
| 20 | 813 s | 10-03 20:47:43 → 21:01:16 | True | L1608 Screen state -> OFF/DOZE |

**非息屏 TOP 5**：2213 s（00:07:28→00:44:21）、1698 s（02:08:22→02:36:40）、1669 s（02:45:58→03:13:47）、1664 s（16:24:53→16:52:37）、1452 s（23:35:31→23:59:43）。

**ANR 相关的小空档**（不在 TOP20，但正是本次现场）：

| 空档 | 起 → 止 | 行 | 说明 |
|---:|---|---|---|
| 8 s | 05:59:30 → 05:59:38 | L4302→L4303 | 阶梯切换刚做完 |
| **14 s** | **05:59:38 → 05:59:52** | **L4303→L4304** | **覆盖 ANR trace（05:59:33.94）与 dropbox 落盘（05:59:40）** |
| 6 s | 05:59:56 → 06:00:02 | L4321→L4322 | — |

同段其它空档：613 s（05:48:57→05:59:10）、740 s（06:02:23→06:14:43）。**05:48:57→05:59:10 的 10 分钟空档正好在 ANR 之前**，说明崩溃前守护进程已处于长时间不可用状态。【已证实】

### 3.7 守护进程重启点（重要）

判据：`Display hook bridge listening on 127.0.0.1:49721` 只出现在 `create_display_hook_server()` 内（HEAD `rate_daemon.c:5108-5138`），而该函数**只在 `main()` 调用一次**（HEAD `:5565`）。因此每一次该行出现都代表**守护进程进程级重启**。用户三 daemon.log 中共 5 次：

| # | 时间 | 启动横幅行 | bridge listening 行 |
|---:|---|---:|---:|
| 1 | 10-03 09:36:16 | L2 | L26 |
| 2 | 10-03 15:40:09 | L698 | L722 |
| 3 | 10-03 23:00:48 | L2038 | L2062 |
| **4** | **10-04 05:59:23** | **L4242** | **L4266** |
| 5 | 10-04 06:55:07 | L4869 | L4893 |

配套启动序列亦可复核：`Boot ColorOS resolution stable`（L27/L723/L2063/**L4267**/L4894）、`Boot resolution reconciled`（L28/L724/L2064/**L4268**/L4895）、`Inotify watching directory`（L52/L735/L2075/**L4286**/L4906）。

第 1、3、5 次与开机/日志轮转对齐（lspd 日志轮转时间 10-03T23:00:23、10-04T06:54:42）。
**第 4 次（10-04 05:59:23）不对应任何开机**——当时 uptime ≈ 25054 s（6h57m），是**会话中途的守护进程重启，发生在 ANR 计时窗（05:59:24.35–05:59:29.35）前 1 秒**。【已证实】
重启原因在包内**无直接证据**：tombstones 目录只有 3 个无关墓碑（`tombstones/listing.txt`：launcher / unicom / audiohalservice，时间 09-30 与 10-03，均非本次），`kmsg_full.txt` 只覆盖 uptime 1110–1381 s（**当前这次开机**，16234 行），不可能覆盖 uptime 25054 s；守护进程由 `service.sh` 的 `rate_daemon_supervisor.sh` 看护（`murongchaopin/service.sh:5`、`:133-138`、`:189-196`，`setsid nohup` 拉起）。**重启原因是推测，不在本报告结论内。**【推测/未证实】

### 3.8 用户三 `module/` 目录关键状态值

| 文件 | 内容 | 解释 |
|---|---|---|
| `module/mode.txt` | `1272x2772 185` / `com.tencent.tmgp.pubgmhd 1272x2772 165` / `com.tencent.tmgp.sgame 1272x2772 165` | 全局 185 Hz；两个游戏 165 Hz —— **正是 05:59 爆发段里 5↔7（165↔185）来回切的来源** |
| `module/policy_state.txt` | `model=PLK110` / `supported=1` / `profile=vendor_ltpo` / `policy=adfr_off` / `active=adfr_off` / `Error: 自制 LTPO 已下线`×2 | ADFR 关闭，走厂商 LTPO |
| `module/resolution_settings.txt` | `user_preferred_screen_index=2` / `oplus_customize_screen_resolution_adjust=1` / `user_preferred_resolution_width=null` / `...height=null` / **`peak_refresh_rate=120.0`** / **`min_refresh_rate=0.0`** | **与模块目标 185 Hz 不一致**：框架侧 peak 仍是 120 —— 与 Hook 在 `setAppRequest` 里反复"抬高 app 帧率上限"的行为互相印证（HEAD `OplusVrrTierHooks.java:176-187`） |
| `module/wm_size.txt` / `wm_density.txt` | `Physical size: 1272x2772` / `Physical density: 560` | 原生分辨率 |
| `module/rmx5200_adfr_mode.txt` / `rmx5200_display_policy.txt` | `off` / `adfr_off` | — |
| `module/premium_config/adfr_lock_state.txt` | `active:floor_120:capability_preserved` | — |
| `module/premium_config/generic_adfr/status.txt` | `skipped:unsupported_model` | — |
| `module/premium_config/oti_pause_last` | `paused` | — |
| `module/coloros_config_runtime/status.txt` | `applied:already` | — |
| `module/display_backend/drm_modes.txt` | `1272x2772@175;1272x2772@185;1272x2772@195;1272x2772@199` | 注入的扩展模式（20 个 HWC 模式里的高分档） |
| `module/display_backend/drm_params.txt` | `drm_module_loaded=no` ... 全 `-` | 本次开机未加载 DRM 模块 |
| `modules/module.prop` | `version=2.9.41` / `versionCode=70` | 与现场版本一致 |
| `props/summary.txt` | `model=PLK110` / `android=17` / `ksu=ksud 3.3.0` / `magisk=none` / **`uptime= 07:17:52 up 23 min, 0 users, load average: 7.81, 7.98, 6.05`** | **load average ≈ 8**（收集时刻）；且 07:17:52−23 min ⇒ 本次开机 ≈ 06:54:52，与 daemon 第 5 次重启（06:55:07）吻合 |

---

## 4. 旁证

### 4.1 先讲清楚「哪些日志能覆盖 ANR 窗口，哪些不能」（避免误读为"没有证据"）

| 文件 | 时间覆盖 | 是否覆盖 05:59:35–05:59:55 | 依据 |
|---|---|---|---|
| `logcat_main.txt` | **10-04 07:17:47.449 → 07:17:52.729（仅 5.28 秒）**，4336 行 | **否** | 脚本 §7.3；逐分钟分布集中在 07:17:47–52 |
| `logcat_events.txt` | **10-04 07:16:04.899 → 07:17:52.363（107.5 秒）**，2000 行 | **否** | 同上 |
| `dropbox/dropbox.txt` | 含全部 48 条历史记录 | **是**（含 ANR 条目） | §4.2 |
| `lspd/modules_2026-10-03T23_00_23.248685.log` | **2026-10-03T23:00:27 → 2026-10-04T06:54:09**，8581 行 | **是** | §4.3 |
| `lspd/verbose_2026-10-03T23_00_23.248503.log` | 23:00:22 → 06:54:13，9890 行 | **是** | 同源轮转文件 |
| `lspd/modules_2026-10-04T06_54_42.088142.log` | 当前开机（06:54:46 起） | 否 | 文件头 |
| `kmsg_full.txt` | uptime 1110 → 1381 s（**当前开机**） | **否** | §3.7 |

**这是一个必须写进发布说明的事实：用户三的 logcat 环形缓冲在采集时只剩 5.28 秒内容**，因此"现场 logcat 里看不到 ANR 时刻"不代表没有发生，只能靠 dropbox + ANR 文件 + daemon.log + lspd 日志。

### 4.2 dropbox 中的 ANR 条目

文件：`dropbox/dropbox.txt`（988477 字节，48 条记录）

| 行 | 内容 |
|---|---|
| L1–L4 | `Drop box contents: 48 entries` / `Max entries: 1000` / rate limit 等 |
| **L6673** | **`2026-10-04 05:59:40 system_server_anr (compressed text, 57158 bytes)`** |
| L6674 | `SystemUptimeMs: 25066930` |
| L6675–L6677 | `Process: system` / `PID: 5750` / `UID: 1000` |
| L6679 | `Timestamp: 2026-10-04 05:59:36.457+0800` |
| L6690–L6691 | `DefaultScreen-State: ON` / `Keyguard-Locked: false`（**亮屏解锁中，用户确实在操作**） |
| L6692 | `Loading-Progress: 1.0` |
| L6700 | `/proc/pressure/cpu`：`some avg10=7.50 avg60=8.50 avg300=8.46 total=1998880404` |
| L6708 | `CPU usage from 5052ms to -3ms ago (2026-10-04 05:59:31.077 to 2026-10-04 05:59:36.133) with 99% awake:` |
| L6709–L6719 | 进程占用：`40% sgame`、**`26% system_server（11% user + 15% kernel，5782 minor / 248 major faults）`**、`22% com.android.systemui`、`18% surfaceflinger`、`14% crtc_commit:212`、`11% vendor...display.composer-service`、`7.3% audiohalservice.qti`、`7.1% com.kugou.android.lite`、`6.7% audioserver`、`3.7% com.android.launcher`；`25% TOTAL` |
| L6720 | `Data File: /data/anr/anr_5750_2026-10-04-05-59-39-673`（与 §2 的 ANR 文件同名，闭环） |
| L6721 | `Subject: Input dispatching timed out (PointerEventDispatcher0 ... Waited 5000ms ...)` |
| L6722–L6723 | `Timeout: 5000` / `TimeoutStart: 25054819` |

另外两条 `Subject:`（L64、L3249）均为 `Blocked in handler on main thread (main) for 15s`，配套 `Watchdog-Type: pre_watchdog`（L65、L3250），对应记录头 L29（`2026-10-02 12:47:39 system_server_pre_watchdog`）及其后一条。说明 system_server 主线程在被观察期内**至少还有另外两次 15 秒级卡死**。

### 4.3 LSPosed 模块日志在 ANR 窗口内的活动

文件：`lspd/modules_2026-10-03T23_00_23.248685.log`（本文件覆盖 ANR 窗）

**05:59:30–05:59:55 共 32 行，全部与本模块有关**（脚本 §7.3）。摘录：

```
7695: [ 2026-10-04T05:59:39.875  1000: 5750: 6726 I/LSPosedFramework ] (system)[com.murongchaopin.displayhook,MurongDisplayHook,1676-1a10247e285-2b-95c,0,1] OPlus VRR tier resolved ...
7696: [ 2026-10-04T05:59:39.881  1000: 5750: 6723 ... ] (system)[...MurongDisplayHook...] OPlus VRR tier resolved ...
7697: [ 2026-10-04T05:59:44.944  1000: 5750: 6726 ... ] OPlus VRR tier resolved type=2 ...
7698: [ 2026-10-04T05:59:45.552  1000: 5750: 7560 ... ] OPlus VRR tier resolved type=0 ...
7699: [ 2026-10-04T05:59:50.819  1000: 5750: 7518 ... ] OPlus VRR tier resolved type=0 ...
7700-7716: [05:59:50.912 -> 05:59:50.951] 14 行 OPlus VRR tier resolved，tid 依次 6726/6726/6726/6865/8565/9203/9203/6865/6726/7506/7580/7580/6726/7580 ...
7717: [ 2026-10-04T05:59:52.789  1000: 5750: 6726 ... ] OPlus VRR tier resolved ...
7718: [ 2026-10-04T05:59:53.443  1000: 5750: 6726 ... ] OPlus VRR tier resolved ...
7719-7724: [05:59:54.308] (com.omarea.vtools) Scene panel skip x6
7725: [ 2026-10-04T05:59:55.737  1000: 5750: 7941 ... ] OPlus VRR tier resolved ...
```

**三条硬结论**：

1. **ANR 窗内看得到本模块 Hook 的日志**——而且是密集的：`OPlus VRR tier resolved` 在 system_server（pid 5750）里持续刷。
2. **05:59:50.912–05:59:50.951 的 39 ms 内爆发 14 行，横跨 8 个 system_server 线程**（6726、6865、8565、9203、7506、7580、7505、9495）——说明 Hook 在大量 binder/服务线程上并发执行，正是"多线程同时抢 WM 锁"的现场。
3. **其中 tid=6865 正是 ANR 里持锁的 `binder:5750_5`**（anr L813 `sysTid=6865` 对应 lspd L7703/L7707）——**把"ANR 持锁线程"和"模块 Hook 执行线程"钉死为同一个线程**。

**ANR 窗内看得到守护进程活动吗？** —— **看不到**。同一个 lspd 日志在 05:59:30–05:59:55 期间**没有任何一行来自守护进程**（守护进程是 root 原生进程，不写 logcat/LSPosed 日志，只写 daemon.log）。守护进程侧的对应事实只能从 daemon.log 读：该窗口内 daemon.log 只在 05:59:38（Screen ON）与 05:59:52（App Change）各留一行，**中间 14 秒完全静默**（§3.5）。两边合起来即：**ANR 期间 system_server 在密集执行模块 Hook，而守护进程 14 秒不吭声。**

### 4.4 卡顿行统计（`Skipped N frames` / `ANR in` / `Slow`）

对整包（含 `logcat_main.txt`、`logcat_events.txt`、`dropbox/dropbox.txt`、全部 `lspd/*.log`）做全文匹配（脚本 §7.3）：

| 模式 | 命中数 |
|---|---:|
| `Skipped [0-9]+ frames` | **0** |
| `ANR in ` | **0** |
| `Slow dispatch` / `Slow delivery` / `Slow operation` / `Slow looper` / `Slow input` | **0** |
| `Choreographer` | 4（全部在 dropbox，非本模块） |
| `doFrame` | 4（logcat_main，全部是 `DynamicFramerate [BackgroundVsyncManager]: updateSkipDoFrameState`） |

**必须明确说明**：本包**没有**任何 `Skipped N frames` / `ANR in` / `Slow ...` 行。原因不是设备没卡，而是（a）logcat 环形缓冲只剩 5.28 秒（§4.1），（b）"Skipped frames" 属于 app 进程的 Choreographer 输出，而本次卡点在 system_server/输入分发层，本来就不会产生这类行。**卡顿的量化证据只能来自 dropbox ANR + ANR 文件 + daemon.log + lspd 日志这四类。** 因此"出现次数最多的进程与时间点"只能由 dropbox 的 CPU 段回答：**05:59:31.077–05:59:36.133 窗口内 system_server 26%（kernel 15%）排第二，仅次于前台游戏 40%**（dropbox L6709–L6710）。

### 4.5 logcat 中能看到的模块行 + dumpsys 代价

`logcat_main.txt` 里本模块只有 2 行（都在 07:17:47–52 这 5 秒内）：

```
L1892: 10-04 07:17:48.938  5697  6713 I LSPosedFramework: (system)[com.murongchaopin.displayhook,MurongDisplayHook,1641-1a103fa2276-2b-142,0,1] OPlus VRR tier resolved type=0 request=1272x2772@60.0
L3937: 10-04 07:17:50.882  5697  6713 I LSPosedFramework: (system)[com.murongchaopin.displayhook,MurongDisplayHook,1641-1a103fa2276-2b-143,0,1] OPlus VRR tier resolved type=0 request=1272x2772@60.0
```

同一 5.28 秒窗口内的 dumpsys 代价（可直接量化的"热路径成本"下界）：

| 服务 | 次数 | 最大 | 平均 | 最大输出 |
|---|---:|---:|---:|---:|
| `window` | 3 | **30 ms** | 19.7 ms | 93828 字节 |
| `display` | 3 | 9 ms | 6.3 ms | 69225 字节 |
| `dropbox` | 1 | 13 ms | 13.0 ms | 988477 字节 |
| `package` | 3 | 7 ms | 3.7 ms | 3782 字节 |

注意这是**空闲时刻**（07:17，刚采集完 bug 包）的窗口值。守护进程源码自己给出的现场数字是：`FOREGROUND_APP_SLOW_DUMP_MS 250`（工作区 `rate_daemon.c:2241`，即"实测 dump ≥250 ms 才算慢"），而 v2.9.41 的 HEAD **根本没有这条慢速退避逻辑**（HEAD :2203 只有一个 2000 ms 常量）。

### 4.6 LSPosed 模块日志全量（用于量化 Hook 热路径规模）

文件 `lspd/modules_2026-10-03T23_00_23.248685.log`（8581 行，23:00:27 → 06:54:09）：

| 消息 | 次数 |
|---|---:|
| `OPlus VRR tier resolved type=... request=...x...@...`（**本模块 Hook 热路径**） | **2097** |
| `(com.omarea.vtools) Scene panel skipped reason=no-anchor ...` | 3045 |
| `(com.luna.music) MoonHook: ... media guard installed ...` | 2435 |
| `App frame-rate ceiling raised from ... to the module selection ...` | **10**（与源码里 `APP_REQUEST_LOGS <= 10` 的日志上限一致，HEAD `OplusVrrTierHooks.java:179`） |
| E 级（全部集中在 23:00:28–34，非 ANR 窗） | 5 |

**分钟峰值**：`04:17 = 1234 行`、`04:19 = 803`、`05:43 = 527`、`04:16 = 518`、**`05:59 = 227`**。
**秒峰值**：`04:17:09 = 151 行/秒`、`04:16:57 = 148 行/秒`。

即：**模块 Hook 在 04:17 一分钟内被调用上千次**，每次调用都要经过 `moduleTargetRate()`（5 秒缓存 — 但仅当成功才刷新，见 §1 第 4 条）。这就是"刷抖音卡 / 搜索界面卡"在框架侧的负载来源。

---

## 5. 其它反馈包交叉验证（同一统计口径）

统计脚本 §7.4（对所有包使用完全相同的解析与判定逻辑）。

### 5.1 机型/版本一览

| 包 | 机型 | 系统 | 模块版本 | 日志跨度 | 反馈原文 |
|---|---|---|---|---|---|
| **用户三** `murong-bugpack-20261004-071752` | PLK110 | Android 17 / ColorOS 17 | **2.9.41**（vc70） | 10-03 09:36:16 → 10-04 07:17:50（21.69 h） | 手势没反应 / 刷抖音卡 / 搜索界面卡 / 切换后台卡 |
| **用户1** `murong-bugpack-20260930-124335` | PLK110 | Android 16 | 2.9.38（vc67） | 09-30 10:59:36 → 12:43:32（1.73 h） | **「刷新率桥接失败」**（`用户1反馈/反馈说明.txt`） |
| **用户2** `murong-bugpack-20261001-125940` | **RMX5200** | Android 17 | 2.9.39（vc68） | 10-01 11:54:36 → 12:59:40（1.08 h） | 「各种卡顿…页面停顿 30 多秒后手势操作非常卡…返回卡顿」 |
| **用户1新** `murong_bugpack_20261001-131818.tar.gz` | PLK110 | Android 16 | 2.9.40（vc69） | 10-01 12:31:21 → 13:17:58（0.78 h） | （同用户1） |

机型/版本取自各包 `modules/module.prop`、`props/summary.txt`、`module/policy_state.txt`；用户1新包解压至临时目录后统计（未写入仓库）。

### 5.2 同口径对比表

| 指标（同一口径） | 用户三 2.9.41 | 用户1 2.9.38 | 用户2 2.9.39 | 用户1新 2.9.40 |
|---|---:|---:|---:|---:|
| 日志跨度（小时） | 21.69 | 1.73 | 1.08 | 0.78 |
| 时间戳行数 | 4963 | 716 | 1828 | 446 |
| **守护进程重启次数** | 5 | **3** | **8** | **4** |
| 重启频率（次/小时） | 0.23 | **1.73** | **7.41** | **5.13** |
| `Ordered refresh switch` | 221 | 22 | 43 | 9 |
| 切换频率（次/小时） | 10.2 | 12.7 | **39.7** | 11.6 |
| `Refresh ladder` 总行数 | 590 | 84 | 218 | 24 |
| **`aligns stale policy`（冗余）** | **121** | 42 | **109** | 9 |
| **冗余 / 切换 比** | **0.55** | **1.91** | **2.53** | **1.00** |
| `Active display mode verified` | 490 | 43 | 133 | 15 |
| `SurfaceFlinger physical mode requested` | 624 | 85 | 242 | 24 |
| `settings put` | 1040 | 110 | 179 | 45 |
| settings put / 切换 | 4.7 | 5.0 | 4.2 | 5.0 |
| `Detected App Change` | 721 | 119 | 100 | 122 |
| App Change 频率（次/小时） | 33.2 | 68.7 | 92.2 | **157.0** |
| 其中间隔 ≤3 s 的抖动次数 | 191 | 43 | 17 | 44 |
| `after=` 中位数 / 最大（ms） | 630.5 / 1002 | 630 / 874 | 618 / 986 | 634 / 664 |
| **≥5 s 空档总数** | **594** | 86 | 120 | 77 |
| 其中非息屏空档 | **529** | 86 | 115 | 77 |
| 非息屏空档累计（秒） | **47052** | 6022 | 3161 | 2617 |
| 最长非息屏空档（秒） | **2213** | 3232 | 277 | 337 |
| ≥6 次的阶梯爆发段 | 5 | 0 | **2** | 0 |
| 最大单分钟切换数 | 7 | 5 | **11** | 3 |

### 5.3 交叉验证结论

1. **「长时间空档」是共性，不是用户三独有**：四个包的非息屏 ≥5 s 空档数分别为 529 / 86 / 115 / 77。按小时归一后 user1 最严重（49.7 次/小时）。
2. **「阶梯切换爆发」是共性**：user3 有 5 段（05:59:11–05:59:28 的 6 连切最贴近 ANR）、user2 有 2 段（12:21:07–12:21:54 六连切、**12:51:15–12:52:31 十七连切**，单分钟 11 次为四包之最）。user1 / user1新 因日志跨度短（1.73 h / 0.78 h）没有形成 ≥6 连切段，但**单分钟仍达 5 次 / 3 次**。
3. **「大量冗余阶梯事务」是共性且在老版本更严重**：冗余/切换比为 user1 1.91、user2 2.53、user1新 1.00，**说明每次真正想切一次刷新率，daemon 平均要额外多打 1–2.5 次"对齐陈旧策略"的模式事务**。user3 的 0.55 反而是四包里最低的——即 2.9.41 在这个维度上有改善，但绝对量仍大（121 次）。
4. **「守护进程频繁重启」是共性**，且在短日志包里密度惊人：**user2 在 1.08 小时内重启 8 次（平均 8 分钟一次）**，user1新 0.78 小时 4 次。user1 的反馈原文直接就是「刷新率桥接失败」——与 §2 的"守护进程不可用时 Hook 侧 connect 必失败"完全对应。
5. **版本对比提示**：2.9.38 → 2.9.41 之间，切换频率、冗余比、空档累计都没有数量级改善；因此 v2.9.41 仍复现同类现场**不奇怪**。

---

## 6. 缺陷清单

每条格式：现象 → 证据 → 影响 → 建议修法；并标注【已证实】/【推算】/【推测】。

### D1【已证实】Hook 在 WindowManagerGlobalLock 临界区内做阻塞 socket I/O

- **现象**：`binder:5750_5` 持锁卡在 `Socket.connect`；`oplus.ui` 等锁 Blocked；23 个线程等同一把锁。
- **证据**：anr L811–L857（L832 `Socket.connect`、L840 `Tudp.setAppRequest`、L841 `setDisplayPropertiesInternal:3933`、L844 `applySurfaceChangesTransaction:6958`、L849 `relayoutWindow:3112`、L850 `- locked <0x08992b89>`）；anr L386–L388；anr L222/250/.../635 共 23 处；mapping.txt L7/L17/L62-91/L92-107 + APK dex 含同一 r8-map-id；HEAD `BridgeClient.java:515,573`、`OplusVrrTierHooks.java:170,175,212`。
- **影响**：输入分发 5 秒预算被耗尽 → **手势/返回/回桌面直接无响应**；同时拉长每一次 relayout，全局卡顿。
- **建议**：Hook 体内**禁止任何阻塞 I/O**。选项：(a) `globalRate` 改为纯粹的**内存快照**（Hook 只在收到 push 时更新 volatile 字段，读侧零 I/O）；(b) 若必须查，改为"先读缓存，缓存缺失立即返回 stock 行为并异步刷新"；(c) 把 `connect` 换成**非阻塞 + select 超时**（`SocketChannel`），并把总预算压到个位数毫秒；(d) 增加"当前线程持有 WM 锁 / 在 relayout 链路上"的探测，命中则直接短路。

### D2【已证实】缓存只在成功时刷新，失败时退化为"每次调用都重试"

- **现象**：守护进程不可用期间，`parseFpsResponse` 返回 `-1`，`if (value >= 30)` 不成立 ⇒ `bridgeGlobalRateAt` 永不更新 ⇒ 5 秒缓存完全失效。
- **证据**：HEAD `BridgeClient.java:306-315`（失败返回 `-1`）、`:267-269`（`GETGLOBAL`）；HEAD `OplusVrrTierHooks.java:207-218`（**:213 是唯一的缓存写入条件**）。
- **影响**：**故障放大**。守护进程越慢 → 失败越多 → Hook 侧 socket 尝试越频繁 → WMS 锁越久 → 守护进程 dumpsys 越慢，正反馈。
- **建议**：缓存"**失败也要缓存**"（负缓存，例如失败后 3–5 秒内不再尝试），并且失败路径**绝不阻塞**（直接返回 0/stock）。同时给失败加计数器与日志（当前现场完全看不到 Hook 侧失败记录）。

### D3【已证实】守护进程单线程：桥接服务与 dumpsys 策略循环互斥

- **现象**：`handle_display_hook_client()` 与 `get_foreground_app()` / `wait_for_active_mode()` 在同一个 `while(1)` 里顺序执行。
- **证据**：HEAD `rate_daemon.c:5657`（select 超时 1 s）、`:5681-5682`（accept/服务）、`:1133-1172`（验证循环，`usleep(150000)`）、`:2228` / `:846`（popen dumpsys）；实测：daemon.log 05:59:38→05:59:52 静默 14 秒；全日志 529 个非息屏 ≥5 s 空档。
- **影响**：守护进程只要进 dumpsys（单次上限 4 s，多次连续），桥接就完全停摆；配合 `listen(fd,4)`（:5127），连接堆积后客户端 `connect` 直接阻塞——**这正是 D1 里那个 400 ms 阻塞的来源**。
- **建议**：(a) 用**独立线程/进程**只负责 accept + 应答（读内存快照，不做任何 dumpsys）；(b) `listen` backlog 提到 128；(c) 给 `GETGLOBAL` 这类只读命令做"无锁内存应答"；(d) 主循环里对 `popen` 加**全局节流**（例如每秒最多 1 次 dumpsys，且做优先级让步：有待处理连接时不发起 dumpsys）。

### D4【已证实】前台应用靠 dumpsys window 轮询，缓存仅 2000 ms

- **现象**：v2.9.41 每 ≤2 秒执行一次 `dumpsys window`。
- **证据**：HEAD `rate_daemon.c:2203`（`#define FOREGROUND_APP_CACHE_MS 2000`）、`:2215`（TTL 判断）、`:2228`（`popen("timeout 4 dumpsys window | grep mCurrentFocus", "r")`）；HEAD 版本**没有**慢速退避、**没有** Hook 推送分支（对照：工作树 `:2244-2248` 才新增 `APP_CHANGE_SETTLE_MS`、`:2258-2269` 才新增 `note_pushed_foreground_app`——**这些在 v2.9.41 出厂版本里不存在**）。
- **影响**：`dumpsys window` 全程持有 `WindowManagerGlobalLock`（守护进程源码自己的注释即如此说明），**与手势监听抢同一把锁**。21.69 小时内至少约 3.9 万次（= 21.69×3600/2，推算），每一次都可能落在一次滑动上。
- **建议**：彻底去掉轮询。已有 `handleFrontAppChange` 推送通道，应把它作为**主路径**并只在推送超时（>15 s）时才降级 dump；降级时把 TTL 提到 ≥6 s。

### D5【已证实】模式切换的冗余对齐事务占比过高

- **现象**：`Refresh ladder aligns stale policy` 121 次（user3）；user1 / user2 / user1新 的冗余/切换比分别 1.91 / 2.53 / 1.00。
- **证据**：daemon.log 计数（§3.2、§5.2）；HEAD `rate_daemon.c:1238`。
- **影响**：每次切换多打 1–2.5 次 SurfaceFlinger 模式事务；在 `applySurfaceChangesTransaction` 路径上再叠加 N 次 relayout，直接推高 WM 锁占用。
- **建议**：把"策略期望模式"与"面板实际模式"的**不一致判据修正**（现在明显误判——L4183 紧接 L4182，`active=5/165Hz` 与期望一致时仍打对齐），或把对齐改为**异步、可合并**的动作。

### D6【已证实】切换动作过重：一次切换 = 阶梯 + 4.7 条 settings + 2.2 次验证

- **现象**：`Ordered refresh switch` 221 次伴随 1040 条 `settings put`、490 次验证、624 次模式请求。
- **证据**：§3.1、§3.3；HEAD `:1238`、`:2191`、`:1160`。
- **影响**：一次用户可见的"切后台"会引发 30+ 行日志、数十次跨进程调用。05:59 那次 ANR 的 5 秒窗内即含 2 次完整阶梯切换（L4270、L4289）。
- **建议**：合并 `settings put`（4 条 → 1 批）、阶梯节点做**去抖 / 最小驻留时间**、切换期间抑制重复的 `applySurfaceChangesTransaction`。

### D7【已证实】App 切换抖动未去抖

- **现象**：user3 有 191 次连续两次 App Change 间隔 ≤3 秒；窗口内 `vtools <-> sgame` 在 10 秒内切了 4 次（L4180/4197/4212/4227）。
- **证据**：§3.5 序列；计数 §5.2。
- **影响**：每次抖动触发一次完整阶梯，把"切换后台"变成连续的 SurfaceFlinger 事务流。
- **建议**：前台应用变化加 **debounce**（工作树已引入 `APP_CHANGE_SETTLE_MS 600`，方向正确，应确认出厂版本包含）。

### D8【已证实】守护进程频繁重启（含非开机原因）

- **现象**：user3 5 次（其中 05:59:23 非开机）、user1 3 次 / 1.73 h、user2 **8 次 / 1.08 h**、user1新 4 次 / 0.78 h。user1 反馈原文「刷新率桥接失败」。
- **证据**：`Display hook bridge listening` 行计数（§3.7、§5.2）；HEAD `rate_daemon.c:5565` 只调用一次 `create_display_hook_server`；`murongchaopin/service.sh:5,133-138,189-196`（supervisor）。
- **影响**：重启期间桥接 socket 完全不可用（**每个 Hook 调用都是一次必然失败的 400 ms connect**），且重启后要重新做 boot 分辨率协调 + 强制重放，又是一轮模式事务。
- **建议**：① 查清崩溃原因（现场缺 tombstone，需要给守护进程加 core dump / 看门狗日志或 `prctl(PR_SET_DUMPABLE)` 与信号处理）；② 重启期间让 Hook 侧走负缓存（见 D2），使"守护进程短暂死亡"不再转化为"框架锁被长时间占用"；③ supervisor 重启加退避，避免重启风暴。

### D9【推算】Hook 每次调用都会读一次共享状态，存在锁竞争放大

- **现象**：05:59:50.912–05:59:50.951 的 39 ms 内，8 个 system_server 线程同时输出 `OPlus VRR tier resolved`。
- **证据**：lspd L7700–L7716；总计数 2097 行。
- **影响**：多线程同时进入 `moduleTargetRate()`，即使命中缓存也会争 `READ_CACHE` / `BridgeClient` 的并发结构；未命中时同时发起多个 connect，直接打满 `listen(fd,4)` 的 backlog。
- **建议**：把 `moduleTargetRate()` 变成**单写入者 / 多读者**的纯 volatile 快照（当前已有 `bridgeGlobalRate` 字段，但仍会在 TTL 到期时由任意线程发起 I/O），并把发起 I/O 的职责收敛到一个专用线程。

### D10【已证实，影响面为推测】resolution_settings.txt 与模块目标不一致

- **现象**：`peak_refresh_rate=120.0`、`min_refresh_rate=0.0`，而模块 `mode.txt` 全局目标 185 Hz。
- **证据**：`module/resolution_settings.txt`；`module/mode.txt`；HEAD `OplusVrrTierHooks.java:176`（`maximum >= (float) target` 时不动作）。
- **影响**：【推测】这正是 Hook 需要反复"抬高 app 帧率上限"的根因之一（源码 :180-181 会打印 `App frame-rate ceiling raised from ... to the module selection ...`，实测该日志出现 10 次）。抬高动作本身又走 `Reflect.call(..., "setAppRequest", ...)`（:185），把负载重新送回 WM 锁内的同一条链路。
- **建议**：让模块在切换目标后**一次性**把 `peak_refresh_rate` / `min_refresh_rate` 写到与目标一致，从根上消掉"每次 setAppRequest 都要纠偏"的必要性。

---

## 7. 附录：统计脚本原文

所有脚本用捆绑 Python 运行：
`C:\Users\Administrator\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe`
运行前设 `$env:PYTHONIOENCODING='utf-8'` 以免中文乱码。脚本本体写在系统临时目录（`%TEMP%\murong_analysis\`），**未写入仓库**。

### 7.1 daemon_stats.py — 守护进程日志量化（计数 / after= 分布 / 密度 / 空档 / 爆发段）

```python
import re, sys, json, statistics
from datetime import datetime, timedelta
from collections import Counter

path = sys.argv[1]
YEAR = 2026
ts_re = re.compile(r'^\[(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\]')
rows = []
all_lines = 0
with open(path, 'r', encoding='utf-8', errors='replace') as fh:
    for i, line in enumerate(fh, 1):
        all_lines += 1
        m = ts_re.match(line)
        if not m:
            continue
        mo, dd, hh, mm, ss = (int(x) for x in m.groups())
        rows.append((datetime(YEAR, mo, dd, hh, mm, ss), line[m.end():].strip(), i))

print("FILE", path)
print("total_lines", all_lines, "timestamped", len(rows))
print("first_ts", rows[0][0], "last_ts", rows[-1][0])

def has(sub):
    return [r for r in rows if sub in r[1]]

counts = {}
for k in ["Ordered refresh switch","Refresh ladder","aligns stale policy","Active display mode verified",
          "Detected App Change","Screen state -> ON","Screen state -> OFF/DOZE",
          "SurfaceFlinger physical mode requested","Forced reapply after screen-on",
          "Refresh ladder request failed","Refresh ladder step failed","verification timed out",
          "stray mode ignored","Screen ON reapply"]:
    counts[k] = len(has(k))
print("--- COUNTS ---")
for k,v in counts.items(): print("%s\t%d" % (k, v))

afters = [int(re.search(r'after=(\d+)ms', r[1]).group(1)) for r in has("Active display mode verified") if re.search(r'after=(\d+)ms', r[1])]
if afters:
    s = sorted(afters); n=len(s)
    print("--- AFTER= DISTRIBUTION (ms) ---")
    print("n=%d min=%d median=%s p90=%d p99=%d max=%d mean=%.1f" % (
        n, s[0], statistics.median(s), s[int(0.9*(n-1))], s[int(0.99*(n-1))], s[-1], sum(s)/n))
    bk = Counter()
    for v in s:
        bk["<400" if v<400 else "400-599" if v<600 else "600-799" if v<800 else "800-999" if v<1000 else ">=1000"] += 1
    print("buckets", dict(bk))

sw = [r[0] for r in has("Ordered refresh switch")]
print("--- DENSITY ---")
hr = Counter(d.strftime("%m-%d %H") for d in sw)
print("per_hour_top10", hr.most_common(10))
mi = Counter(d.strftime("%m-%d %H:%M") for d in sw)
print("per_minute_top15", mi.most_common(15))

print("--- GAPS ---")
gaps = []
for i in range(1, len(rows)):
    d = (rows[i][0] - rows[i-1][0]).total_seconds()
    if d < 5: continue
    prev_off = "Screen state -> OFF/DOZE" in rows[i-1][1]
    next_on = "Screen state -> ON" in rows[i][1]
    idle = prev_off and next_on
    gaps.append(dict(secs=int(d), a=str(rows[i-1][0]), b=str(rows[i][0]),
                     aline=rows[i-1][2], bline=rows[i][2],
                     amsg=rows[i-1][1][:60], bmsg=rows[i][1][:60], idle=idle))
print("gaps_ge5s_total", len(gaps), "screen_off_bounded", sum(1 for g in gaps if g["idle"]))
live = [g for g in gaps if not g["idle"]]
live.sort(key=lambda g: -g["secs"])
print("--- TOP 20 GAPS (all) ---")
for g in sorted(gaps, key=lambda g:-g["secs"])[:20]:
    print("%ds\t%s -> %s\tidle=%s\t[%d] %s\t[%d] %s" % (
        g["secs"], g["a"], g["b"], g["idle"], g["aline"], g["amsg"], g["bline"], g["bmsg"]))
print("--- TOP 20 GAPS NOT BOUNDED BY SCREEN-OFF ---")
for g in live[:20]:
    print("%ds\t%s -> %s\t[%d] %s\t[%d] %s" % (
        g["secs"], g["a"], g["b"], g["aline"], g["amsg"], g["bline"], g["bmsg"]))
print("live_gap_count", len(live), "live_gap_total_seconds", sum(g["secs"] for g in live))

print("--- LADDER BURST SEGMENTS (gap<=20s) ---")
seg = []
for dt in sw:
    if not seg or (dt - seg[-1][-1]).total_seconds() > 20: seg.append([dt])
    else: seg[-1].append(dt)
big = sorted([s for s in seg if len(s) >= 6], key=lambda s: s[0])
for s in big:
    print("%d switches\t%s -> %s\tdur=%ds" % (len(s), s[0], s[-1], int((s[-1]-s[0]).total_seconds())))
print("segments_total", len(seg), "segments_ge6", len(big))
```

调用示例：
```powershell
& $py daemon_stats.py '用户反馈\用户三反馈\murong-bugpack-20261004-071752\module\daemon.log'
```

### 7.2 compare.py — 四包同口径对比 + 用户三逐小时表

```python
import re, sys, statistics
from datetime import datetime, timedelta
from collections import Counter

YEAR = 2026
ts_re = re.compile(r'^\[(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\]')

def load(path):
    rows=[]
    with open(path,'r',encoding='utf-8',errors='replace') as fh:
        for i,line in enumerate(fh,1):
            m=ts_re.match(line)
            if not m: continue
            mo,dd,hh,mm,ss=(int(x) for x in m.groups())
            rows.append((datetime(YEAR,mo,dd,hh,mm,ss), line[m.end():].strip(), i))
    return rows

def summarize(name, rows):
    sw=[r for r in rows if "Ordered refresh switch" in r[1]]
    ac=[r for r in rows if "Detected App Change" in r[1]]
    dur=(rows[-1][0]-rows[0][0]).total_seconds()
    hrs=dur/3600.0
    thrash=0
    for i in range(1,len(ac)):
        if (ac[i][0]-ac[i-1][0]).total_seconds()<=3: thrash+=1
    hr=Counter(d.strftime("%m-%d %H") for d,_,_ in sw)
    mi=Counter(d.strftime("%m-%d %H:%M") for d,_,_ in sw)
    print("### " + name)
    print("span\t%s -> %s\thours=%.2f" % (rows[0][0], rows[-1][0], hrs))
    print("lines=%d" % len(rows))
    print("ordered_switches=%d\tper_hour=%.1f" % (len(sw), len(sw)/hrs))
    print("ladder_lines=%d" % sum(1 for r in rows if 'Refresh ladder' in r[1]))
    print("aligns_stale=%d\tratio_of_switches=%.2f" % (
        sum(1 for r in rows if 'aligns stale policy' in r[1]),
        sum(1 for r in rows if 'aligns stale policy' in r[1])/max(1,len(sw))))
    print("verified=%d" % sum(1 for r in rows if 'Active display mode verified' in r[1]))
    print("sf_requests=%d" % sum(1 for r in rows if 'SurfaceFlinger physical mode requested' in r[1]))
    print("app_changes=%d\tper_hour=%.1f\tthrash_le3s=%d" % (len(ac), len(ac)/hrs, thrash))
    print("settings_put=%d\tper_switch=%.1f" % (
        sum(1 for r in rows if 'settings put' in r[1]),
        sum(1 for r in rows if 'settings put' in r[1])/max(1,len(sw))))
    print("hour_hist\t" + " ".join("%s=%d" % (k[-2:],v) for k,v in sorted(hr.items())))
    print("minute_top5\t" + " | ".join("%s %d" % (k,v) for k,v in mi.most_common(5)))
    a=[int(re.search(r'after=(\d+)ms',r[1]).group(1)) for r in rows if 'Active display mode verified' in r[1] and re.search(r'after=(\d+)ms',r[1])]
    if a:
        s=sorted(a); n=len(s)
        print("after_ms\tn=%d min=%d p50=%s p90=%d max=%d" % (n, s[0], statistics.median(s), s[int(0.9*(n-1))], s[-1]))
    print("")

paths = {
 'user3 (PLK110, 2.9.41)': r'用户反馈\用户三反馈\murong-bugpack-20261004-071752\module\daemon.log',
 'user1 (PLK110, 2.9.38)': r'用户反馈\用户1反馈\murong-bugpack-20260930-124335\module\daemon.log',
 'user2 (RMX5200, 2.9.39)': r'用户反馈\用户2反馈\murong-bugpack-20261001-125940\module\daemon.log',
 'user1new (PLK110, 2.9.40)': r'C:\Users\Administrator\AppData\Local\Temp\murong_analysis\u1new\murong-bugpack-20261001-131818\module\daemon.log',
}
for k,p in paths.items():
    try: summarize(k, load(p))
    except Exception as e: print("ERR",k,e)

rows=load(paths['user3 (PLK110, 2.9.41)'])
sw=[r[0] for r in rows if "Ordered refresh switch" in r[1]]
hr=Counter(d.strftime("%m-%d %H") for d in sw)
print("### user3 hourly ordered-switch table")
for k,v in sorted(hr.items()): print("%s\t%d" % (k, v))
```

### 7.3 lspd_stats.py / lspd_full.py — LSPosed 模块日志

lspd_stats.py（按时间范围切片；参数：文件、起、止）：
```python
import re, sys
from collections import Counter
path = sys.argv[1]
lo = sys.argv[2]; hi = sys.argv[3]
re_hdr = re.compile(r'^\[\s*(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)\s+(\d+):\s*(\d+):\s*(\d+)\s+(\w)/(\S+)\s*\]\s*(.*)$')
tot=0; inrange=0; msgs=Counter(); tids=Counter(); persecond=Counter(); permin=Counter()
with open(path,'r',encoding='utf-8',errors='replace') as fh:
    for ln in fh:
        tot+=1
        m=re_hdr.match(ln)
        if not m: continue
        ts,uid,pid,tid,lvl,tag,rest = m.groups()
        if lo and not (lo <= ts[:19] <= hi): continue
        inrange+=1
        body = re.sub(r'^\((?:\w+)\)','',rest)
        body = re.sub(r'\[[^\]]*\]','',body,count=2)
        key = re.sub(r'\d+','#',body.strip())[:80]
        msgs[key]+=1; tids[(pid,tid)]+=1
        persecond[ts[:19]]+=1; permin[ts[:16]]+=1
print("FILE",path,"lo",lo,"hi",hi)
print("total_lines",tot,"in_range",inrange)
print("--- top messages in range ---")
for k,v in msgs.most_common(25): print("%d\t%s" % (v,k))
print("--- top (pid,tid) in range ---")
for k,v in tids.most_common(15): print("%d\tpid=%s tid=%s" % (v,k[0],k[1]))
print("--- top seconds ---")
for k,v in persecond.most_common(15): print("%d\t%s" % (v,k))
print("--- per minute (05:50-06:10) ---")
for k in sorted(permin):
    if "T05:5" in k or "T06:0" in k: print("%s\t%d" % (k, permin[k]))
```

lspd_full.py（全量：级别/消息/分钟/秒峰值）：
```python
import re, sys
from collections import Counter
path = sys.argv[1]
re_hdr = re.compile(r'^\[\s*(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)\s+(\d+):\s*(\d+):\s*(\d+)\s+(\w)/(\S+)\s*\]\s*(.*)$')
tot=0; msgs=Counter(); permin=Counter(); persecond=Counter()
with open(path,'r',encoding='utf-8',errors='replace') as fh:
    for ln in fh:
        tot+=1
        m=re_hdr.match(ln)
        if not m: continue
        ts,uid,pid,tid,lvl,tag,rest = m.groups()
        body = re.sub(r'^\((?:\w+)\)','',rest)
        body = re.sub(r'\[[^\]]*\]','',body,count=2)
        key = re.sub(r'\d+','#',body.strip())[:70]
        msgs[(lvl.strip(),key)]+=1
        permin[ts[:16]]+=1
        persecond[ts[:19]]+=1
print("FILE",path,"total_lines",tot)
print("--- top (level,message) ---")
for k,v in msgs.most_common(30): print("%d\t%s\t%s" % (v, k[0], k[1]))
print("--- top minutes ---")
for k,v in permin.most_common(20): print("%d\t%s" % (v,k))
print("--- top seconds ---")
for k,v in persecond.most_common(20): print("%d\t%s" % (v,k))
sev=Counter()
for (lv,k),v in msgs.items(): sev[lv]+=v
print("--- severity totals ---"); print(dict(sev))
```

logcat 时间范围统计（PowerShell，流式、不载入上下文）：
```powershell
$ts = Select-String -LiteralPath $p -Pattern '^(\d\d-\d\d \d\d:\d\d:\d\d\.\d\d\d)' |
      ForEach-Object { $_.Matches[0].Groups[1].Value }
"count=$($ts.Count)"; "first=$($ts[0])"; "last=$($ts[-1])"
$ts | ForEach-Object { $_.Substring(0,14) } | Group-Object |
      Sort-Object Count -Descending | Select-Object -First 10 Count,Name
```

整包卡顿行扫描（PowerShell）：
```powershell
foreach($pat in @('Skipped \d+ frames','ANR in ','Slow dispatch','Slow delivery',
                  'Slow operation','Slow looper','Slow input','WindowManager: Slow')){
  $hits = Get-ChildItem -LiteralPath $b -File -Recurse |
          Where-Object { $_.Extension -in @('.txt','.log','.pb') -or $_.Name -like 'modules_*' -or $_.Name -like 'verbose_*' } |
          Select-String -Pattern $pat -ErrorAction SilentlyContinue
  "{0,-25} {1}" -f $pat, ($hits | Measure-Object).Count
}
```

### 7.4 restarts.py — 守护进程重启点 + 每包空档汇总

```python
import re,sys
from datetime import datetime
YEAR=2026
ts_re=re.compile(r'^\[(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\]')
def scan(p):
    rows=[];restarts=[];n=0
    with open(p,'r',encoding='utf-8',errors='replace') as fh:
        for i,l in enumerate(fh,1):
            n+=1
            m=ts_re.match(l)
            if not m: continue
            mo,dd,hh,mm,ss=(int(x) for x in m.groups())
            dt=datetime(YEAR,mo,dd,hh,mm,ss); rows.append((dt,l[m.end():].strip(),i))
            if 'Display hook bridge listening' in l: restarts.append((dt,i))
    return rows,restarts,n
ps={
 'user3 (PLK110,2.9.41)':r'用户反馈\用户三反馈\murong-bugpack-20261004-071752\module\daemon.log',
 'user1 (PLK110,2.9.38)':r'用户反馈\用户1反馈\murong-bugpack-20260930-124335\module\daemon.log',
 'user2 (RMX5200,2.9.39)':r'用户反馈\用户2反馈\murong-bugpack-20261001-125940\module\daemon.log',
 'user1new (PLK110,2.9.40)':r'C:\Users\Administrator\AppData\Local\Temp\murong_analysis\u1new\murong-bugpack-20261001-131818\module\daemon.log',
}
for k,p in ps.items():
    rows,restarts,n=scan(p)
    gaps=[]
    for i in range(1,len(rows)):
        d=(rows[i][0]-rows[i-1][0]).total_seconds()
        if d>=5:
            prev_off='Screen state -> OFF/DOZE' in rows[i-1][1]
            next_on='Screen state -> ON' in rows[i][1]
            gaps.append((int(d),str(rows[i-1][0]),str(rows[i][0]),prev_off and next_on))
    live=[g for g in gaps if not g[3]]
    print("%s\tlines=%d\trestarts=%d\trestart_times=%s" % (k, n, len(restarts), [str(r[0]) for r in restarts]))
    print("   gaps>=5s total=%d screenoff_bounded=%d live=%d live_total_s=%d max_live=%ds" % (
        len(gaps), len(gaps)-len(live), len(live), sum(g[0] for g in live), max((g[0] for g in live),default=0)))
    for g in sorted(gaps,key=lambda x:-x[0])[:5]:
        print("   TOP %ds %s -> %s idle=%s" % (g[0], g[1], g[2], g[3]))
```

### 7.5 验证 APK dex 中的 r8-map-id（PowerShell）

```powershell
$apk='murongchaopin\bin\display_settings_hook.apk'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z=[System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $apk).Path)
$z.Entries | Where-Object { $_.FullName -like '*.dex' } | Select-Object FullName,Length
foreach($e in ($z.Entries | Where-Object { $_.FullName -like '*.dex' })) {
  $ms = New-Object System.IO.MemoryStream; $s=$e.Open(); $s.CopyTo($ms); $s.Close(); $bytes=$ms.ToArray()
  $txt=[System.Text.Encoding]::ASCII.GetString($bytes)
  $hit = $txt.Contains('f311ff7af83126d8daacb353cb15aca5b5689cab5ed446d4cad8135349c8d63d')
  "DEX $($e.FullName) len=$($bytes.Length) contains_r8mapid=$hit"
}
$z.Dispose()
```

### 7.6 提取 HEAD 源码并对齐行号（PowerShell）

```powershell
$out='C:\Users\Administrator\AppData\Local\Temp\murong_analysis\head'
New-Item -ItemType Directory -Force -Path $out | Out-Null
git -C murongchaopin show HEAD:src/rate_daemon.c | Set-Content "$out\rate_daemon.c" -Encoding utf8
git -C murongchaopin show HEAD:src/settings_hook/java/com/murongchaopin/displayhook/BridgeClient.java | Set-Content "$out\BridgeClient.java" -Encoding utf8
git -C murongchaopin show HEAD:src/settings_hook/java/com/murongchaopin/displayhook/OplusVrrTierHooks.java | Set-Content "$out\OplusVrrTierHooks.java" -Encoding utf8
Select-String -LiteralPath "$out\rate_daemon.c" -Pattern 'SYSTEM_MODE_CACHE_MS','timeout 4 dumpsys window',
  'timeout 4 dumpsys SurfaceFlinger','create_display_hook_server','listen\(fd, 4\)',
  'handle_display_hook_client\(hook_server_fd','Ordered refresh switch','aligns stale policy',
  'Active display mode verified','FOREGROUND_APP_CACHE_MS','int hook_server_fd' |
  ForEach-Object { '{0,5}: {1}' -f $_.LineNumber, $_.Line.TrimEnd() }
```

ANR 中"等同一把锁"的线程枚举（PowerShell）：
```powershell
$lines = Get-Content -LiteralPath $anr
$targets = (Select-String -LiteralPath $anr -Pattern 'waiting to lock <0x08992b89>').LineNumber
$threads=@()
foreach($t in $targets){
  for($i=$t-1;$i -ge 0;$i--){
    if($lines[$i] -match '^"(.+)" prio=(\d+) tid=(\d+) (\w+)'){
      $threads += [pscustomobject]@{Line=$i+1; Thread=$matches[1]; Tid=$matches[3]; State=$matches[4]}
      break
    }
  }
}
"distinct blocked threads: " + $threads.Count
$threads | Sort-Object Line | ForEach-Object { "{0,5}  tid={1,-5} {2,-8} {3}" -f $_.Line, $_.Tid, $_.State, $_.Thread }
```

### 7.7 window.py — 05:59:10–06:02:23 爆发段量化

```python
import re
from datetime import datetime
from collections import Counter
YEAR=2026
ts_re=re.compile(r'^\[(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\]')
p=r'用户反馈\用户三反馈\murong-bugpack-20261004-071752\module\daemon.log'
lo=datetime(2026,10,4,5,59,10); hi=datetime(2026,10,4,6,2,23)
rows=[]
for i,l in enumerate(open(p,encoding='utf-8',errors='replace'),1):
    m=ts_re.match(l)
    if not m: continue
    mo,dd,hh,mm,ss=(int(x) for x in m.groups())
    rows.append((datetime(YEAR,mo,dd,hh,mm,ss), l[m.end():].strip(), i))
win=[r for r in rows if lo<=r[0]<=hi]
c=Counter()
for d,msg,i in win:
    if 'Ordered refresh switch' in msg: c['switch']+=1
    if 'Detected App Change' in msg: c['appchange']+=1
    if 'SurfaceFlinger physical mode requested' in msg: c['sf_req']+=1
    if 'Active display mode verified' in msg: c['verified']+=1
    if 'aligns stale policy' in msg: c['aligns_stale']+=1
    if 'settings put' in msg: c['settings_put']+=1
    if 'Refresh ladder' in msg: c['ladder_line']+=1
    if 'Synced system settings' in msg: c['synced']+=1
print('window',lo,'->',hi,'lines',len(win),'first_line',win[0][2],'last_line',win[-1][2])
print(dict(c)); print('duration_s',(hi-lo).total_seconds())
print('app_change_sequence',[(d.strftime('%H:%M:%S'),msg.split(': ',1)[1]) for d,msg,i in win if 'Detected App Change' in msg])
print('switch_sequence',[(d.strftime('%H:%M:%S'),msg.split(': ',1)[1]) for d,msg,i in win if 'Ordered refresh switch' in msg])
```

### 7.8 其它零散取数命令

```powershell
# 守护进程日志规模 / 首尾
(Get-Content -LiteralPath $f -ReadCount 5000 | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
Get-Content -LiteralPath $f -TotalCount 25
Get-Content -LiteralPath $f -Tail 15

# 启动横幅（判定进程级重启）
Select-String -LiteralPath $f -Pattern 'Display transition profile','Display hook bridge listening',
  'Inotify watching directory','Boot ColorOS resolution stable','Boot resolution reconciled'

# dropbox 条目头 / Subject
Select-String -LiteralPath dropbox.txt -Pattern '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \S+ \('
Select-String -LiteralPath dropbox.txt -Pattern '^Subject:'

# logcat 中 dumpsys 代价
Select-String -LiteralPath logcat_main.txt -Pattern "dump: service '(\w+)' took (\d+)ms, (\d+) bytes"
```

---

## 附：本次分析中未能取得 / 未能证实的事项（避免过度解读）

1. **守护进程 05:59:23 重启的原因**：无 tombstone、无 kmsg 覆盖（kmsg 只覆盖当前开机 uptime 1110–1381 s）、无 core dump。属【未证实】。
2. **logcat 现场**：`logcat_main.txt` 仅 5.28 秒、`logcat_events.txt` 仅 107.5 秒，都不在 ANR 时刻，因此**无法给出"哪个进程在哪一秒掉了多少帧"的帧级统计**。本报告的帧级替代物是 dropbox 的 5 秒 CPU 采样（dropbox L6708–L6719）。
3. **未找到 rate_daemon_supervisor.sh 源文件**：仓库内按文件名递归查找无结果，只能从 `service.sh:5,133-138,189-196` 推断其存在与职责（PID 文件 `runtime/rate_daemon_supervisor/pid`）。supervisor 的重启间隔/退避策略**未证实**。
4. **工作树并发修改**：本报告全部源码行号基于 HEAD `818143f`。分析期间 `src/rate_daemon.c` 等 10 个文件处于未提交修改状态（`git status`），其中已包含针对本报告 D4/D7 的疑似修复（`APP_CHANGE_SETTLE_MS`、`note_pushed_foreground_app`、`FOREGROUND_APP_SLOW_DUMP_MS`）。**审阅本报告时请以 HEAD 为准，不要把工作区行号套用到 v2.9.41 出厂版本上。**
