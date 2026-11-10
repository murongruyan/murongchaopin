# 慕容显示增强 v2.9.49

本版修复用户反馈的 6 个体验问题，并做了一次设备日志审计（Settings/框架侧）。与付费包 **1.2.7** 同步。

## 一、自定义超频页“＋添加”按钮没有反应（用户反馈 5）

- 现象：WebUI 刷新率/自定义超频页，点“读取当前 DRM 节点”后点“＋添加”没有任何弹窗。
- 根因：DRM 分支调用了只在父级函数作用域内存在的局部函数 `effectiveWidth()`，所以只要“刷新率”页加载过显示模式（`displayModes` 非空），点击就会抛
  `ReferenceError: effectiveWidth is not defined`；`onclick` 是 async，异常变成 unhandledrejection，于是按钮“看起来完全没反应”。
- 修复：按顶层 `currentResolutionWidth` 选择基准宽度；显示模式未加载时按需加载；整个函数加 try/catch，失败会弹出明确提示而不再静默。
- 顺带修复：WebUI 全局错误上报（`log_event`）以前只记录 `webui_error` 这个类型、把真正的错误与堆栈吞掉了；现在会记录完整 detail（截断 4000 字符），页面错误上报上限也从 400 提到 2000 字符。

## 二、自定义刷新率“要等 2 分钟才生效”（用户反馈 4）

- 现象：改刷新率后屏幕没有立刻切换，最长要等约 2 分钟。
- 根因：视频临时模式（MEMC/视频 SurfaceView）退出时会进入最长 120 秒的恢复 defer：
  ColorOS 释放 MEMC 投票但视频 SurfaceView 仍在前台时，daemon 会继续沿用视频会话里的旧档位，用户此时写入 mode.txt 的新档位只被重载、不会下发到面板，直到 defer 结束。
- 修复：记录用户改档时间；defer 期间若用户在 60 秒内显式改过刷新率，把剩余 defer 上限一次性缩短到 10 秒
  （日志 `User mode change overrides video exit defer: deadline shortened to 10000ms`），到期后仍走原来的
  `clear_video_override` → Iris/ESD 恢复流程；没有用户改档时 120 秒语义完全不变，不动 MEMC 安全边界。
- 另：WebUI 与 Settings 的写入路径实测均 <1 秒落盘（mode.txt mtime + daemon “Config change settled”），排除写入端延迟。

## 三、守护进程自动续期登录 token 与付费授权（用户反馈 6）

- 现象：用户长期不打开 WebUI 时，7 天登录 token 过期、3 天租约进入 10 天 grace 后失效，只能重新登录。
- 根因：续期逻辑只存在于 WebUI 前端（打开页面才会执行），daemon/开机流程没有后台续期。
- 修复：新增无头续期脚本 `scripts/display_auth_renew.sh`（复用 `web_handler.sh` 既有的 HTTPS/header/租约验签保存能力）：
  - 开机 `sys.boot_completed` 后 90 秒首跑，之后每 6 小时检查；lease 剩余 ≤24h 或非 valid 时自动续租（3 天），
    每次已鉴权 GET 顺带保存服务端 `X-Refresh-Token`（服务端在 token 剩余 <3 天时轮换）；
  - 失败保留旧凭证、30 分钟退避重试、连续 3 次后回到 6 小时周期；离线/未登录/免费用户（仅 token 无租约）均不报错；
  - 日志只写时间戳与到期时间，不写 token/lease 内容；pid 单实例，disable/remove 时退出；
  - 免费 `service.sh` 启动、付费 `premium_service.sh` 启动、`rate_daemon_supervisor.sh` 每 60 秒保活。

## 四、daemon 2.9.49

- 新增 `GETFRONT` 只读命令（返回 system_server Hook 推送的前台包名缓存，供 Scene 联动使用）。
- 上述视频 defer 用户改档覆盖。
- 版本号同步 2.9.49。

## 五、设备日志审计发现并修复的问题（Settings/框架）

