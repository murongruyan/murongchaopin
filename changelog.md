# 更新日志

## v2.9.9

1. WebUI 的基础模块更新检查改为调用服务器版本接口，统一返回模块版本、下载地址和更新说明，不再直接请求 GitHub Raw，减少 CDN 限流和缓存导致的“网络不可用”。
2. 优化 WebUI 页面切换：授权刷新改为后台缓存刷新，应用列表只在对应页面活跃时加载，列表项启用内容可见性隔离，减少切换页面时的卡顿。
3. API 102 的游戏助手与 Scene 刷新率选择改为四列平铺，并通过 root bridge 补齐同分辨率的全部刷新率节点；保留全局/应用独立设置同步。
4. 公开 Hook 与付费 Hook 的 API 102 作用域和构建检查继续隔离，新增认证流程、服务端更新契约和 Web 性能回归检查。

## v2.9.8

1. 修复 DRM-KO 安装在真实 DTBO 中因使用 overlay-only HMBIRD 扫描器而报 `no unambiguous HMBIRD target structure`；恢复使用按机型、项目 ID 和面板识别的 `process_dts --hmbird-only` 路径。
2. 修复 OnePlus 15 原厂 timing 节点缺少 `cell-index` 时的安装失败；工具现在只对缺失的 `cell-index` 自动补写，仍对时钟和帧率等关键属性严格报错。
3. 加入真实无 `cell-index` 的 PLK110 回归用例，并将模式索引检查纳入 CI。

## v2.9.7

1. 修复 WebUI 重复点击或多个页面同时启动 DTBO 应用任务时，两个后台进程共用并互删 `dtb_temp.*.dtb`，最终报 `Can not read file: dtb_temp.0.dtb` 的竞态问题。
2. DTBO 完整应用和一键超频刷写现在使用设备端原子互斥锁；已有任务运行时拒绝第二个任务并显示其 PID，任务正常结束或异常退出都会释放锁。
3. 支持自动恢复进程已不存在的陈旧锁，并加入并发拒绝、锁释放与陈旧锁恢复回归测试。
4. 修复部分 KSU WebUI 宿主重复分发触摸事件导致的重复提交；前端现在只允许一个显示写入流程同时运行，并保留第一次任务的完整日志。
5. 后端 `start_apply/start_flash` 改为幂等启动：重复请求会继续读取已有任务，不再把同一次成功流程显示为“无法启动后台任务”。

## 2026-08-18

- 风驰改为持久 DTBO-only：安装阶段写入 HMBIRD 节点，开机不再加载
  `hmbird.ko` 或执行 live-OF changeset。
- 删除 `bin/hmbird.ko`，并移除 `post-fs-data.sh` 的风驰 KO 调用；旧的
  `hmbird_backend.sh apply` 入口现在只记录 `disabled:dtbo_only`。
- 风驰节点改由独立 DTS 结构补丁器写入，不再依赖 RMX5200 识别、
  `ro.boot.prjname`、DTBO `project-id` 或显示刷新率清单；显示超频逻辑保持独立。
## v2.9.6
1. 免费底座更新安装时会迁移既有账号、签名租约和已安装付费组件；检测到有效付费授权后，自动查询并续装服务器上 `version_code` 最高的兼容付费组件，无需重新登录或输入卡密。
2. 自动续装沿用完整的整包 SHA-256、Ed25519 Manifest 签名、设备/SoC/内核/后端、目标路径和逐文件哈希校验。网络、查询、下载或校验失败只跳过续装，免费模块安装与现有付费组件均不受影响。
3. WebUI 的基础模块与付费组件更新检查改为优先比较数值版本码；付费更新弹窗新增服务器发布日志，支持多行与滚动显示。已安装组件的 `version_code` 会写入本地状态，避免同版本重复下载或反复弹窗。

