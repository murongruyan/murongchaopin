# Qualcomm DRM-KO profiles

## 代码来源与边界

`src/ko/rmx5200_display_modes.c` 借鉴 `pmb110_170_mode.c` 的 live mode 注入顺序：先
验证面板/源 timing，再克隆私有 timing 和 `dsi_display_mode` 记录，把新记录追加到
Qualcomm 数组；随后克隆 DRM mode、更新 connector mode list 并发送 hotplug。失败时按
反向顺序恢复 connector、live mode 数组、panel count 和私有对象。它不是 DTS Overlay，
也不写 `dtbo_a/b`。

RMX5200 源码通过 `get_main_display()` 获取主 DSI display，并根据 live DT 和
`dsi_display_mode` 记录交叉验证布局。`src/ko/build.sh` 会针对同一内核树分别构建，
避免 Kbuild 的多外部模块限制。RMX 的 `mode_specs` 参数格式为
`widthxheight@refresh[:clock_hz];...`。

RMX5200 的每个新增 mode 都深拷贝私有 DSI PHY timing。默认
`config/drm_phy_profile.txt=stock` 保留模板值；实验 profile
`v72_vendor_delta` 为 123/150/155/160/165/170/175/180 八个精确默认档分别应用
v7.2 计算增量。DRM-KO 是免费后端，该 profile 不再依赖实验令牌或付费 ADFR
profile；它只能用于清单中的精确默认档，不能自动推广到任意自定义时钟，也不能视为
175/180 已稳定。

固定 180Hz link 再通过 HFP/VFP 构造低档的实验已经失败并从代码中删除。物理
调试层实测 150-180 档都只能到 144Hz，123 档只能到 120Hz，且所有实验档均为
程度相近的中等花屏。这说明 RMX5200 command-mode 面板的实际扫描率不由这组
blanking 数值决定。此前降低 link 再缩短 porch 的方向也只会把 175/180 实际降成
170/175。正式实现不再提供任何固定 link 或 porch 补偿 profile。

## 设备覆盖

| 机型 | 后端 | KO | 运行时规格 | 状态 |
| --- | --- | --- | --- | --- |
| RMX5200 | DTBO / DRM-KO | `rmx5200_drm_modes.ko` | 默认 WQHD 123/150-180；WebUI 可追加任意安全范围档位 | 已在 RMX5200 实机完成 probe、单档追加、DRM/SurfaceFlinger 冷启动可见性、首选模式切换和 DTBO 哈希闭环；持续锁定受厂商 ADFR 策略影响 |
| PLK110 | DTBO / DRM-KO 框架 | `plk110_drm_modes.ko` | DTBO 支持原有 123/170-199 逻辑；DRM 规格待真机 ABI 验证 | 只能编译和 fail-closed 静态验证，不能宣称 PLK110 实机完成 |
| PJD110 | DTBO / DRM-KO | `pjd110_drm_modes.ko` | 1440x3168；默认删除原生 60/90Hz，WebUI 可追加运行时档位 | 已使用一加 12 官方 6.1.141 源码编译和静态事务验证；缺少 PJD110 真机 probe/切换证据，首次启动按精确 ABI fail-closed |

DTBO 与 KO 的差异是显式保留的，不要求三机型强行一致：

- RMX5200 两个后端的默认高刷清单相同，都是 `123,150,155,160,165,170,175,180`。
  DTBO 后端还负责 DTS 级节点处理；DRM 后端只注入 live mode，高刷 timing 不写 DTBO，
  仅从原厂基线写入 HMBIRD-only 最小 DTBO。
- PLK110 的 DTBO 清单是 `123,170,175,180,185,190,195,199`，并保留原有 DTS/ADFR
  处理；DRM 清单只有 `170,175,180,185,190,195,199`，且尚未完成 PLK110 真机
  Qualcomm ABI 验证，所以启动脚本继续 fail-closed。
