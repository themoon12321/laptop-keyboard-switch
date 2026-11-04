# 笔记本键盘开关（Laptop Keyboard Switch）

> **个人实验项目，暂不建议自行安装使用。**
>
> 当前仅有开发者个人电脑上的使用与复现记录，以及隔离环境中的软件测试。尚未在其他实体电脑或生产环境完成安装、冷启动、休眠恢复、卸载的完整验证；现有记录不代表其他硬件或系统也兼容。
>
> 本项目涉及内核键盘驱动，安装可能影响键盘输入，卸载脚本也不能保证恢复旧版本未记录的系统改动。目前公开仓库用于记录开发和交流，**不作为已验证的通用工具或生产可用版本发布，不建议他人依据本文自行安装或部署**。下述流程保留为实验记录，兼容性验证暂缓，当前优先打磨本地交互。

外接键盘叠放在笔记本上时屏蔽内置键盘，避免误触；内置键盘坏了几个键时，用其他键的长按或双击代替。

基于 AutoHotkey v2、AutoHotInterception 和 Interception。支持 Windows x86/x64；ARM64 不支持。内核驱动需要管理员权限及重启，不同厂商和安全设置的兼容性需要真机验证。

## 实验流程（暂不建议自行安装）

1. 下载分发 ZIP 并解压到固定的可写文件夹。
2. `diagnose.cmd` 检查环境和本机设备；断开外接键盘对比，确认内置设备。
3. `setup.cmd` 安装。新驱动只绑定选定的内置 PnP 设备；已有驱动直接复用。不明确的设备需要通过参数指定，不盲选唯一 USB 键盘。
4. 重启，然后 `start.cmd` 打开面板。首次正常直通、替代功能关闭，先确认内置设备再启用功能。
5. 验证外接正常、内置可屏蔽/恢复后，再自行启用替代规则和开机启动。

完整说明：[安装与卸载](docs/INSTALL.md)、[输入异常恢复](docs/RECOVERY.md)、[第三方许可](THIRD_PARTY.md)。

## 本地功能与操作说明

- **暂停内置输入 / 允许内置输入**：使用外接键盘时暂停笔记本自带键盘，避免误触；`Ctrl+Alt+K` 为默认切换快捷键。
- **录制组合键**：面板显示“正在录制”和倒计时，实时显示 Ctrl / Alt / Shift / Win 与主键组合。松开后显示“待保存”，点击“保存快捷键”才生效。Esc、取消、超时或离开面板会结束录制。录制期间临时允许内置输入并暂停旧切换快捷键，结束后恢复原状态。
- **管理替代规则**：选择已有规则直接编辑；新规则点“添加规则”。配置按哪个键、长按/双击、输入哪个键和触发时间；每条规则独立设置 **150–10000 毫秒**，旁边显示对应秒数。
- 修改后直接点击 **保存并应用**。切换规则时保留合法的编辑内容；无效时间会在面板提示，阻止保存。取消不改变已经生效的配置。
- **暂停时保留的按键**：例如暂停内置键盘时仍想使用音量键，点击“选择保留按键”，按下目标键并勾选保存；不用理解扫描码或“豁免”。
- **输入异常？停止处理并退出**：尝试释放本项目的输入订阅并退出程序，与正常允许输入的按钮区分。不能修复任意其他驱动故障。
- 新用户不继承开发者的个人映射，界面不提供恢复个人三条规则的入口；已有本地规则保留。
- 短按保留原键；长按达到阈值输入一次目标键，随后不重复输出。Shift/CapsLock 按当前布局决定字符；Ctrl/Alt/Win 快捷键优先保留原键。
- 双击窗口内暂缓单击，超时或输入其他键时放行。连续输入其他键会提前放行原键以保持顺序。
- 修饰键、锁定键和 Fn 不支持作为规则源/目标；普通 F1–F12 可以。Fn 固件模式请使用电脑厂商设置。
- 暂停内置输入时替代功能也暂停。关闭替代并允许内置输入可完全直通。

规则引擎 `app/Lib/KeyGestures.ahk` 不安装钩子、驱动或定时器，由外部提供事件发送函数和时钟；设置、设备管理和界面分离，便于复用和仿真测试。

## 安装和恢复原则

- 首次驱动安装前，记录机器身份、原始类/设备过滤器及变更归属；重复安装不覆盖原始记录。
- 新安装撤销官方安装器新增的类级键盘/鼠标绑定，仅增加选定内置设备的绑定；不在线重启设备、不修改电源和安全设置。
- 复用现有驱动时不修改其服务/绑定，卸载也保留它。
- 当前用户的原始快捷方式和自启项单独保存。提权仅用于机器层，不切换到另一账户安装用户入口。
- 卸载只撤销本项目改动；保留其他厂商的过滤器及共享驱动，发现冲突或失败时停止并保留记录。
- **全量清理**：`uninstall-all.cmd -Purge` → 重启 → `verify-uninstall.cmd` → 管理员运行 `verify-uninstall.ps1 -PurgeReceipts` → 删除项目文件夹。详见安装文档。
- 旧版未保存真正的安装前快照，不能承诺还原此前被覆盖的状态；按旧版迁移章节处理。

运行配置 `app/KeyboardToggle.ini`、`app/KeyGestures.ini`、日志和 PID 不进入 Git 或新分发包；新默认配置放在 `app/Defaults/`，已有本地配置不覆盖。设备缓存仅用于原电脑，新设备和新片段要求重新确认。

## 边界与验证状态

应用订阅前和输入/定时输出时核对设备身份；断线重连后重新识别。保存用户期望状态，设备暂失不覆盖它。订阅失败回滚，释放失败保留归属并报告未确认状态。

开启替代时内置键盘输入经过回调再发送，需要真机验证输入法、多媒体键、连续打字、蓝牙/2.4G、休眠和重连。AHI 的 Subscribe 内部会开启其上下文过滤，`SetState(false)` 不能修复任意其他软件或驱动故障。首次人工识别可能临时非阻断观察多个键盘；确认后只对保存的内置设备应用功能。

新安装/卸载流程已加入隔离测试，但尚未在干净 Windows 机器完成真实驱动安装与两次重启验收。本机现有驱动和设备配置没有为本轮开发而重新安装，不能以仿真结果替代硬件兼容性结论。

## 开发、测试与打包

```powershell
.\app\AutoHotkey\AutoHotkey64.exe /ErrorStdOut /validate app\KeyboardToggle.ahk
.\app\AutoHotkey\AutoHotkey64.exe /ErrorStdOut tests\sim.ahk
.\app\AutoHotkey\AutoHotkey64.exe /ErrorStdOut tests\gestures.ahk
.\app\AutoHotkey\AutoHotkey64.exe /ErrorStdOut tests\shortcut-capture.ahk
powershell -NoProfile -ExecutionPolicy Bypass -File tests\dryrun.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\install-state.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\install-lifecycle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\user-install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Release.ps1
```

测试使用假驱动、假注册表和隐藏界面，不安装真实驱动或模拟真实输入。打包采用文件白名单，输出 `dist/KeyboardToggle-YYYYMMDD.zip` 和包内 SHA-256 清单，不包含个人配置、设备缓存、测试数据或历史修复脚本。源码历史中的早期本机配置仍保留用于开发回溯，不能把完整 Git 历史当作纯净分发包。

初始版本标签：`baseline-2026-10-26`；开发分支：`feature/key-gestures`。没有自动选择自有代码的开源许可证，公开复用前由仓库所有者决定；第三方组件分别遵守其许可。