## v2.9.5
1. 修复 RMX5200 原厂 LTPS 静止时错误停在 QHD170：SurfaceFlinger 现在精确过滤内部 `object-animation` 新增票，并跳过 AP-scale 旧配对表对已选 modePtr 的二次改写。
2. 修复方案不锁定 60Hz，也不硬编码刷新率或 mode ID。`QHD+ 120` 真机验证为静止 QHD60、触摸后 0.25 秒内回到 QHD120、持续滑动期间保持 120、停止后自动回到 60。
3. 补丁仅对 RMX5200 的免费 `stock_ltps` 策略生效；其他机型、付费自制 LTPO 和完美禁用 ADFR 策略均不进入该路径。当前 OTA 指令或上下文不匹配时拒绝挂载。

## v2.9.4
1. 修复 KernelSU 安装 DRM-KO 后端时报 `HMBIRD DTBO tooling is incomplete`：KernelSU 解压阶段把 native 工具设为 `0644`，现在会在任何后端执行前显式恢复必需工具的 `0755` 权限。
2. 移除只在 DTBO 分支内执行的宽泛 `chmod +x *`，DTBO 与 DRM-KO 统一使用同一份明确工具清单和失败检查。

## v2.9.3
1. 修复 KernelSU 安装界面不显示第二次后端选择提示：后端选择函数不再通过命令替换捕获输出，提示恢复到实时标准输出，选择结果改为直接写入脚本变量。
2. 保留 v2.9.2 的简单单事件音量键读取、两次选择间 1 秒等待、无超时和无默认 DTBO 行为。

## v2.9.2
1. 回退 v2.9.1 复杂的按下/抬起状态机，恢复原有单事件音量键读取方式。
2. 第一次原厂 DTBO 确认后固定等待 1 秒，再进入第二次 DTBO/DRM-KO 后端选择；仍不设置选择超时，也不会默认写入 DTBO。
3. Release 安装包改用带版本号的唯一文件名，避免固定下载 URL 在连续替换资产后被浏览器续传缓存拼接成损坏 ZIP。

## v2.9.1
1. 修复 v2.9 模块安装阶段音量键无响应：改为在同一个 `getevent` 事件流内识别一次完整的按下与抬起，避免两个短进程之间丢失抬起事件而永久等待。
2. 原厂 DTBO 基线确认与 DTBO/DRM-KO 后端选择保持为两次独立操作；两次操作均无超时和默认值，并增加按键防抖，只有第二次明确选择 DTBO 才会进入修改和刷写流程。

## v2.9
以下内容只统计相对 v2.8（提交 `ae7fc32`）的公开源码差异，不把测试结论或后续规划当作更新项。

1. 模块元数据和发布物更名为“慕容显示增强”v2.9；更新地址改为唯一资产 `Murong.Display.Enhancement.zip`。免费与授权增强改为同一模块的两种状态，公开仓库不再发布第二个安装包。
2. 新增显示后端抽象：安装阶段可选择 DTBO 或 DRM-KO；加入 `display_mode_manifest.txt`、后端探测/切换脚本，以及 RMX5200、PLK110、PJD110 的 DRM-KO 产物和对应运行时分派。PJD110 的 KO 配套 DTBO 路径在代码中保留容量与充电阈值处理。
3. `process_dts` 改为由机型清单驱动，新增 RMX5200 原生 FHD/WQHD 节点保留或隔离、扩展节点去重和重排、HMBIRD-only、PJD110 KO-support 等受互斥条件约束的处理分支；RMX5200 的 ADFR dry-run 路径明确标记为不发送物理 DSI 命令。
4. 新增独立免费 `hmbird.ko` 与加载脚本：只在 ColorOS/Realme UI 及受支持 SoC 上尝试使用动态 OF changeset，SM8850/SM8845 使用 `HMBIRD_EXT`，SM8750/SM8650/MT6991/MT6993 使用 `HMBIRD_OGKI`；不满足条件时保持 fail-closed。
5. 新增开机生命周期脚本、ColorOS 配置挂载与 Settings bridge。公开 Hook 工程增加 API 102 入口、显示模式解析、分辨率投票/物理范围桥接、Oplus 服务与 KernelSU WebUI 交互代码；授权功能代码不进入公开 APK。
6. 新增授权基础设施：公开包仅携带 Ed25519 公钥与验证器；WebUI 支持账号、卡密激活、租约刷新、可用内部组件查询和分块下载；模块端对组件执行签名、Manifest、设备/SoC/内核/后端、路径、大小和 SHA-256 校验，并以 staging/previous 目录原子切换。
7. WebUI 重构为明亮玻璃主题与悬浮底栏，增加 DTBO/DRM-KO 状态、显示策略/ADFR 控制、刷新率风险提示、全局与应用独立分辨率/刷新率选择、视频插帧配置及授权状态页面；操作由对应后端命令处理。
8. 公开打包和 CI 改为只组装一个模块 ZIP：重编译公开 DTS 工具，保留已审计的免费守护进程，显式剔除私有 LTPO/ADFR/MEMC 文件，并加入 DRM-KO、HMBIRD、低刷新率、WebUI、Web 工作区隔离和预测性返回等回归检查。

