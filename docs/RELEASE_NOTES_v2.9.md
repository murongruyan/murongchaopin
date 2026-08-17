# 慕容显示增强 v2.9

本说明基于 v2.8（提交 `ae7fc32`）到 v2.9 的公开源码差异编写。慕容显示增强对外只发布一个模块安装包 `Murong.Display.Enhancement.zip`；未授权与授权增强是同一模块的状态，不需要安装第二个模块。

## 相对 v2.8 的实际变更

- 加入 DTBO / DRM-KO 双后端选择、后端探测和机型模式清单；公开包新增 RMX5200、PLK110、PJD110 DRM-KO 运行时产物。
- 重写 DTS 处理的 RMX5200 分支：增加扩展节点去重、顺序整理、原生节点隔离选项、HMBIRD-only 和 PJD110 KO-support 处理；ADFR dry-run 明确不发送面板 DSI 命令。
- 新增免费独立风驰 KO 和 UI/SoC 分派，支持 `HMBIRD_EXT` 与 `HMBIRD_OGKI` 两种节点类型。
- 新增 ColorOS 配置挂载、启动阶段脚本、Settings bridge 与公开 LSP API 102 Hook 基础层。
- 新增账号/卡密授权、租约、本机组件下载和 Ed25519 验证链。公开 ZIP 只带公钥和验证器；内部增强组件只允许经模块校验后下载，不作为第二个模块发布。
- WebUI 增加授权状态、后端状态、显示策略、ADFR、视频插帧、应用独立刷新率/分辨率等页面与命令入口，并改为玻璃主题及悬浮底栏。
- CI 改为构建唯一公开 ZIP，并在打包前剔除私有 LTPO/ADFR/MEMC 文件，运行公开后端、WebUI 和回归检查。
- 修复模块安装时的后端选择误导和音量键连选：确认官方原厂 DTBO 与选择 DTBO/DRM-KO 现在是两次明确操作；每次选择只接受按下事件，并等待同一按键抬起后再进入下一步，不会超时或默认写入修改后的 DTBO。

## 安装说明

在 KernelSU 或 Magisk 中刷入 Release 附带的 `Murong.Display.Enhancement.zip`，完整重启后从模块 WebUI 使用。已有用户可直接覆盖更新；更新流程会保留模块已有的用户配置和已验证的原厂 DTBO 备份。

显示超频存在设备差异。出现黑屏或花屏时请停止继续切换，完整重启后使用模块回滚入口；无法进系统时按设备维护方式从安全模式或 fastboot 恢复原厂 DTBO。
