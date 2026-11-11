# 慕容显示增强 v2.9.50

本版修复 **ColorOS 系统 OTA 后屏幕 DPI / 分辨率档位一直闪烁** 的问题，并补上了"升级系统后第一次开机自动适配"的缺口。

## 一、现象

- 系统从 `RMX5200_17.0.0.106` 升级到 `RMX5200_17.0.1.201(CN01)`（内核由
  `6.12.69-android16-11-gf198a460cdff` 变为 `6.12.69-android16-11-g3cce8c80f983`）后，
  屏幕在 1440x3136 与 1080x2352 两个分辨率组之间来回跳，表现为 UI 尺寸/DPI 连续闪烁。
- 模块日志：`config/surfaceflinger_ltps_vote_patch/state.txt` = `rejected:source_contract_12`，
  `/proc/1/mountinfo` 中 `/system/bin/surfaceflinger` 没有 bind mount，即投票过滤补丁没有挂上。

## 二、根因

1. OTA 替换了 `/system/bin/surfaceflinger`（新 sha256 `89a6e940…9051`），模块需要原地重定位两处指令：
   `-animation` 字符串 insert 站点和 AP-scale 守卫分支。脚本本身已经有**按指令签名动态定位**的能力
   （`detect_dynamic_sites()`），理论上不需要重装模块。
2. 但升级后第一次开机时，状态目录里还保留着上一版系统的缓存：`contract=table` +
   `contract-source=<旧 build sha>`。`select_build_sites()` 先命中这个旧缓存并直接返回旧偏移，
   没有用当前 SurfaceFlinger 的字节重新验证；随后 `patch_site_table()` 验证失败，返回
   `rejected:source_contract_12`。
3. 补丁没挂上时，厂商 `OplusRefreshRateDirector` 的 AP-scale 映射仍把 144/155/170 的投票解析到
   FHD 组（mode 11, 1080x2352@123），守护进程再把 1440p 拉回来，两个分辨率组来回翻转，
   于是 DPI/UI 尺寸持续闪烁。直到第二次重启、`contract-source` 被失败流程覆盖成新 sha 后，
   动态定位才真正执行——这解释了"为什么更新完系统就这样，而且重启一次好像又好了"。

## 三、修复

- `scripts/surfaceflinger_ltps_vote_patch.sh`：`select_build_sites()` 在复用
  `contract=table` 缓存前，必须先用 `verify_table_original()` / `verify_table_patched()`
  验证缓存偏移确实描述当前文件；不匹配就清空缓存并继续走指令签名动态定位。
  这样 OTA 后**第一次开机**就能自行重定位，不再需要手动重装模块或二次重启。
- 回归测试 `tests/check_surfaceflinger_ltps_vote_patch.sh`：新增"陈旧 table 缓存 + 新 build"
  用例；真实 SurfaceFlinger 回归用例不再硬编码分支距离，改为按原分支目标推导期望编码。
- 本版仅改脚本与测试，Hook / 守护进程 / 内核模块均无变化。

> 配套付费包 **1.2.8** 同步修复 Scene 性能页“全局刷新率乱跳、改完自动跳回上一档”的问题（Scene 专属 Hook 在付费包内交付）。

## 四、真机验证

- 升级系统后首次开机：`state=active:boot_verified`，`pid1_mount=present`，
  `/system/bin/surfaceflinger` sha256 = 补丁文件 sha256（`e49cf872…402e`），
  动态站点记录 `89a6e940…:3061260:67580d94:3658524:61020054:13000014`。
- 刷新率 120 / 144 / 155 / 170 来回切换，显示始终保持在 1440x3136 组（mode 1/5/7），
  守护进程日志不再出现 `mode=11 width=1080` 或 `Resolution change … -> …` 的来回跳。
- 桌面、设置、Scene 等应用切换期间不再出现 DPI 闪动。

> 说明：ColorOS OTA 会替换 SurfaceFlinger/内核等厂商二进制。模块对内核模块走 CRC 契约自适应、
> 对 SurfaceFlinger 走指令签名重定位，同类改动通常不再需要更新模块；只有厂商真正改写那两段
> 代码结构时才需要随模块更新适配。
