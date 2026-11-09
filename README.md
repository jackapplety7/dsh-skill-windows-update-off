# 关闭 Windows 更新 + Defender/防火墙开关（DSH Skill）

把常用的两个 Windows「关更新」工具合成一个可安装、可回滚的 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) Skill：

| 原来用 | 现在用 | 做法 |
|---|---|---|
| `Wub.zip`（Windows Update Blocker 1.8，Sordum） | `scripts/Disable-WindowsUpdate.ps1` | 原生改 5 个服务、5 条策略、2 组计划任务 |
| `Defender_Uninstaller.exe`（Raymond.cc 1.2） | `scripts/Set-SecurityToggles.ps1` | 策略 + `Set-MpPreference` 关实时保护，`Set-NetFirewallProfile` 关防火墙 |

两个脚本都是 `Status / Disable / Enable / Revert` 四态，幂等，改前自动备份到
`%LOCALAPPDATA%\dsh-skill-windows-update-off\`，改后**回读校验**，并打印一行回滚命令。

> 仓库**不打包任何第三方 exe**：它们要么改服务权限（难以撤销），要么直接删 Defender 服务
> （微软不支持，大版本更新后大概率出问题）。这里只走系统支持的开关。

## 安装

```powershell
git clone https://github.com/jackapplety7/dsh-skill-windows-update-off.git "$env:USERPROFILE\.dsh\skills\windows-update-off"
```

装完重启 DSH，技能列表里会出现 `windows-update-off`。之后直接说：

> 帮我把 Windows 更新关掉，顺便把 Defender 实时保护和防火墙也关了

## 用法

```powershell
# 只读：看当前状态
.\scripts\Disable-WindowsUpdate.ps1 -Mode Status
.\scripts\Set-SecurityToggles.ps1  -Action Status

# 关 Windows 更新（管理员）
.\scripts\Disable-WindowsUpdate.ps1 -Mode Disable

# 关 Defender 实时保护 + 防火墙（管理员）
.\scripts\Set-SecurityToggles.ps1 -Target All -Action Disable

# 只关其中一项
.\scripts\Set-SecurityToggles.ps1 -Target Firewall -Action Disable

# 恢复
.\scripts\Disable-WindowsUpdate.ps1 -Mode Enable
.\scripts\Set-SecurityToggles.ps1  -Action Enable
```

免手动开管理员窗口：

```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','.\scripts\Disable-WindowsUpdate.ps1','-Mode','Disable'
```

## 到底改了什么

### Windows 更新

| 层 | 内容 |
|---|---|
| 服务 | `wuauserv`、`dosvc`、`WaaSMedicSvc`、`UsoSvc`、`InstallService` → `Start=4`（禁用） |
| 策略 | `NoAutoUpdate=1`、`AUOptions=1`、`DisableWindowsUpdateAccess=1`、`DoNotConnectToWindowsUpdateInternetLocations=1`、`SetDisableUXWUAccess=1` |
| 计划任务 | `\Microsoft\Windows\UpdateOrchestrator\*`、`\Microsoft\Windows\WindowsUpdate\*` 全部禁用 |

⚠️ `WaaSMedicSvc`（更新医生）受系统保护，管理员也经常改不动——脚本会如实报失败但继续执行。
Wub 之所以能一直压住它，是靠**改服务权限**；本仓库不做这件事，因为权限改动很难干净还原。
**版本更新后它可能把其它服务重新拉起来，重新跑一次 `-Mode Disable` 即可。**

### Defender / 防火墙

| 项 | 关 | 开 |
|---|---|---|
| Defender | `DisableAntiSpyware=1` + `Set-MpPreference -DisableRealtimeMonitoring $true` | 反向 |
| 防火墙 | `Set-NetFirewallProfile -All -Enabled False` | `True` |

Defender 这条策略**只有在「篡改防护」关闭时才生效**，且多数版本要重启；脚本会打印篡改防护状态，
别在它显示 `True` 时承诺已经关掉。

> 注意：`Defender_Uninstaller` 是**卸载**（接管服务、删文件），本技能只做**可逆的关闭**。
> 想彻底删除请自行使用原工具，并清楚它不受微软支持。

## 安全提醒

关掉更新 = 不再收到安全补丁；关掉 Defender/防火墙 = 失去实时防护。三项都是安全降级，
做完任务请 `-Mode Enable` / `-Action Enable` 恢复。仓库作者不对后果负责。

## 兼容性

- Windows 10 / 11（x64、ARM64），PowerShell 5.1 与 7
- 需要管理员权限（`Status` 除外）
- 企业/WSUS 托管环境里域策略优先，本脚本可能无效

## License

[MIT](LICENSE)
