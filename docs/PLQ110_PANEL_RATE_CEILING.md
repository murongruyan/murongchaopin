# 一加 Ace 6（PLQ110）170-199Hz 档位为什么不生效

反馈：切到 199Hz，实测仍然只有 165Hz。此前把原因写成「完美禁用 ADFR 导致面板
回落到 165Hz」，这个解释站不住脚，本文给出实际证据链与结论。

## 结论

PLQ110 的面板 **AA605_P_7_A0020 自身时序表最高就是 165Hz**。模块的 170/175/
180/185/190/195/199 档是 DTBO 生成器用 165Hz 的 timing 节点复制出来的
**AP 侧时序**：只改了 `qcom,mdss-dsi-panel-clockrate`、`qcom,mdss-dsi-panel-
framerate`、`qcom,mdss-mdp-transfer-time-us` 和 `cell-index`，面板侧的
`qcom,mdss-dsi-timing-switch-command` 原样继承 165Hz 档位的那一份。于是出现
「内核按 199Hz 驱动、SurfaceFlinger 报 199Hz、面板仍按 165Hz 扫描」的分裂状态。

与 ADFR 无关：`persist.oplus.display.vrr*` 等 props 只影响自适应/空闲降档和框架
投票，不会、也无法凭空造出面板档位；切回原厂 LTPO 同样不会出现 199Hz（原厂
ColorOS 的刷新率枚举到 165Hz 为止，daemon 日志里就有
`ColorOS refresh setting left unchanged for unsupported Settings enum value:
199Hz`）。

## 证据

1. 原厂 DTBO（`新机型适配/一加ace6/dtbo.img`，SHA 由设备 dump 得到）里
   `qcom,mdss_dsi_panel_AA605_P_7_A0020_dsc_cmd` 只声明 5 个 timing：
   `timing@sdc_fhd_60`、`_90`、`_120`、`_144`、`_165`，没有 123，也没有
   170-199。面板 node 全量检索 `adfr` 只有 3 个 mapping 属性
   （`oplus,adfr-min-fps-mapping-table` 等），没有任何
   `qcom,mdss-dsi-adfr-min-fps-*-command`。
2. 真机上报的 HWC 模式表却多出 123 与 170-199，说明这些档位是模块写进 DTBO 的
   克隆节点（`src/process_dts.c` 的 PLQ110/PLK110 分支：复制
   `timing@sdc_fhd_165` 整块后只重写时钟、帧率、transfer-time、cell-index，
   并注入 60Hz 的 ADFR 属性）。
3. 设备 kmsg 证明 AP 侧确实切到了 199：
   `dsi_display_set_mode ... fps=199, clk_rate=1644101818`，
   `[ADFR] sa status reset: auto_mode:0,sa_min_fps:199`；
   SurfaceFlinger 侧 `defaultModeId=10 (199.00 Hz)`、
   `HWC SetActiveConfig [10], switch to [1272x2800@199]`。
4. 而用户用 TestUFO（Chrome rAF 逐帧回调）实测 Frame Rate = 165fps，
   `Pixels Per Frame 6`（960px/s ÷ 165 ≈ 6，若真是 199 应是 5），
   即应用实际拿到的垂直同步仍是 165Hz —— 正是面板上限。
5. 模块自己发现不了是因为 `wait_for_active_mode()` 校验的是 SurfaceFlinger
   请求/期望的模式，不是面板实际扫描率，所以日志一路打印
   `Active display mode verified: mode=10`。

## 后续可验证的实验（需要一台 Ace 6）

1. **读面板实际速率**：`/sys/kernel/oplus_display/test_te`（ADFR test-TE 会输出
   实测 TE 刷新率）与 `dump_info`，用它们代替 SurfaceFlinger 作为验证源；
   WebUI 已新增「实测当前刷新率」（rAF 探针）让用户/开发者现场对账。
2. **找 DDIC 高刷码**：AA605 每个 timing 的 `timing-switch-command` 都会写
   寄存器 `0x60/0x7D`：120Hz=`00/00`、144Hz=`01/02`、165Hz=`02/03`、
   90Hz=`04/01`、60Hz=`05/00`。**`0x03` 未被占用**，若面板 DDIC 存在更高档，
   最可能就藏在这套档位码里。验证方式：只给某个克隆节点换上 `0x60=0x03`
   的 timing-switch-command，用上面的实测手段比对；有花屏/黑屏立即回滚
   原厂 DTBO。
3. 若实测确认面板吃不下更高档，则 PLQ110 的 170-199 应当按「AP 时序档」标注
   或不提供，不能继续当作有效刷新率宣传。

## 本次代码改动

- WebUI：PLQ110 档位文案改为「AP 时序档：面板时序表最高 165Hz」，
  去掉「需要启用 ADFR」的错误说法；新增 rAF 实测刷新率（`panel-rate-status`
  + `btn-probe-rate`），切到高于面板上限的档位后自动实测并弹出现场对账。
- 日志脚本：新增 `display/panel_rate.txt` 取证段（oplus_display 节点实测值、
  应用态 DT 声明的 timing 列表、SurfaceFlinger 模式表与 RefreshRateSelector
  的应用可见区间），下次同类反馈可一次定位是面板没跟上还是框架限流。
