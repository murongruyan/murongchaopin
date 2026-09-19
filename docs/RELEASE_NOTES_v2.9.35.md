# v2.9.35 更新内容

1. 修复「打开王者荣耀 → 侧滑出游戏助手 → 点超级帧率 → 再点原始帧率」之后开始的黑闪。

   真机抓到的链路：关闭插帧后，厂商的 AP-scale / scale_up 映射表会残留在插帧时的
   123Hz 档，SurfaceFlinger 里任何 144fps 的解析（连 `default` 投票也是）都会被指向
   `mode 11`（1080x2352@123）：

   ```
   18:32:42.526  requestRefreshRate insert [version-3-window-animation_4, 144]
   18:32:42.526  updateBestFrameRate [... {fps=144, modePtr={id=11, vsyncRate=123.00}}]
   18:32:42.526  RES::setDrawingSize 1440x3136 -> 1080x2352 → HWC[11] 1080x2352@123
   18:32:42.542  applyRefreshRateSelectorPolicy: 4 (144Hz) → 拉回 1440x3136@144
   18:32:42.630  delete [version-3-window-animation_4] → updateBestFrameRate [default,
                 {fps=144, modePtr={id=11, vsyncRate=123.00}}] → 再次切到 1080x2352
   ```

   面板就这样在 `1440x3136@144` 与 `1080x2352@123` 之间来回切，两秒内出现 21 次跨组
   切换，肉眼即黑闪。

2. 投票过滤补丁（动画投票 NOP + AP-scale 分支旁路）不再只服务 `stock_ltps` 与
   `custom_ltpo`：`adfr_off`（完美禁用 ADFR）同样接入。它也是固定刷新率方案，同样会
   被这张 stale 映射表拖走；补丁自带源码契约校验，机型或系统版本不匹配时仍会
   `skipped` / `rejected`，不会挂上错误二进制。

3. 测试同步更新：`tests/check_surfaceflinger_ltps_vote_patch.sh` 现在要求 `adfr_off`
   被接受，且产出与 `stock_ltps` 完全相同的补丁字节；`custom_ltpo`（未开日常 LTPO）
   与拼写错误的策略仍必须被拒绝。

4. 内置 daemon 版本同步至 2.9.35。
