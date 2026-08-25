# 慕容显示增强 v2.9.20

本版修复付费资源包的内核兼容声明与 KO 构建链，并更新底栏交互体验。

- 修复付费包把 `6.12` 与 `6.1` 拼接成 `6.126.1` 的安装脚本问题；内核版本现在按独立条目校验，不再误报 `kernel not supported`。
- 底栏选中指示器改为按按钮几何中心定位；长按后进入跟手的液态玻璃放大效果，横向拖动连续跟随，松手切换页面并平滑回弹。
- WebUI 致谢名单加入 [AndroidLiquidGlass](https://github.com/Kyant0/AndroidLiquidGlass) 开源项目。
- 免费包继续隔离付费 KO、Hook 和授权资源，更新流程保留已有设备配置。

在 KernelSU、Magisk 或 APatch 中刷入 Release 附带的 `Murong.Display.Enhancement-v2.9.20.zip`，然后完整重启设备。
