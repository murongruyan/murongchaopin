# 慕容显示增强 v2.9.15

## 死机/热重启修复

- system_server 开机阶段（`systemReady` → `DisplayModeDirector`）若在显示锁内重新反射进入 `ActivityThread.systemMain()`，可能与其他模块的显示 Hook 形成 AB-BA 锁死，触发 watchdog 热重启。
- 现在系统上下文只在模块启动早期预热一次并缓存；所有 Hook 回调不再反射 `ActivityThread`，物理包络/模式解析等 Hook 正常运行。
- 真机验证：一次重启后无 watchdog/ANR trace，system_server 16 + 11 项 Hook 全部加载。
