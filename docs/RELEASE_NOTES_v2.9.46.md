# 慕容显示增强 v2.9.46

本版修的是**一个具体的坏毛病**：在 RMX5200 上把分辨率切到 2K 之后，切刷新率会整屏闪一下，
跨组瞬间整机 UI 还会缩放跳变（反馈里的"切换刷新率 DPI 也跟着变"）；1080p 下没有这个问题。

## 一、根因：厂商 SurfaceFlinger 的投票映射表把动画投票指到了 FHD 档

拆开看是三层：

1. **原厂**：ColorOS 17（2026-10-05 OTA）里 `OplusRefreshRateDirector` 维护的"帧率 → mode"
   映射表把 `<prefix>-animation` 投票解析成 `1080x2352` 的 mode（id 10/11），
   而框架下发的 `DisplayModeSpecs` 带 `allowGroupSwitching=true`，所以 SF 真的会去切**分辨率组**。
2. **模块的兜底补丁没挂上**：设备上一直是 `rejected:source_contract_12`。
   真正的原因不是站点表缺条目，而是 `select_build_sites()` 无条件相信上一次记录的 `legacy` 契约，
   而 `record_contract()` 每次都把 `contract-source` 改写成**当前**哈希——"旧 OTA 的 legacy 判决"
   被绑到新二进制上，152 字节块校验永远失败，**按签名自动重定位的逻辑永远走不到**。
3. **放大器**：跨组时密度 override 仍是 560（2K 档），逻辑尺寸从 411x896 变 308x672，
   所以除了闪，还会看到 UI 缩放跳变。

实测（2K 切 120→165，1 秒内）：

| | 面板物理切换 | 跨组 | 显示断连重连 | Topology 变更 | CHANGE transition |
|---|---|---|---|---|---|
| 修复前 | 11 | **9** | 9 | 9 | 10 |
| 修复后 | 3–5（全部同组 144/155/165） | **0** | **0** | **0** | **0** |

日志佐证：修复前 `updateBestFrameRate [version-3-window-animation_4, {fps=90, modePtr={id=10 …}}]`
把面板拖到 FHD；修复后 `window-animation` 投票与 `id=10/11` 映射从日志里完全消失。

## 二、改了什么

- **站点表新增本 OTA 的两个站点**（sha256 `c3b8273f…`）：
  `0x301da0` 的 `std::string::insert`（构造 `<prefix>-animation` 名字）→ NOP；
  `0x37bc24` 的 AP-scale 守卫分支 → 无条件跳转，不再查那张残留表。
- **陈旧的 `legacy` 记录不再被无条件相信**：先重新校验字节，不符就回落到签名重定位，
  以后换 OTA 也能自愈。
- **`detect_dynamic_sites()` 去掉对 `xxd` 的硬依赖**（`od -An -v -tx1` 兜底），
  否则没有 xxd 的 ROM 上未知 build 一律 fail-closed。
- **诊断包新增帧/卡顿证据**：`display/frame_pacing.txt`（SF 漏帧计数、activeMode、
  `mDisplayModeSpecs`、三个刷新率设置）与 `display/jank_probe.txt`（前台包名 +
  `dumpsys gfxinfo` 的 Janky frames/百分位 + framestats + `SurfaceFlinger --latency`）。
  以前"浏览某 App 偶尔小卡顿"这类反馈只有 3~4 秒 logcat，判不了。

## 三、验证

- 真机（RMX5200 / ColorOS 17）：2K 切刷新率不再跨组；分辨率切换不受影响——
  2K↔1080p 各 1 次正常重连，密度 560↔420 自动跟随。
- 补丁在线生效并已通过引导校验：`state=active:boot_verified`，重启后自动重放。
- 测试套件全绿：`tests/check_surfaceflinger_ltps_vote_patch.sh`（含新增的"陈旧 legacy 记录 +
  签名重定位"回归、新 OTA 站点断言、平台门限固定为 16），并用真实 7.3MB SurfaceFlinger
  跑通了 pinned-hash 与未知 hash 两条路径。

## 四、说明

- 如果你在设备上装了会改 `ro.serialno` 的工具，1.2.1 起已做身份钉住，不会掉授权。
- 2K 会话下密度仍由模块按"实际生效的几何"镜像，跨组瞬态不再改写它。
