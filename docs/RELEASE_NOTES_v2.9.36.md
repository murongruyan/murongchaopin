# 慕容显示增强 v2.9.36

## Android 17（ColorOS 17）内核符号适配

升级到 ColorOS 17（Android 17，内核 6.12.69）后，系统重建了整个 vendor
内核，模块里内核增强组件的符号契约不再匹配，`insmod` 直接报
`disagrees about version of symbol module_layout`，相关功能静默失效。

本版加入**内核符号契约守卫**（`bin/ko_abi_guard` + `scripts/ko_abi_guard.sh`）：

- 每次开机从设备自带的 vendor 模块（`/vendor_dlkm`、`/system_dlkm`）里读出
  当前内核真实的符号表与 CRC 契约，不依赖任何写死的版本号；
- 加载每个内核增强模块前先比对契约：
  - 契约一致 → 直接加载随包模块；
  - 只是记录的 CRC 变了 → 在 `runtime/ko_abi/` 生成适配副本后加载
    （原文件不动，永远不会被改写）；
  - 契约里查不到的符号 → 去掉该符号的版本校验（内核会警告一次并接受），
    而不是强行失败；
  - 必要符号在新内核里已经不存在 → 直接跳过该模块，并在
    `runtime/ko_abi/status.txt` 与模块提示里说明原因。

也就是说，以后系统再 OTA 换内核，模块会自己重新检测，而不是整包失效或
盲目加载。

## 真机验证（RMX5200 / ColorOS 17 / 6.12.69）

- 契约检测：扫描 564 个系统模块，得到 9807 个符号契约、53780 个导出符号；
- `rmx5200_adfr_lock`：识别到 4 个 CRC 变化 + 1 个无法校验符号，自动适配后
  加载成功（`oppo_adfr_lock: loaded with deferred activation`）；
- `rmx5200_ltpo_activity`：自动适配后加载成功（`application GPU activity probe active`）；
- `rmx5200_drm_modes` / `rmx5200_ltpo_modes`：可以加载，但模块自身的运行时
  显示结构校验判定厂商显示 ABI 已变化，按设计拒绝改动内存并卸载 —— 超频与
  LTPO 模式注入在 ColorOS 17 上暂不可用，需等下一次针对新显示结构的适配版；
  期间模块只跳过该功能，不会乱改显示状态。

## 其他

- 模块提示列表新增"内核符号不匹配已安全跳过"提示，方便直接反馈；
- 守卫二进制与 daemon 一样在 CI 现场编译，避免打包旧文件；
- 新增 `tests/check_ko_abi_guard.sh` 覆盖契约一致 / 需适配 / 拒绝加载 /
  无契约回退四条路径。
