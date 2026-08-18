# RMX5200 AE084 DVT02 低刷 timing 审计

更新时间：2026-08-11

## 结论

RMX5200 当前不能只靠修改 `qcom,mdss-dsi-panel-framerate` 追加 30/10/1Hz。
AE084 的四个原生 WQHD timing 使用相同 porch 和 PHY，但各自携带不同的 DDIC
on-command 与 timing-switch-command；Pixelworks 侧又只有 8 个 live timing slot。
新节点若不同时处理 Iris timing 匹配，会在 `iris_update_panel_timing()` 中匹配失败并
回退到 slot 0，而不是 WQHD60 的 slot 2。

因此运行时实验必须同时满足：

1. 从真实 WQHD60 parsed mode 克隆私有 DSI 数据，保留其 1.1136GHz 时钟、6800us
   transfer time、PHY 和 DDIC command set。
2. 让 Iris 对低刷实验显式复用 WQHD60 slot 2，不能依赖未命中时的 slot 0 回退。
3. 先把新 mode 当作 scheduler/HWC 低帧实验；只有物理 TE/R1 证据确认后，才能称为
   面板物理 30/10/1Hz 或自定义 LTPO。

## 活动 AE084 timing

数据来自当前活动 DTBO 的两份 entry：

- `work/rmx5200-active-dtbo-audit-20260811/dtbo_dts/dtb_temp.0.dts`
- `work/rmx5200-active-dtbo-audit-20260811/dtbo_dts/dtb_temp.1.dts`

两份 entry 的下表字段、command 长度和 SHA-256 完全相同。

| Hz | cell-index | live clock | transfer | porch H/V | PHY |
|---:|---:|---:|---:|---|---|
| 60 | 2 | 1,113,600,000 | 6800us | H 16/2/16, V 28/2/78 | `00 2f 0c 0c 1e 1b 0c 0d 0c 02 04 00 26 11` |
| 90 | 1 | 1,113,600,000 | 9000us | 同上 | 同上 |
| 120 | 0 | 1,452,000,000 | 6800us | 同上 | 同上 |
| 144 | 3 | 1,452,000,000 | 6800us | 同上 | 同上 |

60/90 的活动 DTS timing 中没有独立 `panel-clockrate` 属性，但 live driver timing 表
已将二者解析为 1,113,600,000Hz。不能用 120/144 的 1.452GHz 假定替代。

| Hz | on-command | timing-switch-command |
|---:|---|---|
| 60 | 2842 bytes, `e4a49e2e08c2a9b431a8ead66befa70edd7fb1f2e0cd6796fc06e30d0dc294dd` | 571 bytes, `288da1584a31d653a1d66cedee8e114aa02f583ff6c0ecd82a63a1cee0c25160` |
| 90 | 2842 bytes, `97a6937a67bca6a336ece90a9ddd4eb55835c48c9e74c4381156f9d020bae9b8` | 571 bytes, `246f31a30eca69ac9a75fffd865c04a99934aac3f0ec094d174970f95fc9beca` |
| 120 | 2842 bytes, `3a1a2a101cb8c40e175eabffb01173a5a0d4545fe7a3f3941cd82a62c5e89ee0` | 571 bytes, `17f8e85acb8bcf9c8d9f8811efe516ae3bb25e2ee5249893cca3c25b3516c35f` |
| 144 | 2842 bytes, `5df41c778abfdb8e0996881830e2abf3a04433da73d80d11fc1fbfff7a78f0ca` | 571 bytes, `08b6744f98594b84101b37769993f96d8395c10a5896be32fc6d50f9a15e907a` |

四档 on-command 均为 188 个 DSI packet，其中 19 个 packet 的 payload 随档位变化；
timing-switch-command 均为 20 个 packet，其中 packet 0、14、18 随档位变化。差异包含
完整的 E1/E2 查找表和 A9 timing payload，不是单个 fps 数字。因此不能从 60Hz blob
直接猜出 AE084 的 30/10/1Hz DDIC payload。

## Pixelworks live timing 表

只读模块 `rmx5200_iris_timing_probe.ko` 调用 msm_drm 正式导出的
`iris_get_cmd_list_cnt()` 和 `iris_get_timing_info()`，没有调用任何 set/update/send/tx
接口。真机回读：

| slot | 分辨率 | fps | clock | transfer | timing-cmd-map |
|---:|---|---:|---:|---:|---:|
| 0 | 1440x3136 | 120 | 1,452,000,000 | 6800us | `0xff` |
| 1 | 1440x3136 | 90 | 1,113,600,000 | 9000us | `1` |
| 2 | 1440x3136 | 60 | 1,113,600,000 | 6800us | `0` |
| 3 | 1440x3136 | 144 | 1,452,000,000 | 6800us | `0xff` |
| 4 | 1440x3136 | 123 | 1,488,300,000 | 6634us | `4` |
| 5 | 1440x3136 | 150 | 1,512,500,000 | 6528us | `3` |
| 6 | 1440x3136 | 155 | 1,562,916,666 | 6317us | `2` |
| 7 | 1440x3136 | 160 | 1,613,333,333 | 6120us | `5` |

`cmd_list_count=6`、`timing_count=8`。固件原始属性为：

```text
panel-te = 120
ap-te = 120
timing-cmd-map = ff 01 00 ff 04 03 02 05
master-timing-cmd-map = 00 00 00 00 02 02 02 02
iris-fps-switch-sequence = 00 15 00 05 00 01 05 f9 00 04 e1 00 11 e5 00
```

