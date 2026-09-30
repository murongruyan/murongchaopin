# 慕容显示增强 v2.9.39

本版修复 ColorOS 17 上原厂 LTPS 静止投票再次落到超频档的问题，并补回 WebUI 启动加载页样式。

## 修复内容

- 当前 RMX5200 的 SurfaceFlinger 更新后移动了动画投票和 AP-scale 两个补丁站点，旧版
  的整文件 hash 表没有命中，补丁直接拒绝挂载，原厂 60Hz 静止档因此落到了超频节点。
- 已知 hash 继续作为快速缓存；未知构建改为在 SurfaceFlinger 内搜索窄指令签名并动态
  解析站点。每个站点在写入前都校验原指令，写入后再次校验，不会盲改地址。
- 解析出的站点会随补丁契约保存，已经是补丁副本时也能继续完成启动后校验。
- 补齐 WebUI 启动加载页的 `.boot-overlay`、旋转动画和提示文字样式，并更新缓存串号。

## 真机验证

- 系统：`RMX5200` / ColorOS 17 / 内核 `6.12.69`。
- 在 `rmx5200_drm_modes` 已加载、原厂 1080p 节点被注入模块移除的状态下：
  - 静止：`1440x3136 60Hz`
  - 滑动：`1440x3136 120Hz`
  - 滑动结束：自动回到 `1440x3136 60Hz`
- SurfaceFlinger 补丁：`active:boot_verified`，`/system/bin/surfaceflinger` 已绑定到补丁副本。

## 安装说明

在 KernelSU、Magisk 或 APatch 中刷入 Release 附带的
`Murong.Display.Enhancement-v2.9.39.zip`，然后完整重启设备。
