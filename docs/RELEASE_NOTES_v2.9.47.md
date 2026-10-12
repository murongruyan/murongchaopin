# 慕容显示增强 v2.9.47

本版只修一件事：**熄屏后再亮屏，刷新率不该"抖两秒"才回到你选的档，更不该卡在中间档。**

## 一、现场（PLK110，超频 185Hz，人脸/指纹解锁）

模块日志里 118 次亮屏、118 次都是同一套动作：

```
Screen ON reapply queued: physical mode and framework mirror will be restored together
Refreshed current mode before switch: cached=7 observed=7          ← SurfaceFlinger 说已经在 185
Screen ON reapply seeded native anchor: target=7/185Hz anchor=5/165Hz
SurfaceFlinger physical mode requested: mode=5                    ← 先掉到 165
Refresh ladder up custom: 5/165Hz -> 6/175Hz
Refresh ladder up custom: 6/175Hz -> 7/185Hz                      ← 再爬回 185
... 6 次 settings put ... Screen ON generic reapply completed
```

**每次亮屏 = 3 次真实面板切换 + 约 2 秒 + 6 次设置写入。** 其中 2 次锚点校验失败、2 次
`retry pending`，面板就留在 165/175，必须手动降档再升档——这就是反馈里的两个现象。

## 二、为什么以前必须这么干

熄屏（DOZE）之后 SurfaceFlinger 的 `activeMode` 可能仍然报"你要的扩展档"，而面板其实落在
stock fallback 上。老逻辑分不清这两种情况，于是**只要 SurfaceFlinger 报目标就先降到原生锚点、
再一档一档爬回来**——安全，但每次亮屏都要付这份钱，还要和厂商 floor 抢。

## 三、改成用证据判定

跳过恢复要同时满足三条：

| 证据 | 来源 | 含义 |
|---|---|---|
| applied 快照 == 目标 | `dumpsys display` 的 `mActiveSfDisplayMode` | composer 回调确认面板真的吃下了这一档 |
| 厂商 ADFR floor ≥ 目标 | `/sys/kernel/oplus_display/min_fps` | 厂商栈自己就会把它保持住，熬得过 DOZE |
| 实时 TE（若可读）== 目标 | `test_te` / `dynamic_float_te` | 独立于框架的旁证 |

三条同时成立 → 只补设置镜像（peak/min/user/ColorOS 枚举），**一次面板切换都不发**；
任何一项读不到或不一致（含节点不存在）→ 老的锚点+阶梯路径原样执行，行为不变。
RMX5200 自制 LTPO 那条分支没有改动。

修好后同一个场景应该只看到：

```
Screen ON reapply skipped: mode=7/185Hz applied=7 floor=185Hz
```

## 四、验证

- 免费 / 付费 daemon 用 CI 同参数（`aarch64-linux-android30 -O3 -static`）编译通过；
- `tests/rate_ladder_unit.c` 新增 8 个纯判定用例：floor 低于目标、applied 仍停在锚点、
  实时 TE 掉档、节点读不到（必须继续恢复）、目标为 0 等，WSL + gcc 真实运行通过；
- `check_screen_on_reapply`、`check_daemon_jank_hotpath`、`check_rate_daemon_transaction`、
  `check_surfaceflinger_ltps_vote_patch` 全绿；
- 免费仓 `bin/rate_daemon` 已按同参数重建，指纹 sidecar 按 LF 检出模拟与 CI 计算一致。

## 五、说明

- 如果你在设备上装了会改 `ro.serialno` 的工具，1.2.1 起已做身份钉住，不会掉授权。
- 本版未改动分辨率/密度镜像逻辑；2K 相关的 SF 投票过滤补丁仍是 2.9.46 的那套。