活动 DTBO 已有 12 个 WQHD mode，但 Iris 表只覆盖前 8 个；165/170/175/180 不在
表内。对设备当前 `msm_drm.ko` 的反汇编确认，`iris_update_panel_timing()` 逐项比较
width、height 和 fps，未找到时把索引置 0，随后读取
`timing-cmd-map[index]`。这同样适用于未来追加的低刷节点。

调用点会从当前 parsed mode 复制一个 0x38-byte 的临时 timing 到栈上，其中
`width@0x0`、`height@0x10`、`fps@0x20`。因此实验 KO 只需在
`iris_update_panel_timing()` 进入时把该栈副本的 30/10/1 临时映射为 60，返回时
恢复原值；无需修改共享 parsed mode，也不能把 parsed mode 的 `refresh@0x2c` 错当成
Iris 入参 ABI。

探针 SHA-256 为
`13cf14afb50f44cf1f4b91a6a89fa84a30c7458165550123f10a1037d339dd53`。
探针已卸载，`/data/local/tmp` 临时文件已删除；本阶段未刷 DTBO、未切显示 mode。

## 下一步实验边界

- 第一阶段只发布 30/10/1 三个可卸载 runtime mode，不一次加入 10 到 1 的全部档位。
- 每个低刷 mode 克隆 WQHD60，Iris 匹配临时引导到 slot 2；卸载 KO 必须恢复原 mode
  数组、connector 列表和 Iris 输入。
- 切换顺序固定为 60 -> 30 -> 60、60 -> 10 -> 60、60 -> 1 -> 60。任一阶段出现
  黑屏、触摸不恢复、热重启或 TE 异常，立即停止后续档位。
- SurfaceFlinger 显示 1Hz 只能证明 scheduler mode 生效。必须再记录面板 TE、Iris
  timing index/command map 和 DSI 发送路径，才能判定是否达到物理 1Hz。

## 运行时断点

- 低刷 KO probe-only 已确认 QHD60 parsed source index 为 2，12-mode ABI 的 refresh
  字段是 `0x2c`；这与 Iris 栈 timing 的 `fps@0x20` 是两个不同结构。
- 直接运行时追加能让 DRM connector 出现 30/10/1，但已经启动的 QTI composer 不会
  刷新 HWC config。必须由 `post-fs-data` 早期加载并整机重启，不能重启 composer/SF
  后继续沿用旧 Launcher input channel。
- 早期加载后 HWC 已原生枚举 QHD 1/10/30。当前 `iris_update_panel_timing` Hook 在一次
  30Hz 切换中没有命中，所以 slot 2 引导仍未闭环。只读 switch probe 已覆盖 13 个
  实际候选入口，待用户肉眼确认浮层和触摸后重跑 30Hz 路径。

## 触摸状态机当前基线

- 正式 KO SHA-256：
  `ce32a5b450cb418bcfcb203ffb9988e3d36f715f9d795deb4683c670ea7825c8`。
- 正式 daemon SHA-256：
  `7ab9e83b1b989dea3b9c181dac09e7d1aae4bb36d4152fb77ec747d582e3bc4c`。
- 下降 dwell：120Hz 保持 3000ms，60Hz 保持 350ms，30Hz 保持 400ms，10Hz 保持
  250ms，再进入 1Hz。真机 `60 -> 30` 观测约 0.40-0.45s。
- 后续不允许通过重启 composer 或 SurfaceFlinger 装载新实验：该流程会使 Launcher
  保留失效 input channel，出现桌面仍在绘制但触摸无响应。必须写入
  `I_UNDERSTAND_AE084_LTPO_RUNTIME_TEST_ONCE`、同步落盘并整机重启。

## libsdmclient timeline A/B（排除项）

原厂 `/vendor/lib64/libsdmclient.so` SHA-256 为
`714493f26a1ec67eba2887fa0dbd6c8a0d0a12449f05f4fcd6967c0854b736a6`。tracefs 证明
1Hz 旧周期下，初始 `EstimateVsyncPeriodChangeTimeline` 和
`SubmitActiveConfigChange` 内第二次 Estimate 都返回
`appliedTime = earliestTime + 1000000000ns`；Iris ready 检查没有阻塞 Submit。

三轮真机 A/B 结果：

| 修改范围 | SHA-256 | 结果 |
|---|---|---|
| 仅初始 timeline | `6589fb802f0dd87b1ad99d338e5ac04df62ed9b003d499ef84f3319839a3e1e3` | 初始 applied 已清零，`1 -> 120` 仍约 3.14s |
| 仅 Submit timeline | `c1ef4da5a83363e2d72966d1e70c9254ba63013a862563f490430cc45f1fd5a4` | Submit applied 已清零，`1 -> 120` 仍约 3.24s |
| 两份 timeline 同改 | `21eaefdb1f1576a21f45d52bba295af2ab65f38a302375a493afd6fa3a6ee0aa` | 两份 applied 都等于 earliest，QHD120 仍约 3.23s，且 applied-mode 认知错位、下降节奏失效 |

因此 `EstimateVsyncPeriodChangeTimeline` 的返回值不是实际升档延迟根因，正式启动链已
移除 `libsdmclient_timeline_patch.sh` 的 `apply/mark-boot-success` 调用。2026-08-11 整机
重启回读原厂库哈希一致，KO 为 `12 -> 15`、注入 3 档、`touch_boost_ready=Y`，设备保持
`1440x3136/560` 与 `mode.txt=QHD+ 120`。下一步追踪 SF commit 之前的 scheduler 唤醒及
Finalize 之后的 DRM/DSI 实际 mode switch，不再改两份用户态 timeline 返回。
