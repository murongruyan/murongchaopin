# ColorOS 17 RMX5200 LTPO 完整排查（2026-09-26）

目标：让 AE084（真我 GT8 Pro 的 LTPS 面板）在 ColorOS 17 上实现**物理低刷**
（面板真的降到 1~30Hz，不是只让框架报数字）。

## 结论：六处叠加，最后一环没有调用方

| 环 | 问题 | 证据 / 状态 | 提交 |
|---|---|---|---|
| ① | AE084 的 DTBO 节点**零 ADFR 属性**（同板 AC180 有完整一套） | 注入后 `adfr_config` `0x0`→`0xe51`，内核按表真发 DSI | `fa7961d` |
| ② | 内屏无 EDID → DRM VRR 范围 `0/0` | Kretprobe KO 写 `monitor_range` 后 `1/144` 且开机后持久 | `02378c1` `1ac06ff` |
| ③ | `post-fs-data.sh` 的 QSync 使能被写在 **`exit 0` 之后**，从未执行 | 移前一行后 `appRequest` `[120,120]`→`[0,120]`，并报出 `mSupportedRefreshRates=[144…28.8]` | `3c6f84f` |
| ④ | daemon 的 OTI 策略把框架窗口拉回 `[120,120]` | 纯测试开关停 daemon 后恢复 `[0,120]` | `5102824` `c9b4775` |
| ⑤ | SF 有两道 `config->type==1` 门 | 补丁点与语义均已反汇编确认 | — |
| ⑥ | **驱动 idle 的路径在 C17 上没有任何调用方** | 穷举 `/system/framework/*.jar`、`/vendor`、`/odm`、`/system/lib64`、`/system/bin` 全部 0 命中，只有 SF 自己有 `setIdleModeExternal` 字符串 | ❌ **唯一断点** |

## 面板侧：AE084 的低刷是 DDIC 自主行为

用 `dri/0/DSI-1/tx_cmd`（格式 `0xNN 0xNN …`，每次 `echo` 发一条完整 DSI 包）
在纯测试环境下逐条实测，**全部无可见变化**：

| 候选 | 值 | 结果 |
|---|---|---|
| `0x68`（原生档位寄存器） | `10` | 无 |
| `b7` 帧周期表 `0x0c-0x0f` | `2500` / `12000` | 无 |
| `b7 0x10-0x1f`（20/10/8/6Hz） | `12000` | 无 |
| `0x09bd` | `05`/`0b`/`77`/`00` | 无 |
| `0x09be` / `0x09bc` | `77` | 无 |
| AOD 命令组 | 原值 | 仅亮度 + DCS `0x38` |

结论：`a9 01 00 2f` 的档位索引只有 4 组（0=144/1=120/2=90/3=60），
越界写（如 `04`）会被 DDIC 照单执行 → gamma 被写坏 → 偏色，**切档即复原**；
`b7` 那张含 60/20/10/8/6/4.8Hz 的帧周期表**不是给主机调的**，是 DDIC 自主使用。

`nolp` 里的 DCS `0x38` = Enter Idle Mode —— 低刷由"系统停止送新帧"触发。

## 内核侧：把 Range 和 Capability 都给了

```
struct drm_connector            display_info   @ 0x0d8   (BTF)
struct drm_display_info         monitor_range  @ 0x09a
struct drm_monitor_range_info   min_vfreq      @ 0x000   u16 Hz
                                max_vfreq      @ 0x002   u16 Hz
=> connector + 0x172 / + 0x174
```

`vrr_range_show()` 读的就是这两个字段（内屏无 EDID 所以是 0）。
一次性写在 connector probe 时会被驱动重填冲掉，必须用 **kretprobe 在
`sde_connector_fill_modes` 返回处重写**（实测 `observed=52 applied=7`）。
`vrr_capable` 属性必须在 **workqueue 进程上下文**挂载 —— 在 kretprobe 里调用
`drm_connector_attach_vrr_capable_property()` 会因 `kmalloc(GFP_KERNEL)`+
取锁触发 `drm_mode_object_add` WARN（已修）。

## SF 侧：两道 type 门与"没人调用"

```
函数 A @0x42f62c  ATRACE="setIdleModeExternal"
  42f66c: cmp w8,#1 ; b.ne 0x42f6b4     ; type!=1 → 干活
  落到 0x42f674: log "black hole mode now, dismiss setLdileModeExternal"; return 2

函数 B @0x42f7d0  ATRACE="setLTMStatus"
  42f818: cmp w8,#1 ; b.ne 0x42f86c     ; type!=1 → 干活（0x42f86c 转发 idle 给 HAL）
  落到 0x42f820: log "black hole mode now, dismiss setLTMStatus"; return

模块的 TYPE_GUARD_OFFSET=4388892(=0x42F81C) 原 81020054 → 补丁 1f2003d5(nop)
```

**注意**：模块注释说是 `setIdleModeExternal`，但 `0x42F81C` 实际在**函数 B
（`setLTMStatus`）**里；而 `setIdleModeExternal` 的门（`0x42f670`，字节
`21020054`）**从未被动过**。且从语义看，把 `b.ne` nop 掉会让函数 B
**永远走"丢弃"分支，真活 0x42f86c 永不执行** —— 与注释意图相反。

**实机验证**：把 `0x42F81C` 还原成 `81020054` 后重启，
`idleScreenRefreshRateConfig` **仍然是 null**，显示正常。
即**这门打不打都一样** → 反证整条路径**处于休眠、无人调用**。

## 唯一断点与解法

`setIdleModeExternal` 在整个 ColorOS 17 上**没有调用方**。因此只能由模块自己当：

```
付费 hook（已在 system_server）
  → 屏幕空闲时通过 binder 调 SF
  → 让函数 A 的 0x42f6e0 / 函数 B 的 0x42f86c 那条路被走到
  → 该路 ld r x0,[x19,#0x1a8]; ldr x8,[x9,#0xa8]; blr x8  把 idle 转给 composer HAL
  → 驱动停送新帧 → DDIC 按 b7 表物理降到 4.8~20Hz
```

## 工具链（已全部跑通）

```
WSL: /home/murongruyan/kernel-sm8850-common-6.12.23       内核树
     /home/murongruyan/kernel-out-6.12.23-plus-ext        输出+Module.symvers
     /home/murongruyan/toolchains/clang19                 编译器
     /home/murongruyan/llvmshim                           符号链接 shim（须含 *.real）
     注意：WSL 的 /tmp 每次调用会被清空，shim 与产物必须放持久路径

构建:  PATH=$SHIM KERNEL_TREE=… KERNEL_OUT=… KERNEL_SYMVERS=…
       sh src/ko/build.sh rmx5200-vrr-range
CRC:   python work/device_crc_map.py     (从设备 /vendor_dlkm 模块读 __versions)
       python work/patch_crc.py <contract> <outdir> <ko>
```

## 曾走错并纠正的判断（记录以免重走）

- SF 哈希"过期"：错。量到的是 bind mount 后的补丁版；模块 `contract-source` 对的是原厂哈希，基准正确。
- libsdmclient 哈希"过期是活缺陷"：错。模块根本不 patch 这个库（脚本/启动链 0 引用），只是文档陈旧。
- `TYPE_GUARD_OFFSET` 一度算成 `0x42F5BC`：正确是 `0x42F81C`。
- 在 kretprobe 处理函数里调 `drm_connector_attach_vrr_capable_property()`：非法上下文，已改 workqueue。
