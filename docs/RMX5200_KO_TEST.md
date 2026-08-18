# RMX5200 DRM-KO 原型测试记录

设备：RMX5200（真我 GT8 Pro）

内核：`6.12.23-android16-5-gb2a876903b49-ab14541642-4k`

## 目标

按 `process_dts.c` 的 RMX5200 WQHD 逻辑，在运行时追加新的
`dsi_display_mode` 和 DRM mode，不替换原有 8 条 mode：

- WQHD `1440x3136@123`
- WQHD `1440x3136@150/155/160/165/170/175/180`
- `mode_specs` 可追加 WebUI 自定义刷新率

KO 不写 DTBO 分区；`probe_only=1` 只做布局探测。

## 构建检查

模块：`bin/rmx5200_drm_modes.ko`（源码：`src/ko/rmx5200_display_modes.c`）

vermagic：

```text
6.12.23-android16-5-gb2a876903b49-ab14541642-4k SMP preempt mod_unload modversions aarch64
```

RMX5200 运行时布局探测结果：

```text
mode_count=8
mode_stride=0xc8
source_mode_index=7
display_panel_offset=0x108
panel_count_offset=0x5a0
mode_refresh_offset=0x2c
mode_clock_offset=0x30
mode_pixel_offset=0x98
mode_index_offset=0xb0
mode_priv_offset=0xb8
priv_clock_offset=0x1dd0
priv_transfer_offset=0x1db8
source_clock=1113600000
probe_bound_clock_180_from_fhd_144=1392000000
```

最后一项只用于探测器的 FHD 144 模板边界检查，不是 WQHD 180 的实际时钟。

## `probe_only` 闭环

装载：`insmod ... probe_only=1` 返回 0。

内核日志：

```text
display=... count=8 stride=0xc8 source=7 panel=0x108 count_off=0x5a0
probe_only layout accepted, no memory changed
```

卸载返回 0。活跃 panel 的 860 个 live-DT 属性文件在装载前后哈希一致，
SurfaceFlinger 仍为原始 1080p `60/90/120/144Hz`。模块镜像中的原厂备份哈希为：

```text
0de4f26051248e1589e6813798b0c22ad58e17333ae5f20b04b94e1a70f60d8e
```

2026-08-09 在当前 RMX5200 `_a` 原厂启动状态下重新执行了同一条
`probe_only=1` 侧载链。使用 `mode_specs=1440x3136@123;1440x3136@150` 和共享
AE084 profile，实机返回：

```text
insmod_rc=0
adfr_profile_valid=Y
adfr_command_injection_supported=N
applied=N
cache_applied=N
failure_code=0
mode_count_before=8
probe_only layout accepted, no memory changed
rmmod_rc=0
```

这次探针没有追加 mode、没有改 live mode 数组、没有发送 DSI；它只重新证明
KO 的 profile gate 和 Qualcomm runtime layout 可探测。真实命令注入仍然没有
实现，必须等待 AE084 DVT02 的独立 ADFR command table。

## 单档运行时追加

使用原厂 DTBO 启动后加载：

```text
insmod rmx5200_drm_modes.ko mode_specs=1440x3136@150
```

实测参数：

```text
mode_count_before=8
mode_count_after=9
injected_mode_count=1
connector_mode_count_before=8
connector_mode_count_after=9
connector_hotplug_sent=1
failure_code=0
```

`/sys/class/drm/card0-DSI-1/modes` 出现 `1440x3136x150cmd`。晚加载时已经运行的
composer 不会主动重建自己的 mode cache；因此用户可用路径必须在 `post-fs-data`
加载，早于 composer。冷启动实测在约 5 秒完成加载，SurfaceFlinger 首次枚举包含
150Hz，`cmd display get-user-preferred-display-mode` 能识别该模式，active mode 也
能够切换到 150Hz。厂商显示策略会在空闲时切换到低刷 timing，这不是 mode
枚举失败。

