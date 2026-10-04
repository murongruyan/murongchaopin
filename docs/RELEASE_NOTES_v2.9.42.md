# 慕容显示增强 v2.9.42

本版修的是 v2.9.40 没有修完的那个“还是卡”：**手势导航划了没反应、切后台卡、刷抖音和搜索页卡**。
这一版不是继续调参数，而是在用户三的反馈包里把真正的因果链找出来了。

## 一、根因：模块自己的 Hook 把窗口管理器的全局锁占住了

用户三（PLK110 / ColorOS 17 / 2.9.41）的反馈包里有一份 system_server 的 ANR：

```
Subject: Input dispatching timed out (PointerEventDispatcher0 is not responding.
         Waited 5000ms for MotionEvent(... source=TOUCHSCREEN ... action=MOVE ...))
```

- 系统手势监听线程 `oplus.ui` 停在
  `DisplayPolicy$1.onSwipeFromTop → SystemGesturesPointerEventListener.onPointerEvent`，
  它要的是 `WindowManagerGlobalLock`；
- 持有这把锁的线程 `binder:5750_5` 的栈里，
  从 `WindowManagerService.relayoutWindow` 一路走到 `DisplayManagerService.setDisplayPropertiesInternal`，
  最后落在**本模块 Hook APK 的代码**上：栈帧的 R8 标记
  `r8-map-id-f311ff7af83126d8daacb353cb15aca5b5689cab5ed446d4cad8135349c8d63d`
  与 `bin/display_settings_hook.apk` 内 classes.dex 中的字符串完全一致，
  而对应的混淆映射里 `BridgeClient -> g`、`request(String,int) -> c`；
  下一帧就是 `java.net.Socket.connect`。

也就是说：**Hook 在持有 `WindowManagerGlobalLock` 的框架线程上，同步发起了一次到守护进程的
loopback socket 连接**。守护进程当时正卡在 `dumpsys` 里（同一份 `daemon.log` 在
05:59:38（亮屏）到 05:59:52（切到桌面）之间有 14 秒没有任何输出），根本没法 accept，
于是这次连接只能等到超时才返回；而只要它不返回，窗口管理器的全局锁就一直被握着，
手势监听线程一个触摸事件也收不到 —— 5000ms 后系统判定“输入分发超时”，
用户看到的就是“划了好几次都没反应”。

## 二、本版的修复

### 1. Hook 侧：框架线程永远不再等守护进程

- `BridgeClient` 新增后台刷新器（单线程）：`refreshGlobalRateAsync()` /
  `refreshLtpoRouteAsync()`。`getPreferredFrameRate`、`addFRTCFrameRate`、
  `setAppRequest`、模式解析等 Hook 回调只读一个 volatile 快照并立即返回，
  socket 往返一律丢给后台线程。
- 失败退避 5 秒：守护进程不可用或超时时，不再“每次框架回调都重连一次”，
  而是保留上一次已知值继续服务。
- `BridgeClient.ltpoRoute()` 改为非阻塞：过期只投递异步刷新，并按
  `LTPO_HOLD_MS` 继续沿用最近一次成功路由（`murong.ltpo.route` 系统属性镜像仍然是首选，
  读属性不会阻塞）。

### 2. 付费 Hook 同步同一套修复

授权设备上同时装着免费 Hook（`com.murongchaopin.displayhook`）和付费 Hook
（`com.murongchaopin.displayhook.premium`）两个包，两者都会注入 system_server。
付费 Hook 是同一套代码的另一份副本，同样在框架锁内同步等守护进程。本版把非阻塞改造
完整移植到付费 Hook 源码，并重新构建、签名的付费产物；回归测试现在同时覆盖两份副本。

### 3. 守护进程：不再周期性 dump 窗口管理器

`dumpsys window` 每一次都会在 system_server 内部持有 `WindowManagerGlobalLock`，
而系统手势监听线程需要的正是这把锁。

- 前台应用改由 system_server 的 Hook 通过新的桥接命令 `FRONTAPP <pkg>` 主动推送
  （Hook 本来就在 `handleFrontAppChange` 上收到厂商的前台回调），守护进程不再轮询；
- 没有 Hook 可用的设备保留 `dumpsys` 兜底，但会按实测耗时自动退避：
  单次 dump ≥250ms 就把间隔从 2 秒拉到 6 秒；
- 息屏/待机时完全不再查询（前台策略此时不会生效）。

### 4. 刷新率阶梯：成功路径的事务数减半，校验采样不再刷屏