## v2.8
1. WebUI 点击"应用更改"后新增**流程日志弹窗**：不再是一次性等待整条命令（原实现 10~30 秒无反馈，易误判卡死）。后端 `web_handler.sh` 拆分为 `pack_only`（打包）→ `merge_avb`（复用官方 VBMeta 合成签名）→ `flash_final`（写入分区+回读校验）三个阶段子命令。**后台执行 + 前端流式轮询**：点击立即弹出弹窗，打包/签名/刷入全流程在后台运行（setsid），前端每 500ms 增量读取日志逐行追加（不再阻塞 UI 线程、日志像 customize.sh 一样逐行滚动），任一步失败立即中止并标红，DTBO 分区不会被修改。"刷写 DTBO"同样拆分为 提取→解包→补丁→smart_add → 打包 → 签名 → 刷入 分步日志。
2. 刷入完成弹窗改为双按钮：**🔄 立即重启** / **⏰ 稍后重启**（恢复原厂、卸载成功弹窗同样生效）。立即重启直接执行 reboot，稍后重启关闭弹窗。
3. 添加刷新率新增**折叠高级选项**：时钟频率 (clockrate, Hz) 与传输时间 (transfer-time-us, µs) 两个可选自定义输入，**输入框实时显示自动计算值**（基于基准节点按目标 FPS 等比换算），无原值时提示"留空由后端自动计算"，用户可改可清空；填写时**自定义值覆盖自动计算**（framerate 仍使用目标 FPS）。`dts_tool add`/`smart_add` 增加可选 clock/transfer 参数（缺省行为与旧版完全一致，向后兼容）。
4. "修改当前刷新率"弹窗同步支持高级选项：打开即**预填节点原值**（clockrate/transfer-time-us），修改目标 FPS 时实时按比例换算并回填（手动编辑过则尊重用户输入），解决"不知道原值不会填"的问题。
5. WebUI 表格"修改/删除"按钮间距加大、按钮尺寸加大，避免误触。
6. 修复打包日志显示 WARNING: linker 噪音（avbtool 加载 Python 扩展 .so 的 DT_RPATH 提示），打包日志展示时过滤，界面干净。
7. 修复"应用更改"误报"打包失败"：前后端成功标记统一为 `Success:` 前缀，删除失败关键词正则误伤（smart_add 输出中的"提示：…发生错误"不再误判为失败），失败弹窗保留完整日志内容。