冷启动期间设备保持运行，ADB 未断开；恢复 `dts_backend=dtbo` 并重启后，KO 未加载、
系统恢复原厂 8 条 mode。两次哈希始终为：

```text
0de4f26051248e1589e6813798b0c22ad58e17333ae5f20b04b94e1a70f60d8e
```

## 完整追加与原厂 timing 保真

冷启动加载的基础追加 KO：

```text
failure_code=0
applied=Y
cache_applied=Y
mode_count_before=8
mode_count_after=16
injected_mode_count=8
```

追加档位的 WQHD 私有 timing 已同步更新 `clk_rate_hz` 和
`mdp_transfer_time_us`：

| 档位 | `clk_rate_hz` | `mdp_transfer_time_us` |
| --- | ---: | ---: |
| 123 | 1488300000 | 6634 |
| 150 | 1512500000 | 6528 |
| 155 | 1562916666 | 6317 |
| 160 | 1613333333 | 6120 |
| 165 | 1663750000 | 5934 |
| 170 | 1714166666 | 5760 |
| 175 | 1764583333 | 5595 |
| 180 | 1815000000 | 5440 |

当前实现为每个新增 mode 深拷贝独立的 `u32[14]`，即 56 字节
`phy_timing_val`，不再让新增 mode 与原厂对象共享该数组。默认
`phy_profile=stock` 只做深拷贝；实验值 `v72_vendor_delta` 对八个新增档
`123/150/155/160/165/170/175/180` 分别应用 Qualcomm v7.2 计算结果相对
厂商 144Hz 基线的增量。完整目标值如下：

| 档位 | 实验 PHY timing（十六进制） |
| --- | --- |
| 123 | `00 2f 0d 0d 1e 1b 0d 0d 0c 02 04 00 26 11` |
| 150 | `00 30 0d 0d 1e 1b 0d 0d 0c 02 04 00 26 11` |
| 155 | `00 32 0d 0d 1f 1c 0d 0e 0c 02 04 00 2a 12` |
| 160 | `00 33 0e 0e 20 1d 0d 0e 0d 02 04 00 2a 11` |
| 165 | `00 35 0e 0e 20 1d 0e 0e 0d 02 04 00 2a 11` |
| 170 | `00 36 0f 0e 21 1e 0e 0f 0d 02 04 00 2f 13` |
| 175 | `00 38 0f 0e 22 1e 0f 0f 0e 02 04 00 2f 13` |
| 180 | `00 3a 0f 0e 22 1f 0f 10 0e 02 04 00 2f 13` |

模块只在私有对象偏移、长度、厂商 144Hz 基准和精确目标时钟全部
匹配时才应用；任一条件不符都会在写入 live mode 数组前失败关闭。

KO 对追加前的 8 条原厂 `dsi_display_mode` 做逐字节保真校验。RMX5200
实机读取到的原厂 WQHD timing 为：

```text
60:  transfer=6800 clock=1113600000
90:  transfer=9000 clock=1113600000
120: transfer=6800 clock=1452000000
144: transfer=6800 clock=1452000000
```

旧原型曾用 144 timing 替换原厂 60/90，导致 120/123/144/150/155
空闲时错误落在约 72Hz，并使 165/170 的异常低刷出现花屏；这一逻辑已经删除。

2026-08-08 用 RMX5200 设备上的 DTS 拆包目录复制到临时目录运行新版
`bin/process_dts`，没有写入 DTBO 或模块工作目录。三组 WQHD 60Hz、三组 WQHD
90Hz、三组 WQHD 120/144Hz，以及 FHD 60Hz 节点在处理前后逐块 SHA-256 一致；
因此新版只会保留厂商低刷 timing，不再用高刷模板覆盖它们。

## RMX5200 物理屏实测

下表是用户通过屏幕调试层观察的物理 LTPS 结果，不以 SurfaceFlinger 的逻辑
mode 代替物理读数：

