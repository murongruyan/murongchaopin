# 慕容显示增强 v2.9.44

这一版修的是「**游戏助手一打开，整屏分辨率来回跳、刷新率像是失效了**」，
外加两个 ColorOS 17 上的兼容问题。

## 一、现象（用户四真机日志）

15:06:23 → 15:06:44 之间，守护进程在 **1272x2772 ↔ 1080x2354** 之间整套切换了三个来回。
每一次切换都是：

```
Resolution change / 分辨率变更: 19 -> 7. Direct switch.
SurfaceFlinger physical mode requested: mode=7 width=1272 rc=0
Active display mode verified: mode=7 after=440ms samples=2
settings put secure/oplus_customize_screen_resolution_adjust / index / width / height   (4 次)
settings put secure/oplus_customize_screen_refresh_rate + peak/user/default/min          (5 次)
```

也就是**每次切换 App = 一次约 440ms 的整屏模式变更 + 9 次系统设置写入**。用户感受到的就是
「游戏助手里设的刷新率没生效、屏幕还在闪」。

## 二、根因

`mode.txt` 里多了一条**游戏助手自己**的条目：

```
1080x2354 199                        ← 默认
com.tencent.tmgp.gnyx 1080x2354 165
com.blrpj.hnhy.gw     1080x2354 60
com.tencent.tmgp.dfm  1080x2354 185
com.oplus.games       1272x2772 185  ← 悬浮窗宿主被当成普通 App
```

游戏助手是**悬浮窗宿主**，不是用户选择的显示对象。它一浮到前台，守护进程就按它自己那条
（原生分辨率）条目把整屏切过去，退出再切回；同时把这条临时几何**回写成用户的全局分辨率偏好**，
于是跳变被"粘住"，来回震荡。

## 三、修复

1. **悬浮窗宿主不再被当作普通 App**：`com.oplus.games` / `com.oplus.gameassist` /
   `com.coloros.gamespace` 处于前台时，保持游戏当前的模式，绝不按自己的条目动面板。
2. **条目几何不再驱动整屏切换**：条目里的分辨率只是"写入那一刻"的附带值。与当前面板几何不一致时，
   只应用该条目的**刷新率**，保持当前几何：
   `App row … is … but the panel runs …; applying …Hz in the live geometry`。
3. **不再把临时几何回写成全局分辨率偏好**：只有与用户配置的几何一致时才同步
   `oplus_customize_screen_resolution_adjust` 等键。

## 四、顺带修的两个 ColorOS 17 兼容问题

4. **设置页刷新率条目恢复**：ColorOS 17 把 `mScreenRefreshAppCategory` 改名为
   `mScreenRefreshRateSettingsCategory` / `mScreenRefreshRateCategory`，旧代码硬编码取字段抛
   `NoSuchFieldException`，导致整个"设置首页"补丁被跳过。现改为候选字段探测 + 空值容忍。
   真机验证：`Settings front-page rates=[120, 123, 144, 150, 155, 165]`，异常消失。
5. **进程启动后第一次请求也能抬高上限**：新增 `BridgeClient.primeGlobalRate()`，在 Hook 安装线程
   （LSPosed worker，不在 WindowManagerGlobalLock 内）做一次阻塞读取写入快照；热路径仍只读 volatile。
   此前异步快照未落地时首次 `setAppRequest` 会拿到 -1 而跳过抬高，游戏/小进程尤其明显。

## 五、验证

- 两个守护进程（免费 / 付费）与两个 Hook APK 均编译通过；
- 设置页修复已在 RMX5200 / ColorOS 17 真机验证（本次改动前该项是确定失败的）；
- 悬浮窗/几何逻辑需要用户四升级后复测：升级 2.9.44 → 打开游戏 → 开游戏助手悬浮窗 →
  分辨率不应再跳，游戏条目里的刷新率保持生效。

## 六、说明

- 悬浮窗宿主名单是内置的（三个包名），如果你的机型游戏助手包名不同，把包名发我即可加进去。
- 如果你确实想让某个 App 用不同分辨率，请在 WebUI 的按应用列表里设置——那是显式选择；
  游戏助手里的刷新率卡片只负责刷新率。
