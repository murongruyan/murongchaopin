# 慕容显示增强 v2.9.4

这是 KernelSU 安装 DRM-KO 后端时 native 工具权限的修复版本，其他模块功能保持不变。

## 修复内容

- 修复选择 DRM-KO 后报 `HMBIRD DTBO tooling is incomplete`：KernelSU 解压阶段会把普通文件设为 `0644`，安装器现在会在任何后端执行前恢复必需 native 工具的 `0755` 权限。
- DTBO 与 DRM-KO 后端共用同一份明确工具清单；任一工具缺失或权限设置失败都会在选择后端前给出明确错误。
- 保留 v2.9.3 已修复的第二次选择实时提示、简单音量键读取、两次选择间 1 秒等待、无超时和无默认 DTBO 行为。

## 安装说明

在 KernelSU、Magisk 或 APatch 中刷入 Release 附带的 `Murong.Display.Enhancement-v2.9.4.zip`，按界面提示完成两次音量键操作，然后完整重启设备。