## v2.7
1.修复 Web 刷入修改版 DTBO 后不开机（必须还原 DTBO 才能开机）的隐藏 Bug：`dtbo_write_be64` 原实现通过 `>> 56/48/40/32/...` 移位循环写入 64 位大端字段，但 Android mksh 是 32 位有符号算术，移位 ≥32 会回绕（`>>48` 被当作 `>>16`），导致 AVB footer 的 original_image_size / vbmeta_offset / vbmeta_size 三个 64 位字段全部错位（写成"4 字节值重复两次"），bootloader 按错误偏移定位 VBMeta 失败 → AVB 校验不过 → 拒启变砖。已重写为"前导 4 个 NUL + 低 32 位大端"写法（所有取值均 < 2^31），真机验证 footer 输出正确，刷入后正常开机。
2.新增合成后结构自检（防再变砖）：dtbo_apply_stock_avb 生成 dtbo_final.img 后强制回读 footer 三字段校验、VBMeta magic 校验、与官方备份逐字节 cmp，任一失败即中止刷入并提示，绝不把未验证镜像写入分区。
3.修复说明：`bin/new_dtbo.img` 是解包重打包后的裸中间产物（本就无 AVB），Web 实际刷入的是合成官方 VBMeta 的 `dtbo_final.img`；变砖根因是合成时 footer 字段写错，而非"没签名"。

## v2.6 (未发布)
1.修复超频刷新率息屏后亮屏回到 120Hz 的 Bug：rate_daemon 新增屏幕状态监测，检测到息屏（OFF/DOZE）后再次亮屏时，强制重新下发目标模式并同步系统刷新率设置，不再依赖内存缓存的短路判断。可观察 daemon.log 中的 "Screen ON after OFF/DOZE" 与 "Forced reapply after screen-on" 日志确认触发。
2.修复 WebUI "禁用 ADFR" 无效的问题：原脚本操作的属性（persist.oplus.display.vrr.adfr 等）在 GT8 Pro 上不存在（实际为 persist.oplus.display.vrr.pdfr），导致按钮空转。现改为：备份并操作真实属性（兼容新旧机型）、persist 属性持久化写入、`cmd display set-user-preferred-display-mode` 固定框架层目标模式、启用内核 ADFR 并写入 min_fps 下限，且写入状态文件，开机后由 service.sh 自动重新应用，直到点击"还原默认"。已在 RMX5200 (GT8 Pro) 真机验证禁用/还原闭环。

## v2.5
1.修复 WebUI 刷入链路：删节点/改节点后"应用更改"与"刷写 DTBO"统一走官方 AVB 信息复用（raw 复制官方 VBMeta，不自签名），AVB 处理失败时**中止刷入**并提示"请勿重启"。
2.修复 flash_dtbo 成功输出无 Success 前缀导致 WebUI 误报刷写失败的问题（前后端判断已统一）。
3.pack_dtbo 打包日志不再丢弃（保留到 pack.log），打包失败时回显具体原因。
4.WebUI 前端增强错误识别：兼容旧版模块"AVB签名添加失败"等日志，明确提示 AVB 处理失败、DTBO 分区未被修改。

## v2.4
1.修复 AVB 信息复用失败问题：官方 VBMeta 现可重定位到修改后的数据之后（4096 对齐），不再要求修改后 DTBO 必须小于官方 VBMeta 偏移；只要数据 + VBMeta + footer 不超分区大小即可正常刷入。
2.实测校验：VBMeta 与原装逐字节一致（纯 raw 复制，无自签名），数据与 footer 偏移均正确。

## v2.3
1.移植官方 DTBO 的 AVB/VBMeta/footer 复用流程，修改后的镜像无需重新生成不匹配的签名密钥。
2.安装、WebUI 刷入、恢复和卸载增加镜像大小及写回校验。
3.完善 action.sh：未检测到 KsuWebUI 时自动安装模块内置 APK，失败时给出明确提示。
4.更新 Web 致谢名单，补充傻瓜我爱你呀和小宇同学的酷安主页。

## v2.2
1.为真我GT8Pro添加风驰调速器
  - 在 process_dts.c 中添加了针对 RMX5200 (真我 GT8 Pro) 的补丁逻辑。
  - 自动在 oplus_sim_detect 节点前插入 oplus,hmbird 节点（如果不存在）。
  - 配置内容为： config_type { type = "HMBIRD_EXT"; }; 。
