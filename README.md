# 慕容显示增强

## 简介
这是一个面向 OnePlus 和 Realme 设备的 KernelSU/Magisk 显示模块，支持 DTBO 与 DRM-KO 两种超频后端，并提供刷新率、分辨率和显示策略管理。

本项目始终只发布一个“慕容显示增强”模块 ZIP。免费与付费表示同一模块内的授权状态，不是两个模块或两个安装包。未授权时免费能力可完整离线运行；取得永久授权后，由模块 WebUI 校验设备与签名并按需下载增强组件。用户不需要、也不应另外寻找所谓 Premium 模块。

## 功能特性
- **多档位刷新率支持**：真我 GT8 Pro 可枚举 123Hz、150-180Hz 档位；当前 RMX5200 样机实测 170Hz 稳定，175Hz 仍有少量细线，180Hz 花屏不可用。1+15 支持 123Hz、170-199Hz；DTBO 生成的新增节点会带同面板原厂 60Hz ADFR 命令组和 1Hz 映射，但尚无 1+15 真机验证。
- **WebUI 管理界面**：内置功能强大的 Web 管理界面，无需复杂的命令行操作。
- **自定义配置**：
  - 支持查看当前支持的刷新率节点。
  - 支持手动添加自定义刷新率节点。
  - 支持删除不需要的刷新率节点。
- **ADFR 控制**：
  - 在内核已提供对应 sysfs 接口的设备上提供禁用/恢复可变刷新率 (ADFR) 的功能；它不会凭空生成面板专用 DSI 命令。
  - RMX5200 的 DTBO 后端提供默认关闭的“静息 1Hz DTS 解析验证”：仅写入 `0x101` dry-run 配置和最低帧率映射，用于验证内核能否解析，不发送 ADFR 面板命令，也不代表屏幕已经实现物理 1Hz。
  - 自动备份系统属性，支持一键还原默认设置。
- **安全机制**：
  - 原厂 DTBO 与 Web 工作镜像隔离，并使用 SHA-256、AVB 和压缩恢复副本保护。
  - 模块卸载功能。

## 同一模块内的功能权限

- **未授权也可使用**：DTBO / DRM-KO 后端、自定义超频刷新率节点、模块 WebUI 的全局/应用刷新率与分辨率、原厂显示策略（RMX5200 为已修复的原厂 LTPS）、风驰节点、运行日志、关于与卸载回滚。
- **取得「显示增强永久授权」后解锁**：Settings 内刷新率/分辨率/应用独立刷新率增强、游戏助手与 Scene 联动、自制 LTPO、完美禁用 ADFR、视频动态插帧（抖音），以及后续明确登记的显示增强。授权 20 元，一卡一机，永久有效。

授权用户仍安装同一个公开 ZIP，只需在 WebUI 的“我的”页登录慕容调度账号、绑定本机并点击下载增强组件，完成校验后整机重启。组件安装包含签名、逐文件哈希、机型、SoC、内核和后端检查；授权异常只会在下次完整开机切回未授权路径，不会热卸载显示组件或重启显示服务。

## 显示应用后端

WebUI 只有两种应用后端：

- `DTBO`：修改并刷入 DTBO 分区，支持工作区中的完整 DTS 编辑和自定义档位。
- `DRM-KO`：Qualcomm live mode 注入器，不向 DTBO 写入高刷 timing。RMX5200 的
  `bin/rmx5200_drm_modes.ko` 会克隆原 `process_dts.c` 的 WQHD timing，运行时追加
  `1440x3136@123` 和 `150-180Hz`，并接受 WebUI 写入的 `runtime/drm_modes.txt` 自定义档位。
  它必须匹配本机 6.12 `msm_drm` ABI；用户选择 DRM-KO 后由启动脚本直接加载。
  PLK110 的 KO 仍只完成编译和 fail-closed 框架，未有 PLK110 真机 ABI 证据；PJD110
  使用官方 6.1 ABI 编译的 `pjd110_drm_modes.ko` 删除原生 60/90Hz 并注入 WebUI 档位，
  但目前同样只有静态验证，没有 PJD110 真机加载证据。