| 目标档位 | 高档表现 | 空闲 LTPS | 低刷表现 |
| --- | --- | --- | --- |
| 120 | 不花 | 60 | 不花 |
| 123 | 不花 | 60 | 不花 |
| 144 | 不花 | 60 | 不花 |
| 150 | 不花 | 60 | 不花 |
| 155 | 不花 | 60 | 不花 |
| 160 | 不花 | 52-60 | 不花 |
| 165 | 不花 | 51-52 | 不花 |
| 170 | 不花 | 53 | 不花 |
| 175 | 少量细线，仍判定为轻微花屏 | 48-50 | 不花 |
| 180 | 严重花屏，完全不可用 | 37-38 | 不花 |

结论：在各档独立 link 的既有基线下，当前 RMX5200 样机的实测稳定上限是 170Hz。175Hz 已进入面板/链路
边缘，180Hz 虽能被 DRM 枚举和切换，但不能视为可用档位。单独同步
`mdp_transfer_time_us` 不能修复高档链路花屏。

175Hz 的“少量细线”仍属于轻微花屏，不能记为通过；它不是稳定无花屏，只是比 180Hz 的整屏花屏轻。

## 刷新率守护进程与分辨率事务

RMX5200 的 Qualcomm Android 16 `dumpsys SurfaceFlinger` 使用
`activeMode={id=..., hwcId=...}` 报告当前活动 HWC mode，不能只查旧版的
`activeConfig=`。守护进程现在按 `activeMode`、`mDisplayModePtr`、旧版
`activeConfig` 的顺序读取实际状态；不会把 `dumpsys display` 的 framework
`mActiveModeId` 当成 HWC ID。首次启动和息屏亮屏重放不再依赖过期的目标缓存。

刷新率切换改为单次 HWC 事务，不再逐档经过中间刷新率，减少厂商 LTPS/ADFR 策略与守护进程互相抢写的窗口。
跨 2K/1080p 时，事务会先保存 `wm density` 和 `wm size` 覆盖，调用
`cmd display set-user-preferred-display-mode` 对齐 framework 分辨率组，等待 HWC 稳定后恢复覆盖；普通
刷新率切换不会执行 `wm density`/`wm size`。

2026-08-08 实机闭环：

- 1440x3136@160 (mode 11) -> @170 (mode 13)：活动 mode 正确变化，密度 560、尺寸覆盖保持不变。
- 1440x3136@170 (mode 13) -> 1080x2352 组 (请求 mode 4/@144) -> 1440x3136@170：两次跨分辨率事务完成，密度仍为 560，尺寸恢复为对应物理分辨率。等待 3 秒后的 FHD active mode 被厂商策略改为 160Hz，因此这次测试只证明分辨率和密度闭环，不把 FHD 144Hz 记为持续锁定成功。
- 设备空闲时出现的 60Hz/低 LTPS 是厂商 ADFR 的空闲策略；不能用 SurfaceFlinger 的逻辑目标 mode 代替屏幕调试层的物理刷新率结论。

复核 Qualcomm v7.2 计算器后发现，既有 175/180 表的 clock-lane trail 值误写为
`0x0f`；相对厂商 144Hz 基线应用官方增量后应为 `0x0e`。`0.11` 只修正这两个
字节，保持 175/180 的真实独立 link、transfer time 和其余 PHY 值不变。修正后复测：
175Hz 仍有少量细线，不能标记为“无花屏”；180Hz 仍为花屏、不可用。

## 已否定的 link + blanking 补偿实验

`0.9-rmx5200-porch-comp` 的方向错误：175 使用 170 link、180 使用 175 link，
即使缩短 HFP/VFP，物理调试层仍分别只有 170Hz 和 175Hz。该 profile 已从源码、
启动脚本和测试中删除，不能作为高刷成功结果。

随后用所有新增 WQHD 档统一使用真正的 180 link、180 档 PHY timing 和
`mdp_transfer_time_us=5440`，低档同时增加 HFP/VFP，使名义总周期按
`180 / target_refresh` 放大：

