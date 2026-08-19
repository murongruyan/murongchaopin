# 慕容显示增强 v2.9.7

本版本修复 WebUI 并发执行 DTBO 打包时的临时文件竞态。

## 更新内容

- “应用更改”和“一键超频刷写”增加设备端原子互斥锁，防止重复点击或多个 WebUI 页面同时操作同一 DTBO 工作区。
- 已有任务运行时直接拒绝第二个任务，不再让两个 `pack_dtbo` 进程互相删除 `dtb_temp.*.dtb`。
- 任务结束和受控异常退出时自动释放锁；进程已经消失的陈旧锁会在下次操作时安全恢复。
- CI 增加并发拒绝、正常释放和陈旧锁恢复测试。
- 修复部分 KSU WebUI 宿主重复分发触摸事件导致的重复提交；前端现在只允许一个显示写入流程同时运行。
- `start_apply/start_flash` 对已有任务返回幂等的 `Started` 状态，让重复触摸继续读取第一次任务的日志，而不是误报失败。

## 故障影响

旧版竞态发生在 DTBO 流程第 1 步，日志通常包含 `Can not read file: dtb_temp.0.dtb`。失败任务尚未进入官方 AVB 信息合并及分区写入阶段，因此不会修改 DTBO 分区。

## 安装说明

在 KernelSU、Magisk 或 APatch 中刷入 Release 附带的 `Murong.Display.Enhancement-v2.9.7.zip`，然后完整重启设备。