- 每一步**先请求目标档位**，只有校验失败时才回退到“先对齐当前档位再请求”的旧路径。
  成功路径由此从 2 次 SurfaceFlinger 事务降到 1 次（每次都要 fork 一个 shell 并占用
  SurfaceFlinger 锁）。
- 校验用的 `dumpsys SurfaceFlinger` 采样：从“最多十几次、每 100-150ms 一次”
  收敛为**最多 4 次、间隔 350ms、总时长仍受 1500ms 上限约束**，连续 2 次一致即判定成功；
  稳态缓存 400ms → 700ms。校验必须读新鲜值，否则会自己“确认”自己，所以这里收敛的是采样次数而不是缓存。
- 这两项恰好作用在“切后台/抖音滑动时” —— 那段动画期间每减少一次 SurfaceFlinger 争用，
  用户就少一次掉帧。

### 5. 切换前台后先等前台稳定，再做阶梯

手势导航和最近任务会把一次切换拆成好几次前台变化（用户三日志里 05:59:10–05:59:28
连续来回切了 4 次，每次都跑完整阶梯）。本版加入 600ms 稳定窗口：
前台稳定之前不动刷新率阶梯，避免在切换动画里和 SurfaceFlinger 抢锁。

### 6. 版本号同步

守护进程内置版本统一到 2.9.42（付费侧此前还停在 2.9.40）。

## 三、验证

- 现场证据链（ANR 栈、R8 map-id 与 APK 内字符串比对、`daemon.log` 空档统计）见
  `docs/JANK_EVIDENCE_20261005.md`。
- 现场时间线由 dropbox 的 SystemUptimeMs 换算钉死：ANR 的 5 秒窗是 05:59:24.35–05:59:29.35，
  而 `daemon.log` 显示守护进程在这个窗口里正好各做了一次完整的 5→7 / 7→5 阶梯切换，
  窗口之后是 05:59:38→05:59:52 的 14 秒零输出 —— 双边正好互相卡住。
- 守护进程改动经 NDK 重新编译（`bin/rate_daemon` 与源码指纹同步更新），付费守护进程
  源码同步同一套改动；免费与付费 Hook APK 均从当前源码重新构建并通过官方签名校验
  （证书 SHA-256 `7776d8cf…e90e`）。
- 新增两个回归测试：`tests/check_daemon_jank_hotpath.sh`（守护进程热路径契约）与
  `tests/check_hook_nonblocking_bridge.sh`（Hook 不得在框架线程上做 socket 往返，
  含付费副本）；仓库既有 `tests/check_*.sh` 结果与改动前逐项对比，无新增失败。

## 四、真机验证（RMX5200 / ColorOS 17）

在连着 adb 的 RMX5200 上实际部署并测量，不是纸面推演：

| 指标 | 修复前（2.9.40） | 修复后（2.9.42） |
|---|---|---|
| 守护进程的 `dumpsys window` | 每 2 秒一次 | **0 次**（962 次采样、40 秒空闲 + 一次真实切换） |
| 前台应用来源 | 轮询窗口管理器 | Hook 推送（日志：`Foreground app pushed by the display hook: <pkg>`） |
| SurfaceFlinger 事务 / 切换 | 3.75（含 25 次冗余对齐） | 3.14（冗余对齐 **0**，每步 1 次） |
| 模式校验采样 | 最多十几次 | 有界，日志中 `samples=2/3` |
| 桥接往返延迟 | connect p50 0ms / 往返 p50 1-2ms、p99 90-98ms | 同量级（瓶颈从来不是守护进程本身，而是 Hook 在框架锁里等它） |

Hook 侧确认：重启后 system_server 加载了 20 个 hook，其中 `appRequest=1`（ANR 路径）
与 `front=1`（前台推送）都在。

**设备测试还抓出一个缺口**：最初的推送实现只把推送值当作 15 秒新鲜值，过期后守护进程会
退回每 2 秒轮询——等于稳态下修复失效。现在推送会同时写入缓存，之后最多每 60 秒做一次
慢速对账；一旦对账结果与推送不一致（说明 Hook 停止上报）就自动恢复轮询。复测结果即上表
的 0 次。

## 五、说明

- 本版仍然没有“凭空提高刷新率”这类玄学改动：所有改动都只是让模块**少占系统锁、
  少做无用事务**。手势导航的流畅度最终由系统自己的合成与输入决定，模块能做的就是别再挡路。
- 如果你的设备上仍然出现“划了没反应”，请按 `scripts/collect_bugpack.sh` 抓包，
  ANR 里 `WindowManagerGlobalLock` 的持有者栈是最直接的判据。
