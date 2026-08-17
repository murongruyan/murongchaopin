# 慕容显示增强 v2.9.5

本版本修复 RMX5200 在系统升级后，原厂 LTPS 静止降帧被错误映射到 QHD170 的问题。

## 修复内容

- 在 SurfaceFlinger 内部精确过滤新增的 `object-animation` 正向投票；0Hz 撤票以及其他
  FRTC/OTI 请求继续使用原厂逻辑。
- 跳过 AP-scale 旧配对表对已选 modePtr 的二次改写。该处理不锁 60Hz、不硬编码刷新率
  或 mode ID，触摸和动画仍会回到 `mode.txt` 中的用户上限。
- 补丁只对 RMX5200 的免费 `stock_ltps` 策略生效。其他机型、自制 LTPO 和完美禁用
  ADFR 策略不进入该路径；当前 OTA 指令或上下文不匹配时自动拒绝挂载。

## 真机验证

- 系统：`RMX5200_16.0.9.402(CN01)`。
- `QHD+ 120` 静止时稳定为 QHD60，短滑动后 0.25 秒内升到 QHD120，停止后自动回 60。
- 1.8 秒持续滑动期间始终保持 QHD120，手势结束约 0.2 秒后回到 QHD60。
- SurfaceFlinger 与 composer 进程全程稳定，没有热重启、黑屏或花屏。

## 安装说明

在 KernelSU、Magisk 或 APatch 中刷入 Release 附带的
`Murong.Display.Enhancement-v2.9.5.zip`，然后完整重启设备。