| 目标档位 | HFP | VFP | `clk_rate_hz` | 预测总周期刷新率 |
| --- | ---: | ---: | ---: | ---: |
| 123 | 325 | 759 | 1815000000 | 122.987 |
| 150 | 157 | 387 | 1815000000 | 149.997 |
| 155 | 130 | 331 | 1815000000 | 154.990 |
| 160 | 105 | 276 | 1815000000 | 159.986 |
| 165 | 82 | 221 | 1815000000 | 165.012 |
| 170 | 59 | 171 | 1815000000 | 170.024 |
| 175 | 37 | 124 | 1815000000 | 174.990 |
| 180 | 16 | 78 | 1815000000 | 180.000 |

2026-08-08 冷启动证明 KO 确实写入了实验参数：

```text
KO version=0.10-rmx5200-uniform-180-link
SHA256=2439ea945a43fb224895bacb85a6e6d2568364c6ca59e2ab48c136b06ee573d5
failure_code=0
applied=Y
cache_applied=Y
mode_count_before=8
mode_count_after=16
uniform_link_applied=Y
uniform_link_mode_count=8
DTBO SHA256=0de4f26051248e1589e6813798b0c22ad58e17333ae5f20b04b94e1a70f60d8e
```

驱动日志确认 123、150、155、160、165、170、175、180 八档读取到表中统一 link
和对应 porch，但物理屏幕调试层的最终结果为：

| 名义档位 | 物理最高刷新率 | 屏幕表现 |
| --- | ---: | --- |
| 123 | 120 | 中等花屏 |
| 150/155/160/165/170/175/180 | 144 | 全部中等花屏，程度基本一致 |

因此该实验只能改变 DRM 名义 timing，不能控制 RMX5200 的真实扫描率，而且会破坏
链路稳定性。`uniform_180_link`、porch 目标表、状态参数和启动选项均已从正式实现
删除；静态测试会阻止它重新成为可选 profile。后续 175/180 调试必须保留各档真实
独立 link，并研究 Qualcomm 的 PHY/PLL hopping 与面板切档命令。

只读诊断进一步确认，这块面板各 timing 私有对象的通用 ADFR min-fps map
字段为空；LTPS 降档走的是原厂 timing 切换命令。内核日志已捕获
`144 -> 120 -> 60`，并分别使用原厂 120/60 的时钟和 transfer 参数。因此不再
对未启用的通用映射表或未命中的 ADFR hook 做修改。

## 安全边界

`post-fs-data.sh` 只有在 `config/drm_experimental_enable` 精确匹配
`I_UNDERSTAND_RMX5200_DRM_INJECTOR_RISK` 时才会执行 DRM-KO；令牌不随模块发布。
后端默认是 DTBO。KO 运行期间不要在线 `rmmod`，回滚使用切换回 DTBO 后重启。
PLK110、PJD110 没有本次 RMX5200 实机证据，不能将其标记为已完成。RMX5200
默认配置可以保留 175/180 供手动实验，但 WebUI 必须把 175 标为边缘档、180
标为当前样机不可用，不能自动切换到这两个档位。
## 2026-08-09 AE084 profile gate 真机复测

本次新增共享 profile：`ae084-dvt02-ltpo1hz-dry-run-v1`。设备序列号为
`3B15AQ00DHW00000`，原厂 DTBO SHA-256 为
`0de4f26051248e1589e6813798b0c22ad58e17333ae5f20b04b94e1a70f60d8e`。

切换到 DRM 后端并使用一次性令牌重启后，新的 `0.12-rmx5200-ae084-profile-gate`
模块报告：

```text
applied=Y
cache_applied=Y
failure_code=0
adfr_profile_valid=Y
adfr_command_injection_supported=N
ADFR profile=ae084-dvt02-ltpo1hz-dry-run-v1 command_injection=0
```

系统 DRM mode 从原厂 8 条追加到 16 条，期间 DTBO 回读哈希保持不变，
`adfr_config=0x0`。随后切回 `dts_backend=dtbo`、删除一次性令牌并重启，
`ko_loaded=no`、状态为 `skipped:dtbo`，系统恢复原厂 8 条 mode。

