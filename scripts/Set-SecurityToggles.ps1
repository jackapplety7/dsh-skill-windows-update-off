<#
.SYNOPSIS
    Turn Microsoft Defender real-time protection and the Windows Firewall off (or back on).

.DESCRIPTION
    Uses only supported, reversible switches:

      Defender   HKLM\SOFTWARE\Policies\Microsoft\Windows Defender -> DisableAntiSpyware
                 plus Set-MpPreference -DisableRealtimeMonitoring
      Firewall   Set-NetFirewallProfile -All -Enabled False/True

    It does NOT uninstall Defender. Tools such as "Defender Uninstaller" take ownership of
    Defender's service and files and delete them; that is unsupported, survives poorly
    across Windows updates, and can leave the machine unable to re-enable protection.
    This script stays on the supported path so -Action Enable actually restores things.

    Defender policy changes are honoured only while Tamper Protection is off, and the
    policy value needs a reboot in most builds. The script reports Tamper Protection so
    the operator knows why a change may not have taken effect.

.PARAMETER Action
    Status (default), Disable, Enable, or Revert (restore the newest backup).

.PARAMETER Target
    All (default), Defender, or Firewall.

.EXAMPLE
    .\Set-SecurityToggles.ps1 -Action Status

.EXAMPLE
    .\Set-SecurityToggles.ps1 -Target Firewall -Action Disable

.NOTES
    Everything except Status needs an elevated shell.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Disable', 'Enable', 'Revert')]
    [string]$Action = 'Status',

    [ValidateSet('All', 'Defender', 'Firewall')]
    [string]$Target = 'All',

    [string]$BackupDir = (Join-Path $env:LOCALAPPDATA 'dsh-skill-windows-update-off')
)

$ErrorActionPreference = 'Stop'

$SCRIPT = 'security-toggles'
$DEFENDER_KEY = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DefenderPolicy {
    try {
        $item = Get-ItemProperty -LiteralPath $DEFENDER_KEY -Name 'DisableAntiSpyware' -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $null }
        return [int]$item.DisableAntiSpyware
    } catch { return $null }
}

function Set-DefenderPolicy {
    param([int]$Value)
    if (-not (Test-Path -LiteralPath $DEFENDER_KEY)) { New-Item -Path $DEFENDER_KEY -Force | Out-Null }
    New-ItemProperty -LiteralPath $DEFENDER_KEY -Name 'DisableAntiSpyware' -Value $Value `
        -PropertyType DWord -Force | Out-Null
}

function Get-DefenderStatus {
    $out = [ordered]@{ policy = (Get-DefenderPolicy); available = $false; realtime = $null; tamper = $null; antivirus = $null }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $out.available = $true
        $out.realtime = $mp.RealTimeProtectionEnabled
        $out.tamper = $mp.IsTamperProtected
        $out.antivirus = $mp.AntivirusEnabled
    } catch {
        $out.available = $false
    }
    return $out
}

function Get-FirewallStatus {
    try {
        $profiles = Get-NetFirewallProfile -ErrorAction Stop
        return @($profiles | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Enabled = [bool]$_.Enabled } })
    } catch { return @() }
}

function Write-Backup {
    param([hashtable]$Payload)
    if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $file = Join-Path $BackupDir ('{0}-backup-{1}.json' -f $SCRIPT, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    ([ordered]@{ script = $SCRIPT; createdAt = (Get-Date).ToString('o'); kind = 'security-toggles' } + $Payload) |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

function Show-Status {
    $d = Get-DefenderStatus
    $f = Get-FirewallStatus
    Write-Output 'Security toggles:'
    Write-Output ''
    Write-Output '  Microsoft Defender'
    Write-Output ('    DisableAntiSpyware policy : {0}' -f $(if ($null -eq $d.policy) { '(not set)' } else { $d.policy }))
    if ($d.available) {
        Write-Output ('    real-time protection      : {0}' -f $d.realtime)
        Write-Output ('    antivirus enabled         : {0}' -f $d.antivirus)
        Write-Output ('    tamper protection         : {0}' -f $d.tamper)
        if ($d.tamper -eq $true) {
            Write-Output '    note: Tamper Protection is ON — policy changes are ignored until it is turned off in Windows Security.'
        }
    } else {
        Write-Output '    (Defender module not available on this machine)'
    }
    Write-Output ''
    Write-Output '  Windows Firewall'
    if ($f.Count -eq 0) { Write-Output '    (could not query firewall profiles)' }
    foreach ($p in $f) { Write-Output ('    {0,-10} {1}' -f $p.Name, $(if ($p.Enabled) { 'ON' } else { 'OFF' })) }
}

# ---------------------------------------------------------------- main

switch ($Action) {
    'Status' { Show-Status; exit 0 }

    'Revert' {
        if (-not (Test-Admin)) { Write-Output 'error: Revert needs an elevated shell.'; exit 2 }
        $latest = Get-ChildItem -LiteralPath $BackupDir -Filter "$SCRIPT-backup-*.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { Write-Output "error: no backup under $BackupDir"; exit 1 }
        $saved = Get-Content -LiteralPath $latest.FullName -Raw | ConvertFrom-Json
        if ($saved.defenderPolicy -ne $null) { Set-DefenderPolicy -Value ([int]$saved.defenderPolicy) }
        foreach ($p in $saved.firewall) {
            try { Set-NetFirewallProfile -Profile $p.Name -Enabled ([bool]$p.Enabled) -ErrorAction Stop } catch { }
        }
        Write-Output ("restored from {0}" -f $latest.FullName)
        Show-Status
        exit 0
    }

    default {
        if (-not (Test-Admin)) {
            Write-Output 'error: changing these settings needs an elevated shell (Run as administrator).'
            Write-Output "hint: Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$PSCommandPath','-Action','$Action','-Target','$Target'"
            exit 2
        }

        $d = Get-DefenderStatus
        $f = Get-FirewallStatus
        $backup = Write-Backup -Payload @{ defenderPolicy = $d.policy; firewall = @($f) }

        $disable = ($Action -eq 'Disable')

        if ($Target -in 'All', 'Defender') {
            Set-DefenderPolicy -Value $(if ($disable) { 1 } else { 0 })
            if ($d.available) {
                try {
                    Set-MpPreference -DisableRealtimeMonitoring $disable -ErrorAction Stop
                } catch {
                    Write-Output ('  warning: Set-MpPreference failed ({0}) — Tamper Protection is likely on.' -f $_.Exception.Message)
                }
            }
        }

        if ($Target -in 'All', 'Firewall') {
            $enabled = -not $disable
            try {
                Set-NetFirewallProfile -All -Enabled $enabled -ErrorAction Stop
            } catch {
                Write-Output ('  warning: could not change the firewall: {0}' -f $_.Exception.Message)
            }
        }

        Write-Output ("applied: {0} -> {1}" -f $Target, $(if ($disable) { 'disabled' } else { 'enabled' }))
        Write-Output ''
        Show-Status
        Write-Output ''
        Write-Output ("backup: {0}" -f $backup)
        Write-Output ("undo:   {0} -Target {1} -Action Revert" -f $PSCommandPath, $Target)
        if ($disable) {
            Write-Output 'WARNING: real-time protection and/or the firewall are now off. Re-enable them when the task is done.'
        }
        exit 0
    }
}
