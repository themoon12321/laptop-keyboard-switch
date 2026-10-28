# 第三方组件

项目使用以下独立许可的组件，随附许可文件不能移除。此项目没有重新许可它们，也不声称拥有这些二进制的签名或驱动支持能力。

| 组件 | 上游与许可 |
| --- | --- |
| AutoHotkey v2 | https://github.com/AutoHotkey/AutoHotkey ，GPL；完整文本在 `app/AutoHotkey/license.txt` |
| AutoHotInterception（封装及托管 DLL） | https://github.com/evilC/AutoHotInterception ，MIT，见 `licenses/AutoHotInterception-MIT.txt` |
| Interception（原生库及驱动安装器） | https://github.com/oblitum/Interception ，上游区分库、非商业使用和商业许可；见上游 README 与 `licenses/Interception-LGPL-3.0.txt` |
| CLR.ahk | 随 AHI 封装使用的 CLR 桥接脚本，保留原文件及上游来源；许可归属应随上游版本核验 |

Interception 上游列出的商业授权条件适用于相关组件；不要据此宣称整个分发包可无条件用于商业用途。库源代码与许可参考：https://github.com/oblitum/Interception/tree/master/library ，https://github.com/oblitum/Interception/tree/master/licenses 。

`scripts/Build-Release.ps1` 为包内每个文件生成 SHA-256 清单，供核对完整性；哈希不等于数字签名或上游发布证明。当前仓库保留的第三方二进制并非本项目自行编译，首次公开正式发行前还应核验其上游版本和再分发条件。

本仓库自有代码暂未单独指定开源许可证；上传到 GitHub 不等于授予他人开源使用权。若要面向公众发布，仓库所有者应先选择自有代码的许可证。