- PJD110（一加 12）的 `pjd110_drm_modes.ko` 使用官方 SM8650 6.1 私有头在编译期取得
  `dsi_display` 偏移（lock `0x48`、modes `0x308`、panel `0x108`、connector `0x10`），
  验证 AA545/1440x3168 原生 60/90/120/144 四档后，事务删除 parsed/DRM 两侧的 60/90，
  再按 WebUI `mode_specs` 追加自定义高刷。卸载路径恢复原数组、panel count、connector
  顺序和私有 timing。PJD110 选择 DRM-KO 时会从原厂基线生成配套最小 DTBO，只写
  `oplus,batt_capacity_mah=6000`、`oplus_spec,vbat_uv_thr_mv=2800`、
  `oplus,reserve_chg_soc=1` 和 `HMBIRD_OGKI`；60/90/120/144 timing 与原 mode index
  保持逐字不变。因此 KO 应用路径与完整 DTBO 路径都包含解容，但显示 timing 仍只有一个所有者。
- `get_main_display` 的 MODVERSIONS CRC 由同一套官方 6.1 头和配置在构建时生成，产物依赖
  设备已有 `msm_drm`，不携带或加载构建期 provider。当前只有源码/编译/静态验证，不能
  把 RMX5200 的实机结果写成 PJD110 真机通过。

## 安全边界

DRM-KO 是免费后端，用户选择后直接在 `post-fs-data.sh` 加载，不依赖实验令牌或付费
ADFR profile。RMX5200 的加载顺序是 msm_drm 已初始化、SurfaceFlinger/HWC 尚未建立
mode cache，此时追加的 mode 才能被首次枚举看到。已注入的 KO 不建议在线 `rmmod`，
回滚使用切换回 DTBO 后重启。

## 风驰 DTBO-only

风驰节点不再由 `rmx5200_drm_modes.ko` 或独立 `bin/hmbird.ko` 维护。当前发布方案
只在安装阶段调用 `scripts/hmbird_backend.sh prepare-dtbo`，从原厂 DTBO 基线生成
结构化补丁并写入对应 `HMBIRD_EXT`/`HMBIRD_OGKI` 节点；开机阶段的 `apply` 仅记录
`disabled:dtbo_only`，绝不执行 `insmod` 或动态 OF 修改。这样风驰节点与显示模式只有
一个持久所有者，也避免晚加载导致的启动卡死。

`src/ko/hmbird.c` 保留为历史实验源码，不属于当前构建或安装路径。对没有 dynamic OF
的 RMX5200，必须通过 DTBO 重启让厂商消费者读取节点；PJD110 的配套镜像仍可同时写入
解容参数，其他机型保持 HMBIRD-only。

helper 直接检测 UI：Realme UI 由
`ro.build.version.realmeui` 或 Realme brand/manufacturer 识别，ColorOS 由 OPPO
brand/manufacturer 和 `ro.build.version.oplusrom` 识别。支持 SoC 与 type 映射为：

| SoC | `hmbird_type` |
| --- | --- |
| `SM8850`, `SM8850P`, `SM8845` | `HMBIRD_EXT` |
| `SM8750`, `SM8750P`, `SM8650`, `SM8650P`, `MT6991`, `MT6993` | `HMBIRD_OGKI` |

未知 UI/SoC 或错误 type 均不调用 `insmod`。加载参数和结果通过
`/sys/module/hmbird/parameters/*` 与 `runtime/hmbird/status.txt` 留痕。
若发现同名 `hmbird` 已加载，helper 还会核对这些参数是否与当前系统一致；不一致时
记录 `blocked:existing_module_mismatch`，避免复用外部错误模块。

RMX5200 `SM8850 + Realme UI` 的当前验证目标是安装阶段写入 `HMBIRD_EXT`，重启后由
厂商消费者读取；不再把历史 `insmod` 结果当作当前安装闭环。

2026-08-17 在 OTA 后的 RMX5200 `_b` 槽完成免费冷启动闭环：从原厂 DTBO
`0de4f26051248e1589e6813798b0c22ad58e17333ae5f20b04b94e1a70f60d8e` 生成只新增
`HMBIRD_EXT` 的最小镜像，写入/回读哈希为
`fdc8c5b7e32431460efc4ef77445cd916405da9cb4d7f55ee063d6a4757a3ce0`。整机重启后
`rmx5200_drm_modes.ko` 为 `applied=Y/cache_applied=Y/failure_code=0`，注入 8 档，
两套原厂 FHD 去重计数均为 4；DTBO 回读含 `HMBIRD_EXT` 节点，厂商
`oplusHmbirdBpfManager` 已运行。
