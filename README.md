# 真我 GT8 Pro 超频 DTBO 模块

## 简介
这是一个专为真我 GT8 Pro 设计的 KernelSU/Magisk 模块，旨在解锁屏幕刷新率限制，支持更多高刷档位。通过修改 DTBO (Device Tree Blob Overlay)，本模块可以让您的设备支持自定义的高刷新率，带来更流畅的视觉体验。

## 功能特性
- **多档位刷新率支持**：支持 123Hz, 150Hz, 155Hz, 160Hz, 165Hz, 170Hz, 175Hz, 180Hz 等多个档位（具体取决于屏幕体质和驱动支持）。
- **WebUI 管理界面**：内置功能强大的 Web 管理界面，无需复杂的命令行操作。
- **自定义配置**：
  - 支持查看当前支持的刷新率节点。
  - 支持手动添加自定义刷新率节点。
  - 支持删除不需要的刷新率节点。
- **ADFR 控制**：
  - 提供禁用/启用可变刷新率 (ADFR) 的功能。
  - 自动备份系统属性，支持一键还原默认设置。
- **安全机制**：
  - 自动备份原厂 DTBO，随时可以恢复到出厂状态。
  - 模块卸载功能。

## 安装与使用
1. **下载与安装**：
   - 在 KernelSU 或 Magisk 管理器中刷入本模块的 ZIP 包。
   - 重启手机以生效。

2. **使用管理界面**：
   - 打开 KernelSU/Magisk 应用。
   - 进入“模块”页面。
   - 找到“真我GT8Pro超频dtbo模块”。
   - 点击模块卡片上的“操作”或“WebUI”按钮（取决于管理器版本）。
   - 在弹出的 Web 界面中进行刷新率管理、ADFR 设置或恢复操作。

## 注意事项
- **风险提示**：修改屏幕刷新率和系统底层参数存在一定风险，可能导致屏幕显示异常、耗电增加或系统不稳定。请务必在操作前备份重要数据。
- **黑屏处理**：如果应用新的刷新率后出现黑屏，请尝试强制重启手机。如果问题依旧，请进入安全模式或通过 TWRP/ADB 删除本模块 (`/data/adb/modules/murongchaopin`)。
- **兼容性**：本模块专为真我 GT8 Pro 开发，其他机型请勿尝试。

## 更新日志
请查看 [update.json](https://raw.githubusercontent.com/murongruyan/murongchaopin/main/update.json) 获取最新版本信息。

## 开源协议
本项目采用 [GPL 3.0 License](LICENSE) 开源。

## 作者
- **慕容茹艳**（酷安 @慕容雪绒）

## 致谢
感谢所有为本项目提供测试和建议的朋友。
- **酷安穆远星**（http://www.coolapk.com/u/28719807）
- **GitHub开源项目**（https://github.com/KOWX712/Tricky-Addon-Update-Target-List）
- **酷安大肥鱼** (http://www.coolapk.com/u/951790)
- **酷安望月古川** (http://www.coolapk.com/u/843974)
- **qq傻瓜我爱你呀** (QQ: 3844041986)