免费风驰节点由独立 `bin/hmbird.ko` 处理，且不依赖 DTBO/DRM-KO 后端选择。它只接受 ColorOS/Realme UI，
并按 `ro.soc.model` 将 `SM8850/SM8850P/SM8845` 映射为 `HMBIRD_EXT`，将
`SM8750/SM8750P/SM8650/SM8650P/MT6991/MT6993` 映射为 `HMBIRD_OGKI`。DTBO 已有
风驰节点时独立 KO 只校验并复用，避免重复创建。DRM 后端会从原厂基线生成不含显示改动的
最小 DTBO；PJD110 的配套镜像还保留完整 DTBO 路径已有的 6000mAh 解容、2800mV 阈值和
`reserve_chg_soc=1`，所有面板 timing 仍保持原厂值。

两种后端共用 WebUI，但路径不同。DTBO 后端保留完整 DTS 节点增删和刷入流程；RMX5200
DRM-KO 将自定义刷新率转换为 `宽x高@刷新率[:clock_hz]` 规格，不向 DTBO 写高刷 timing，也不会修改
`img/dtbo.img` 原厂基线。后端选择只影响“应用更改”时的执行路径。

## 安装与使用
1. **下载与安装**：
   - 在 KernelSU 或 Magisk 管理器中刷入本模块的 ZIP 包。
   - 首次安装确认原厂 DTBO 后，可用音量键选择应用后端：音量+为 DTBO，音量-为
     DRM-KO；超时默认 DTBO。
   - 重启手机以生效。

2. **使用管理界面**：
   - 打开 KernelSU/Magisk 应用。
   - 进入“模块”页面。
   - 找到“慕容显示增强”。
   - 点击模块卡片上的“操作”或“WebUI”按钮（取决于管理器版本）。
   - 在弹出的 Web 界面中进行刷新率管理、ADFR 设置或恢复操作。

## 构建说明
- 本地重新编译 `process_dts`、`dts_tool`、`pack_dtbo`、`unpack_dtbo`、`rate_daemon` 时，建议优先使用 `NDK 30.0.14904198` 或兼容的 `r30` 系版本。
- 独立风驰 KO 使用目标设备内核树和已准备的 Kbuild 输出编译：`bash src/ko/build.sh hmbird`；
  产物为 `bin/hmbird.ko`，其 vermagic 必须与目标内核完全匹配。
- `src/build.bat` 与 `build_daemon.bat` 现在会优先检测 `%ANDROID_NDK_ROOT%`、`%NDK_ROOT%`，再检测本机常见的 `r30-beta1 / r30` 路径，最后才回退旧路径。
- GitHub Actions 工作流也已经统一到 `NDK 30.0.14904198`，会在 Ubuntu Runner 上重新编译这些原生二进制并组装最终模块包。

## 注意事项
- **风险提示**：修改屏幕刷新率和系统底层参数存在一定风险，可能导致屏幕显示异常、耗电增加或系统不稳定。请务必在操作前备份重要数据。
- **黑屏处理**：如果应用新的刷新率后出现黑屏，请尝试强制重启手机。如果问题依旧，请进入安全模式或通过 TWRP/ADB 删除本模块 (`/data/adb/modules/murongchaopin`)。
- **兼容性**：本模块目前仅适配 **真我 GT8 Pro**、**OnePlus 12** 和 **OnePlus 15**。其他 OnePlus/Realme 机型请谨慎测试。

## 更新日志
请查看 [update.json](https://raw.githubusercontent.com/murongruyan/murongchaopin/main/update.json) 获取最新版本信息。

## 开源协议
本公开仓库内的源码采用 [GPL 3.0 License](LICENSE) 开源。授权后由服务器下发的增强组件不属于本公开仓库，也不会进入公开 Release 或 CI 产物。

## 作者
- **慕容茹艳**（酷安 @慕容雪绒）

## 致谢
感谢所有为本项目提供测试和建议的朋友。
- **酷安穆远星**（http://www.coolapk.com/u/28719807）
- **GitHub开源项目**（https://github.com/KOWX712/Tricky-Addon-Update-Target-List）
- **酷安大肥鱼** (http://www.coolapk.com/u/951790)
- **bybycode**（http://www.coolapk.com/u/716079）
- **破星**（http://www.coolapk.com/u/21669766）
- **酷安望月古川** (http://www.coolapk.com/u/843974)
- **傻瓜我爱你呀**（https://www.coolapk.com/u/33802586）
- **小宇同学**（https://www.coolapk.com/u/12778615）
- **COPG开源项目**（https://github.com/AlirezaParsi/COPG）
- **梦**（酷安：https://www.coolapk.com/u/1404550）
- **MTK-Display-Overclock-LKM 开源项目**（https://github.com/Yunnijian/MTK-Display-Overclock-LKM）