parser-only DTS 在设备上解包并打包成功，但官方 AVB 复用阶段拒绝修改后的
payload：设备 `ro.boot.verifiedbootstate=green`、`ro.boot.vbmeta.device_state=locked`、
`ro.boot.veritymode=enforcing`，没有厂商私钥时不能生成可刷的修改 DTBO。未执行
分区写入，不能把这次结果记为 parser 真机通过，更不能记为物理 1Hz。

## 独立 HMBIRD KO 历史实验（2026-08-09，已废弃）

以下记录仅保留用于追溯，不能作为当前安装路径。当前版本删除独立
`bin/hmbird.ko`，风驰只通过安装阶段的 DTBO 补丁写入。

历史版本曾将风驰逻辑从 `rmx5200_drm_modes.ko` 拆出为 `bin/hmbird.ko`。DRM 后端由
`post-fs-data.sh` 调用 `scripts/hmbird_backend.sh`，DTBO 后端明确跳过该 helper，
因此不会由两个模块同时生成高刷或风驰节点。

加载 gate 如下：

| 条件 | 允许值 | 输出 |
| --- | --- | --- |
| UI | ColorOS 或 Realme UI | `ui_valid=Y` |
| SoC | `SM8850/SM8850P/SM8845` | `HMBIRD_EXT` |
| SoC | `SM8750/SM8750P/SM8650/SM8650P/MT6991/MT6993` | `HMBIRD_OGKI` |

模块参数 `ui_family`、`soc_model`、`hmbird_type` 必须与 gate 一致；错误组合直接
返回 `EINVAL`。helper 还要求 DRM 一次性实验令牌，并在 `/proc/kallsyms` 中检查
动态 OF changeset API，只有 API 完整时才传入 `dynamic_of=1`。

当前设备信息：

```text
serial=3B15AQ00DHW00000
model=RMX5200
ro.soc.model=SM8850
ro.build.version.realmeui=V7.0
ro.product.brand=realme
```

真机命令：

```text
adb push bin/hmbird.ko /data/local/tmp/hmbird.ko
adb shell su -c 'insmod /data/local/tmp/hmbird.ko enable=1 probe_only=0 dynamic_of=0 ui_family=realmeui soc_model=SM8850 hmbird_type=HMBIRD_EXT'
```

结果：

```text
insmod_rc=0
ui_valid=Y soc_valid=Y type_valid=Y
node_present=Y node_created=N
consumer_reinit_supported=N failure_code=0
selected_type=HMBIRD_EXT
```

内核日志为 `existing node type=HMBIRD_EXT accepted`。本机 live DTBO 已含风驰节点，
且运行内核没有 `CONFIG_OF_DYNAMIC`/完整 `of_changeset_*` 符号，因此本次验证是
“gate + 已有节点复用”，不是晚加载创建 stock 节点或重新初始化调度消费者。对于
没有预置节点的平台，helper 会记录 `error:insmod:<rc>` 并保持 fail-closed。

随后将同一 helper 临时推送到设备并以真实 `getprop`、token 和 `insmod` 执行，得到：

```text
applied:node_present=Y,node_created=N,type=HMBIRD_EXT,consumer_reinit=N
```

模块已卸载，临时目录已删除。此次只读回读的当前 `_a` DTBO SHA-256 为
`563ca0629faa006fcb7541e82e2b45b566865360335abcc324a8928546492dec`；原厂回滚
基线仍保存在 `work/device-module-20260809/dtbo.img.sha256`，值为
`0de4f26051248e1589e6813798b0c22ad58e17333ae5f20b04b94e1a70f60d8e`。

原厂回滚 DTBO 的 SHA-256 保留在 `work/device-module-20260809/dtbo.img.sha256`：
`0de4f26051248e1589e6813798b0c22ad58e17333ae5f20b04b94e1a70f60d8e`。官方 AVB
helper 对修改 payload 返回 hash descriptor 校验失败，未向 `dtbo_a/b` 写入任何字节。
