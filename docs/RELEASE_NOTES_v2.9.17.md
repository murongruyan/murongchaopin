# 慕容显示增强 v2.9.17

## 付费 Hook 自愈改为版本号比较

- 只有模块内置的付费 Hook 比已安装版本新时才升级，已安装的同版本或更高版本不再被开机脚本覆盖；并为付费 Hook 增加独立的 `display_premium_hook.version` 构建产物。

## Hook 版本号独立递增（v69）

- 免费 / 付费 Hook 改用各自独立的版本号（v69）：以后每次代码变更都随构建递增，避免“改了代码但版本没动”导致误判。

## SystemUI 稳定性加固

- hook `IconManager.onSetIcon` 的 stock 类型转换崩溃点（网络速度视图占用状态栏图标槽位导致 `NetworkSpeedView cannot be cast to StatusBarIconView`），不再让 SystemUI 崩溃重启；免费 Hook 新增 `com.android.systemui` 作用域，安装/升级后自动恢复。

## 刷新率设置页卡顿修复

- 修复“设置 → 屏幕刷新率 → 自定义应用刷新率”在 ColorOS 16.99+ 上主线程被 OPlus 后端刷新调用阻塞约一分钟的问题：运行时发现阻塞的 `refreshUiData` 调用并挪到后台线程，页面即时渲染。

## 其他修复

- 彻底移除 `PremiumGateBridge` 中残留的 `ActivityThread.systemMain()` 反射兜底，杜绝显示锁路径上的同类死锁。
- 诊断包收集器自动识别模块目录名（不再硬编码 `murongchaopin`），避免部分设备收集到空的版本/模块信息。
