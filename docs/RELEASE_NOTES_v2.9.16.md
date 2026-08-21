# 慕容显示增强 v2.9.16

## 开机稳定性修复（撤回 v2.9.15）

- v2.9.15 在 system_server 启动早期反射 `ActivityThread.systemMain()` 预热系统上下文，实测会导致 system_server 启动异常、zygote 重启、LSPosed 反复进入安全模式，已撤回。
- v2.9.16 彻底移除该启动反射：物理包络 Hook 不再在显示锁路径内查询系统状态，系统上下文也不再在 Hook 回调中反射获取。
- 真机验证：模块启用状态下连续开机稳定，system_server 无重启、无 watchdog、LSPosed 不再进安全模式。