- “搜索刷新率后是开关不是选择”：ColorOS 17 应用刷新率页的**页内搜索列表**使用独立适配器，只渲染厂商 Switch，模块未 hook；
  现已接管搜索适配器，搜索结果同样是模块档位选择。
- 主列表每行的装饰被 `Preference.setSummary` 打断（RecyclerView computing layout 异常），导致行内仍保留开关；
  已改为不触发 notify 的写法并直接改行内数值，选中后行内立即显示新档位。
- ColorOS 17 的 `ScreenRefreshAppPreference` 已删除 `setEntries` 等 entries API（日志里 16 次 E），
  已改为直接走模块 picker；`Preference.setChecked` 不存在的 25 次 E 已由“C17 档位行由 front-page hook 提供时跳过重复注入”修复。
- Android 17 framework 删除了 `mAppSupportedModesByDisplay` 字段（system_server 203 次 E）；源码回退
  `mSupportedModesByDisplay` 已包含在本版 Hook 中，**安装本版并重启后生效**（此前日志中的报错来自重启前加载的旧 dex）。

## 六、验证

- 免费 daemon 由 CI 同参数（`aarch64-linux-android30 -O3 -static`）编译通过，版本串自校验 2.9.49；
- WebUI：真机点“读取当前 DRM 节点”→“＋添加”弹窗正常，添加 165Hz 成功并回显、可删除还原；JS 错误上报完整写入 daemon.log；
- Settings：搜索行/主列表均为档位选择（非开关），修复后 Settings 进程 E 日志为 0；picker 写入 mode.txt <100ms；
- 续期：真机强制续租成功（lease expires_at +3 天、Ed25519 验签通过）；断网/坏 token/未登录/单实例/免费 token-only 测试通过；
- 视频 defer 修复：两份 daemon 编译通过 + 代码路径与历史日志证据；真机视频场景对比见 1.2.7 说明。
## 七、额外修复（用户补充测试中发现）

- **视频插帧目标档位不受支持时静默失效**：WebUI 视频页允许保存不在本机模式表里的目标（如 165Hz），daemon 会在 VIDEOSTART 时拒绝、
  视频插帧实际不生效。现在：
  - WebUI 只列出真实可用档位；已保存的非法值显示为“当前不受支持”并提供“一键改到最近支持档”；
  - `set_video_motion_target` 兜底拒绝不可用档位；
  - daemon（premium）：请求的 fps 不在模式表时回退到同几何下最近可用档位（优先不低于请求值），并记录
    `Video temporary mode target ... falling back to nearest ...`，不再静默拒绝。
- **模块更新/重刷后用户手动配置丢失**：`customize.sh` 的用户状态保留列表漏了 `config/game_assistant_features.txt`
  （WebUI 里“游戏助手增强/插帧应用”的白名单），更新模块时会被新包覆盖；已补入保留列表。
- **Scene 刷新率开关开机写入时机**：`service.sh` 在 `sys.boot_completed` 之前就尝试写 Scene 私有目录，此时 /data 尚未解锁，
  状态一直停在 `skipped:scene_not_installed`；改为启动完成后后台重试（最多 10 分钟，成功即退出）。

## 八、本版真机验证（RMX5200 / ColorOS 17 / Android 17）

- 免费 Hook 83.0 + premium Hook 89.0 安装并重启后：system_server 的 `mAppSupportedModesByDisplay` E 日志 **从 203 次降为 0**；
- 开机自动续期：`auth_renew: loop start pid=... boot_delay=90s` → 90 秒后 `auth_renew: ok: lease valid expires_in=...`；
- WebUI：刷新率页/超频页＋添加弹窗/插帧页目标不支持提示与一键修复/日志页 全部通过（截图见 work/webui-video-target-fix/）；
- Settings：搜索列表档位选择、主列表行内即时刷新、picker 写入 mode.txt <100ms（截图见 work/settings-fix/）；
- Scene：新版双页弹窗适配通过（基础页 per-app 写入、性能页全局滑块），见 1.2.7 说明；
- 游戏助手 10.44.6：app 页与游戏内侧边栏 7 档 grid、点击写入 mode.txt（见 1.2.7 说明）。
