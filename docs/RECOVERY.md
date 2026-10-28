# 输入异常时恢复

正常卸载与可验证清理见 [INSTALL.md](INSTALL.md)。不要首先删除程序目录：卸载所需的官方工具和记录仍在其中。

1. 仍能使用鼠标或外接键盘时，托盘选择「紧急恢复键盘」，或在项目目录运行：

   ```powershell
   .\app\AutoHotkey\AutoHotkey64.exe .\app\KeyboardToggle.ahk release
   ```

   32 位 Windows 使用 AutoHotkey32.exe。此操作仅请求本项目退出，不能修复任意其他软件或驱动故障。

2. 随后运行 `uninstall-all.cmd -Purge`；失败时保留 `machine.json` 和 `machine-error.txt`，不要通过删除整个 UpperFilters 值来尝试修复。该列表可能包含系统和其他厂商驱动。
3. 若全部输入都不可用，进入 Windows 恢复环境/安全模式，优先使用安装前系统还原点或受信任的系统恢复手段。不要在不清楚设备和驱动归属时盲删 `kbdclass`、`mouclass`、服务或驱动文件。恢复环境中的盘符和注册表配置单元可能与正常系统不同，本项目不提供会猜测目标的离线删除脚本。
4. 能正常启动后完成卸载、重启，再运行 `verify-uninstall.cmd` 检查。

源码包和 ZIP 都不能保证所有厂商设备兼容。首次在新机器验证驱动前，应保留能访问恢复环境的方式及重要文件备份。
