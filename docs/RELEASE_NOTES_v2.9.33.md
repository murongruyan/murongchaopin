# v2.9.33 更新内容

1. 修复 RMX5200 面板周期性黑闪/亮闪与 dpi 抖动：屏幕静止约 5 秒后，厂商 OTI 会投出
   60Hz 票，而 SurfaceFlinger 的 OTI 暂停（transaction 22015）是易失状态 —— 面板模式
   切换、厂商 MEMC 释放 screen-rate 投票、息屏亮屏都会把它丢掉，daemon 却只读自己写的
   `config/adfr_lock/oti_pause_last`，状态一致时直接短路，于是再也不补发。结果是面板在
   `1440x3136@165` 与 `1080x2352@60` 之间每约 5 秒来回切一次，UI 的 `sw` 也在
   `411dp`/`309dp` 之间跳，看起来就是「dpi 在闪」。
2. OTI 暂停改为约 0.5 秒一次的心跳保活，并在每次面板模式事务成功后立即补发，
   不再让 daemon 自己的状态文件自证 SurfaceFlinger 侧是否还持有暂停。
3. 触摸抬起后的补发不再只限自定义 LTPO：关闭 ADFR（`config/rmx5200_adfr_mode.txt=off`）
   时自定义 LTPO 并不启用，而厂商 OTI 恰好是抬手后约 1.5 秒投票，原条件让最常见的
   固定刷新配置完全没有这层保护。
4. 构建流程修正：免费版 daemon 改为在 CI 中由 `src/rate_daemon.c`（`-DMURONG_FREE_BUILD`，
   aarch64 静态）现场编译并强制打入模块包，不再依赖仓库里提交的 `bin/rate_daemon` 旧产物；
   发版构建会校验包内 daemon 版本与 `module.prop` 一致，并断言免费构建不含付费专属代码。
5. 内置 daemon 版本同步至 2.9.33。
