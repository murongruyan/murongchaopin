# 慕容显示增强 v2.9.8

本版本修复 2.9.7 在部分设备上安装直接失败的问题。

## 修复内容

- DRM-KO 的 HMBIRD 配套 DTBO 恢复使用按机型、项目 ID 和面板识别的 `process_dts` 结构化路径，兼容真实 RMX5200/PJD110 DTBO，不再依赖只识别 overlay 的文本扫描器。
- OnePlus 15（PLK110）原厂 timing 缺少 `cell-index` 时自动补写连续索引，避免所有节点重编号失败导致安装脚本返回错误。
- 增加真实无 `cell-index` DTS 回归测试，并接入 CI。

游戏助手 Hook 本身属于授权 API 102 组件；2.9.7 安装脚本在 DRM-KO 前置 DTS 处理失败时会提前退出，导致 Hook 更新步骤根本没有执行。修复安装失败后，已安装的授权 Hook 才能正常完成更新和加载。

## 安装

在 KernelSU、Magisk 或 APatch 中刷入 `Murong.Display.Enhancement-v2.9.8.zip`，然后完整重启设备。
