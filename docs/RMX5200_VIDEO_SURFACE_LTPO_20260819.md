# RMX5200 视频 Surface 与自制 LTPO 实测

日期：2026-08-19

## 现象

Telegram 播放硬件解码视频时，前台 Activity 仍是
`org.telegram.messenger/.DefaultIcon`，但 Pixelworks MEMC Hook 没有建立
`VIDEOSTART` 会话。自制 LTPO 只看到低 GPU 提交，于是按空闲路径执行
`120 -> 60 -> 30 -> 10 -> 1Hz`，视频画面期间会掉到 1Hz。

截图对应的 SurfaceFlinger 层为：

```text
SurfaceView[org.telegram.messenger/org.telegram.messenger.DefaultIcon]
SurfaceView[org.telegram.messenger/org.telegram.messenger.DefaultIcon](BLAST)
```

## 修复

付费 `rate_daemon_premium` 新增通用视频 Surface 探测：

- 每 500ms 以当前前台包为范围扫描 `dumpsys SurfaceFlinger --list`。
- 发现 `SurfaceView[<foreground-package>/` 后暂停 LTPO 空闲降档。
- 播放期间最低保持同分辨率原生 60Hz；用户上限高于 60Hz 时不主动把当前高刷降下来。
- 取消未完成的降档事务，避免旧的 1Hz receipt 在视频开始后抢回面板。
- Surface 消失后保留 1.8s 迟滞，再从原 LTPO 阶梯恢复；释放时重新设置
  `last_activity_ms`，不会永久锁在 120Hz。

该逻辑不包含 Telegram、抖音或哔哩哔哩专用判断，普通第三方播放器和
浏览器的硬件解码 `SurfaceView` 也走同一条路径。

## 真机闭环

设备：RMX5200 / SM8850 / Android 16 / dtbo / 自制 LTPO。

本地构建的付费 daemon：

```text
6a0d29e21aa70570f1551fab48d2d8c6a1ab4236f60c443010e6a68e07f339fe
```

第二版（补充 Surface 结束后的活动基准重置）构建并整机重启后：

```text
4208b2c37c7959afc931fa4ce4a4a8edbd094864e877c9c9afa135b89ffc6c4f
```

设备端运行中的二进制哈希与第二版一致。

Telegram 播放期间日志：

```text
RMX5200 video SurfaceView detected: package=org.telegram.messenger
```

同时没有新的 `idle drop submitted ... -> 1Hz`，物理提交保持 `120Hz`。
退出播放后：

```text
RMX5200 video SurfaceView ended: package=org.telegram.messenger age=~2.1s
```

设备正常回到 Telegram 会话页，未出现黑屏、花屏或触摸失效。

## 后续验证边界

抖音和哔哩哔哩包已确认安装，代码路径已覆盖；本轮尚未在其具体视频页面
逐个点击播放并采集帧率 CSV。下一轮应分别记录播放、暂停、退出三种状态，
并确认视频 Surface 消失后的 1.8s 迟滞是否符合体感。
