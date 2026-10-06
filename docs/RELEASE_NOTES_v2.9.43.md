# 慕容显示增强 v2.9.43

本版修的是「明明有授权却显示未授权、想重新绑定卡密又被拒」这个问题——它和显示效果无关，
是**设备身份被改掉之后，模块每次重新推导身份**造成的。

## 一、现象

用户（PLK110 / ColorOS 17 / 模块 2.9.42）反馈：本机租约还在有效期内，但 WebUI 显示「未授权」；
点「输入卡密绑定」，弹出「绑定失败：授权状态冲突 或 请求已处理」。

## 二、根因（逐字节可验证）

模块解析设备身份的顺序是 `ro.serialno` → `ro.boot.serialno`，**而且每次调用都重新解析、并覆盖缓存文件**。
反馈包里这台机器的实际值：

```
ro.serialno                    = 5inKbvQAalccHUj      ← 与 ro.boot.chipecid 相同（随机串）
ro.boot.chipecid               = 5inKbvQAalccHUj
ro.boot.serialno               = 3B16590023L00000    ← 硬件序列号，没变
ro.vendor.oplus.radio.serialno = 3B16590023L00000
vendor.oplus.caihong.serialno  = 3B16590023L00000
```

也就是说这台机器上有**设备 ID 伪装类工具**改写了 `ro.serialno` / `ro.boot.chipecid`
（更早的 LSPosed props 快照里 `ro.boot.chipecid` 还是正常的高通十六进制值 `0000046a474cd898`）。于是：

- 绑定当时（10-03）模块读到的是 `3B16590023L00000`，其哈希 `sha256("3b16590023l00000")` =
  租约里的 `device_id_hash` `85ea2b14…`（**逐字节吻合**）；
- 属性被改之后模块读到 `5inKbvQAalccHUj`，哈希对不上 → 本地租约被判成「绑定到另一台设备」→ 未授权；
- 用户再点绑定 → 服务端已有 active 绑定且设备对不上 → 409「授权状态冲突或请求已处理」。

## 三、修复

1. **身份钉住**：`config/auth/device_id.txt`（文件头注释本来就写着 OTA-stable）一旦写入即**只读复用**，
   只有文件缺失或损坏时才重新推导并落盘。此前它每次都被覆盖，等于没有缓存。
2. **多候选校验**：租约 claim 只要命中「钉住值 / 硬件序列号 / 各属性候选」中的**任意一个**即视为本机。
   已经漂移过的老用户不用重新绑定就能恢复。
3. **新身份的来源改为 `ro.boot.serialno` 优先**：引导器写入的序列号，只改 `ro.serialno` 的伪装工具动不了；
   sysfs 的 SoC 序列号（`/sys/devices/soc0/serial_number`）与其余属性进入候选集。之所以不把 sysfs 放第一位，
   是因为它虽然最难伪造，但 App 与服务端既有记录都不用这个值，新设备绑上去反而会与生态里的身份不一致。
4. **漂移留痕**：身份不一致时向 `runtime/device_identity.log` 写一行（同一对只记一次）；
   `device_info` 新增 `identity_candidates` / `identity_hashes` / `lease_claim_matches_this_device`，
   以后这类问题从日志一眼可见。
5. 服务端查询（权益、付费包）带上第二身份候选（`sn`），使「绑定早于属性变化」的记录仍能被匹配到。

## 四、真机验证（RMX5200 / ColorOS 17）

在临时目录里模拟「身份已被伪装工具改过」（把 `device_id.txt` 写成 `5inKbvQAalccHUj`）：

| 检查项 | 结果 |
|---|---|
| 钉住的身份 | `5inKbvQAalccHUj`（保持钉住值，不再被属性带跑） |
| 派生身份 | `3B15AQ00DHW00000`（硬件序列号） |
| 候选集合 | `5inKbvQAalccHUj`, `3B15AQ00DHW00000` |
| 哈希集合 | 两者的 sha256，与模块自身口径一致（无尾随换行） |
| 硬件序列号 claim | **接受** ✓ |
| 钉住值 claim | **接受** ✓ |
| 无关哈希 | **拒绝** ✓ |
| 漂移日志 | `pinned=5inKbvQAalccHUj derived=3B15AQ00DHW00000` ✓ |

## 五、线上处置

受影响用户（user 2074 / license 86 / 卡密尾号 `KD3F`）已在管理端解绑并按当前身份重新绑定：
`binding_id=89`、`device_id_hash=39671000058c8cdd…`，与该设备模块算出的哈希一致；
用户重新打开 WebUI 刷新授权即可恢复（不需要重装模块）。

## 六、说明

- 模块侧只改了身份解析与校验，不涉及显示、超频、刷新率的任何行为。
- 如果设备上装了会改 `ro.serialno` 的工具，本版之后即使它再改，已绑定的设备也不会掉授权；
  但**首次绑定仍建议在干净状态下进行**，绑定后再开伪装工具最稳妥。
