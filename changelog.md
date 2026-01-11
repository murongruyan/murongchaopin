# 更新日志
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
