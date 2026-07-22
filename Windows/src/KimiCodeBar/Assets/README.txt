KimiCodeBar 资源图标说明
========================

本目录下的 `icon.ico` 与 `trayTemplate.png` 为**占位资源**，由构建脚本
（generate_assets.py，纯 Python 生成蓝色方块）产出，仅用于让
Package.appxmanifest / KimiCodeBar.csproj 的清单引用有效。

请将其替换为正式设计资源：

- `icon.ico`    ：应用图标，建议包含 16/32/48/64/128/256 等多种尺寸，
                  透明背景，主色 Kimi 蓝 (#3B82F5)。
- `trayTemplate.png`：托盘小图标，建议 32x32，单色/高对比，
                  用于在任务栏通知区域显示。

替换后无需修改工程文件（文件名保持一致即可）。
