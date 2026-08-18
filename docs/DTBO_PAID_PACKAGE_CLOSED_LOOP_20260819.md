# DTBO 付费组件闭环记录

## 问题

RMX5200 使用 `dtbo` 后端时，服务器已发布的 1.0.3 组件外层兼容矩阵只声明了 `drm`，客户端因此得到 `no_compatible_package`。将设备切换到 DRM-KO 才能下载不是正确修复，会改变用户当前后端并破坏 DTBO 闭环。

## 修复

- 生产发布记录 `id=4 / 1.0.3 / version_code=4` 的 `supported_backends` 补为 `["drm", "dtbo"]`。
- 付费包 ZIP、整包 SHA-256 `6df563772511860e4c0cd3a1abb9988239d5a854107da78234f323441f2de948`、签名 manifest 和 payload 不变。
- 下载令牌响应回传服务器实际 `supported_backends`。
- 客户端数组解析器修复：`["drm","dtbo"]` 的逗号必须保留为分隔符，之前误删逗号会把多个后端拼成一个值，从而再次误报不兼容。
- 客户端仅在已认证下载令牌明确授权 `dtbo`，且 release ID 与整包 SHA 完全匹配时，建立一次性兼容桥，允许旧签名 manifest 的 DTBO 下载；普通未授权包仍严格拒绝。
- 成功安装或失败清理后删除兼容桥文件。

## 2026-08-19 真机闭环结果

首次在设备保持 `dtbo` 时返回 `no_compatible_package`，确认是服务端发布记录的后端矩阵问题，不是授权失效，也没有执行 DRM-KO 切换。

随后仅对生产记录 `id=4 / version=1.0.3 / version_code=4 / status=published / file_sha256=6df563772511860e4c0cd3a1abb9988239d5a854107da78234f323441f2de948` 执行受限更新，将 `supported_backends` 改为 `["drm", "dtbo"]`。数据库回读和下载令牌均确认包含 `dtbo`。

客户端第一次下载已成功但在签名 manifest 兼容性检查处报 `display backend not supported`，根因为多项 JSON 数组解析误判；修复解析器并推送到设备后，真实结果为：

```text
backend=dtbo
status=downloading
version=1.0.3
version_code=4
Success: paid package staged
sha256=6df563772511860e4c0cd3a1abb9988239d5a854107da78234f323441f2de948
Notice: accepting server-authorized DTBO compatibility bridge for signed 1.0.3 manifest
Success: paid package installed; a full reboot is required
```

完整 `adb reboot` 后验收：

```text
model=RMX5200
soc=SM8850
kernel=6.12.23-android16-5-gb2a876903b49-ab14541642-4k
backend=dtbo
package version=1.0.3
package version_code=4
package sha256=6df563772511860e4c0cd3a1abb9988239d5a854107da78234f323441f2de948
override=cleared
rate_daemon_premium=running
```

重启后再次查询返回 `status=current / version=1.0.3 / version_code=4`。整个过程未改写 `dts_backend`，未加载 DRM-KO，未修改付费包 payload 或签名 manifest。

## 真机验收标准

设备必须保持：

```text
model=RMX5200
soc=SM8850
kernel=6.12.23-android16
dts_backend=dtbo
```

完整 `adb reboot` 后执行 `sh /data/adb/modules/murongchaopin/scripts/web_handler.sh auth_install_latest`，应返回 `status=updated`、`version=1.0.3`、`version_code=4`。不得出现 DRM-KO 加载或后端切换。

## 后续

拿到生产包私钥后重新生成双后端签名 manifest，客户端移除本过渡桥；在此之前不得把 `drm` 单独当成 RMX5200 DTBO 的兼容条件。