2.修改- 初始化改用 HWC : init_display_modes 现在使用 dumpsys SurfaceFlinger 解析 resolution 和 vsyncRate ，不再依赖不准确的 dumpsys display 。
  - 当前模式检测 : get_current_system_mode 现通过 dumpsys SurfaceFlinger | grep "activeConfig=" 直接获取当前生效的 HWC Config ID。
  - 切换指令修正 : set_surface_flinger 移除了之前的 id - 1 逻辑，现在直接使用 HWC Config ID 调用 service call SurfaceFlinger 1035 。
切换 HWC 刷新率检测 ( webroot/js/main.js )
  - 修改了 WebUI 的 loadDisplayModes 函数。
  - 现在使用 dumpsys SurfaceFlinger 替代旧的 dumpsys display ，直接从 HWC 获取 ID、分辨率和刷新率，无需 ID-1 修正。
3.移植 COPG 高效应用名显示 ( webroot/js/main.js )
  - 引入了 COPG 项目的 getPackageInfoNewKernelSU 核心逻辑。
  - 极速模式 ：优先调用 KernelSU 的 ksu.getPackagesInfo (批量 API) 或 ksu.getPackageInfo (单体 API) 获取应用名，大幅减少 Shell 调用耗时。
  - 兼容模式 ：如果 API 不可用，自动回退到原来的 pm list + Shell 脚本方式。
  - loadAppList 已重构为支持批量获取，加载速度将显著提升。

## v2.1
- 修复自定义超频检测面板显示其他刷新率的问题。
- 修复自动超频处理逻辑，解决部分情况下DTS文件生成重复节点（如两个123Hz节点）的Bug。
- 修复当前刷新率节点删除按钮无法正常工作的问题。
- 修复添加刷新率节点后，刷新页面后节点丢失的问题。
- 新增当前刷新率节点和添加新刷新率节点后的cell-index排序问题。

## v2.0
- 项目更名为 "OnePlus & Realme 修改 dtbo 模块"。
- 扩展支持范围，适配更多 OnePlus 和 Realme 机型（具体视测试情况而定）。
- 优化文件结构和说明文档。
- 适配"1+15"修改 DTBO，删除原有60，90hz，120更改为123hz，使用165添加170，175，180，185，190，195，199档位并使用165添加60来修复高挡位ltpo。
- 适配"1+12"修改 DTBO, 删除原有的60和90hz，电池解容至6000mah，修复cell-index排序问题。
- 添加无需禁用avb效验即可修改dtbo（此处致谢大肥鱼，bybycode和破星）。

## v1.1
- 修复了高帧率下的ltps和亮度问题。
- 修复了web恢复原厂dtbo未执行恢复的问题。
- 修复了web卸载此模块未还原dtbo的问题。
- 修复Web端"恢复原厂DTBO"按钮无反应及缺少提示的问题。
- 优化备份逻辑，卸载或恢复后不再删除备份文件，支持重复恢复。
- 修复Web界面顶部元素遮挡问题，增加垂直间距。
- 修复"应用更改&刷入"弹窗卡死及"刷入失败"误报问题。
- 将"初始化工作区"拆分为"扫描当前DTS"和"重新提取当前DTBO"，操作更清晰。
- 重构文件目录结构，分离Web工作区与原厂备份目录，防止误覆盖原厂备份。
- 增强错误捕获，刷入失败时显示具体错误信息。



## v1.0
- 初始版本发布。
- 支持真我GT8 Pro 123Hz、150Hz、155Hz、160Hz、165Hz、170Hz、175Hz、180Hz 等多个刷新率档位。
- 内置 WebUI 管理界面。
- 支持自定义刷新率节点（添加/删除）。
- 支持 ADFR (可变刷新率) 控制。
- 自动备份原厂 DTBO，支持一键恢复。
