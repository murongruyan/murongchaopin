# 更新日志
## v2.6
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
- 适配“1+12”修改 DTBO, 删除原有的60和90hz，电池解容至6000mah，修复cell-index排序问题。
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
