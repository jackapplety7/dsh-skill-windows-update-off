---
name: windows-update-off
description: 'Use on Windows when the user wants Windows Update blocked or turned off (no automatic downloads, no forced restarts), optionally together with Microsoft Defender real-time protection and the Windows Firewall. Native PowerShell over services, policies and scheduled tasks, plus reversible security toggles: every change is backed up, re-read to verify, and has a one-command undo. It does not uninstall Defender.'
---

# Turn Windows Update off (and, if asked, Defender real-time + firewall)

Two third-party tools usually do this job on Chinese Windows machines: **Windows Update
Blocker (Wub)** and **Defender Uninstaller**. This skill reproduces what they toggle, with
the operating system's own switches, so nothing is bundled and every change can be undone.

| Goal | Script | What it touches |
|---|---|---|
| Stop Windows Update | `scripts/Disable-WindowsUpdate.ps1` | 5 services, 5 policy values, `UpdateOrchestrator` + `WindowsUpdate` tasks |
| Stop Defender real-time / firewall | `scripts/Set-SecurityToggles.ps1` | `DisableAntiSpyware` policy, `Set-MpPreference`, `Set-NetFirewallProfile` |

Both are `Status` / `Disable` / `Enable` / `Revert`, idempotent, and write a timestamped
JSON backup to `%LOCALAPPDATA%\dsh-skill-windows-update-off\` before changing anything.

## When to use

- “关掉 Windows 更新 / 不想再被强制更新和重启 / 更新老是失败卡住”
- “把自动更新关掉，我自己手动更”
- “顺便把 Defender 实时保护和防火墙也关了”（only if the user says so)

Do **not** use this skill for:

- “Defender 卸载 / 删掉 Defender 服务” — that is unsupported and destructive; explain that
  this skill only disables it reversibly, and that `Defender Uninstaller`-style removal
  survives poorly and can leave the machine unable to re-enable protection.
- “暂停更新 7 天” — that is the Settings UI, no script needed.
- Windows Server / WSUS-managed fleets — group policy there wins over local values.

## Say this before applying

Blocking updates means the machine stops receiving security fixes until it is undone.
Say so in one sentence, then run it. For Defender and the firewall, say that both are
real protections being switched off, and prefer `-Target Firewall` or `-Target Defender`
over `All` when only one is needed.

## Commands

```powershell
# read-only state
& '<skill-dir>\scripts\Disable-WindowsUpdate.ps1' -Mode Status
& '<skill-dir>\scripts\Set-SecurityToggles.ps1'  -Action Status

# block Windows Update (elevated)
& '<skill-dir>\scripts\Disable-WindowsUpdate.ps1' -Mode Disable

# turn Defender real-time and the firewall off (elevated)
& '<skill-dir>\scripts\Set-SecurityToggles.ps1' -Target All -Action Disable

# put everything back
& '<skill-dir>\scripts\Disable-WindowsUpdate.ps1' -Mode Enable
& '<skill-dir>\scripts\Set-SecurityToggles.ps1'  -Action Enable
```

Elevation, when the agent must launch it:

```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','<script>','-Mode','Disable'
```

That raises one UAC dialog — tell the user to expect it.

## What “blocked” means here

`Disable-WindowsUpdate.ps1 -Mode Disable` writes:

| Layer | Value |
|---|---|
| Services | `wuauserv`, `dosvc`, `WaaSMedicSvc`, `UsoSvc`, `InstallService` → `Start=4` (disabled) |
| Policies | `NoAutoUpdate=1`, `AUOptions=1`, `DisableWindowsUpdateAccess=1`, `DoNotConnectToWindowsUpdateInternetLocations=1`, `SetDisableUXWUAccess=1` |
| Tasks | every task under `\Microsoft\Windows\UpdateOrchestrator\` and `\Microsoft\Windows\WindowsUpdate\` disabled |

`WaaSMedicSvc` is protected by Windows (it repairs the other services). It often refuses
the change even for an administrator; the script reports it as failed and keeps going.
Real-world Wub also rewrites that service's permissions to keep it at `4` — this skill
does **not** do that, because a permission rewrite is hard to undo. Say “WaaSMedic may
re-enable things after a feature update” instead of claiming a permanent block.

Windows Update can also be re-armed by a feature update or by the Settings app's
“Resume updates” button. Re-run `-Mode Disable` after big updates.

`Set-SecurityToggles.ps1`:

- Defender: `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\DisableAntiSpyware=1` plus
  `Set-MpPreference -DisableRealtimeMonitoring $true`. Honoured only with **Tamper
  Protection off**; the policy needs a reboot. The script prints Tamper Protection state,
  so read it before promising success.
- Firewall: `Set-NetFirewallProfile -All -Enabled False` (all three profiles), reversible
  with `-Action Enable`.

## Verify

- Update: `-Mode Status` prints each service's `Start`, every policy value and the task
  states; the verdict line says `BLOCKED` only when `wuauserv` is `4`. Also open
  `Settings → Windows Update` — it should show the access-blocked message.
- Security: `-Action Status` prints the Defender policy, real-time/tamper state and the
  three firewall profiles.
- Trust the script's `verified:` columns — they re-read the values after writing.

## Revert

`-Mode Revert` / `-Action Revert` restore the newest JSON backup. `-Mode Enable` /
`-Action Enable` write Windows' default shapes instead (services auto/manual, policies 0,
tasks enabled, firewall on). Both need an elevated shell. Report the backup path so the
user can undo days later.

## Report back

In the user's language, one short block: what was blocked or switched off, what refused
(the protected `WaaSMedicSvc`, Tamper Protection), whether a reboot is needed, the backup
path, and the undo command. Never claim updates are *permanently* off.
