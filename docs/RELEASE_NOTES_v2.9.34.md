# v2.9.34 更新内容

1. 修复一加 Ace 6（PLQ110）刷入后无法开机：PLQ110 的内核注入路径属于未真机验证状态，而 Ace6 内核是 `CONFIG_PANIC_ON_OOPS=y` + `PANIC_TIMEOUT=-1`（panic 后不会自动重启），KO 里一次坏指针或校验命中就是永久 panic。现在 PLQ110 默认不再加载任何注入用内核模块，回到已真机验证可用的 DTBO + props 方案；只有安装器按音量键选择 DRM-KO、或在 WebUI 切到「DRM-KO」并确认风险时才允许注入。
2. 新增开机自保护（防砖）：post-fs-data 记录本次 boot_id，service.sh 在系统启动完成并稳定后记录同一个 boot_id；下次开机若发现上一次没走完，就自动跳过全部内核模块注入（付费侧退回 props 方案）并在 module.prop / WebUI 显示提示。
3. WebUI 切换到 DRM-KO 时对 PLQ110 增加风险确认弹窗；安装器选择 DRM-KO 时打印同样的提示。
4. 内置 daemon 版本同步至 2.9.34。
