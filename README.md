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
- **ADFR / LTPO 控制**：
  - 在内核已提供对应 sysfs 接口的设备上提供禁用/恢复可变刷新率 (ADFR) 的功能；它不会凭空生成面板专用 DSI 命令。
  - RMX5200 的**公共 DTBO 后端**保留默认关闭的“静息 1Hz DTS 解析验证”：仅写入 `0x101` dry-run 配置和最低帧率映射，用于验证内核能否解析，不发送 ADFR 面板命令。这一条是解析实验，不是 RMX5200 自制 LTPO 的运行时实现。
  - RMX5200 授权组件另提供自制 LTPO 的 KO 与守护逻辑，已在样机完成 `1Hz -> 10Hz -> 30Hz -> 60Hz -> 用户选择的高刷` 的升帧，以及反向逐档降帧闭环；因此授权状态下屏幕可以进入实际的 1Hz 静息档。它与上面的 DTBO dry-run 是两条独立路径，不能把 dry-run 的限制套到已验收的自制 LTPO 上。
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
  PLK110 的默认 DRM 规格和启动探测已恢复，首次加载仍由 KO 做 fail-closed 的运行时
  ABI/布局校验；当前工作区未保留 PLK110 真机 ABI 证据；PJD110
  使用官方 6.1 ABI 编译的 `pjd110_drm_modes.ko` 删除原生 60/90Hz 并注入 WebUI 档位，
  但目前同样只有静态验证，没有 PJD110 真机加载证据。

风驰节点现在由 DTBO 后端持久写入，不再使用独立 `bin/hmbird.ko`，也不在
`post-fs-data` 阶段修改 live device tree。OGKI 使用 `fragment@15` 内的
`oplus,hmbird/version_type`，EXT 使用对应的 `config_type`。DRM 后端如果被选择，
仍只生成配套 DTBO（PJD110 还保留 6000mAh 解容、2800mV 阈值和
`reserve_chg_soc=1`），但不再加载风驰 KO；所有面板 timing 仍保持原厂值。
风驰节点本身由独立结构补丁器处理，不识别 RMX5200，不读取 `ro.boot.prjname` 或
DTBO `project-id`；显示超频仍保留它自己的机型和面板选择逻辑，两条路径互不作为前置条件。

两种后端共用 WebUI，但路径不同。DTBO 后端保留完整 DTS 节点增删和刷入流程；RMX5200
DRM-KO 将自定义刷新率转换为 `宽x高@刷新率[:clock_hz]` 规格，不向 DTBO 写高刷 timing，也不会修改
`img/dtbo.img` 原厂基线。后端选择只影响“应用更改”时的执行路径。

## 安装与使用
1. **下载与安装**：
   - 在 KernelSU 或 Magisk 管理器中刷入本模块的 ZIP 包。
   - 首次安装先按音量+继续，安装器会自动校验当前 DTBO；这一步只确认继续安装，不会单独修改。
     随后的第二次提示再选择后端：音量+为 DTBO（本次安装会写入修改后的 DTBO），
     音量-为 DRM-KO；第一次确认后固定等待 1 秒再进入后端选择，
     不会超时或默认写入 DTBO。
   - 后续更新模块时，安装器先读取当前 slot 的实际 DTBO 分区哈希，再决定路径，不以“模块
     目录是否被清空”或系统版本指纹作为唯一依据：
     - 当前哈希等于模块记录的 `img/dtbo.applied.sha256`：判定为普通软件更新，只替换
       Hook、脚本和守护进程，不读取或刷写 DTBO，也不重新选择后端。
     - 当前哈希等于模块原厂备份 `img/dtbo.img.sha256`：走正常安装流程，保留模块内的
       应用刷新率、自定义超频刷新率、游戏助手/视频插帧配置和后端选择。
     - 当前 DTBO 通过官方 AVB 签名校验但与模块原厂备份不一致：按当前系统建立新的原厂
       基线，再按原后端正常应用，同时保留上述用户配置；这覆盖系统升级后 DTBO 变化的情况。
     - 当前 DTBO 既不是原厂签名，也不是模块最近记录的应用版本：只警告并跳过底层刷写，
       继续安装软件组件，不覆盖未知 DTBO。
   - `ro.build.fingerprint` 只写入模块目录用于提示“模块备份与当前系统版本是否变化”，
     不决定更新路径。确实需要在更新时强制重做底层后端时，可在 root shell 中设置
     `MURONGCHAOPIN_UPDATE_BACKEND=dtbo` 或 `drm` 后再刷入。
   - 重启手机以生效。

2. **使用管理界面**：
   - 打开 KernelSU/Magisk 应用。
   - 进入“模块”页面。
   - 找到“慕容显示增强”。
   - 点击模块卡片上的“操作”或“WebUI”按钮（取决于管理器版本）。
   - 在弹出的 Web 界面中进行刷新率管理、ADFR 设置或恢复操作。

## 构建说明
- 本地重新编译 `process_dts`、`dts_tool`、`pack_dtbo`、`unpack_dtbo`、`rate_daemon` 时，建议优先使用 `NDK 30.0.14904198` 或兼容的 `r30` 系版本。
- 风驰节点不再编译或打包独立 KO；DTBO 后端直接写入持久设备树，因此没有
  vermagic、符号 CRC 或 `SMP preempt mod_unload modversions aarch64` 兼容性要求。
- `src/build.bat` 与 `build_daemon.bat` 现在会优先检测 `%ANDROID_NDK_ROOT%`、`%NDK_ROOT%`，再检测本机常见的 `r30-beta1 / r30` 路径，最后才回退旧路径。
- GitHub Actions 工作流也已经统一到 `NDK 30.0.14904198`，会在 Ubuntu Runner 上重新编译这些原生二进制并组装最终模块包。

## 注意事项
- **风险提示**：修改屏幕刷新率和系统底层参数存在一定风险，可能导致屏幕显示异常、耗电增加或系统不稳定。请务必在操作前备份重要数据。
- **黑屏处理**：如果应用新的刷新率后出现黑屏，请尝试强制重启手机。如果问题依旧，请进入安全模式或通过 TWRP/ADB 删除本模块 (`/data/adb/modules/murongchaopin`)。
- **兼容性**：本模块目前仅适配 **真我 GT8 Pro**、**OnePlus 12** 和 **OnePlus 15**。其他 OnePlus/Realme 机型请谨慎测试。

## 更新日志

付费组件启动前会校正已通过签名校验的 `premium/scripts/*.sh` 行尾。这样从
Windows/WebUI 下载的付费包不会因为 CRLF 被 Android `sh` 静默跳过；租约签名、设备绑定、
功能特性和包文件哈希仍然在校正前完成验证。发布工作流同时拒绝 CRLF 付费脚本。

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
