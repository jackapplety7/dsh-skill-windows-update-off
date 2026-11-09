<#
.SYNOPSIS
    Block (or restore) Windows Update: services, policies and the update orchestrator tasks.

.DESCRIPTION
    Native re-implementation of what "Windows Update Blocker" (Wub) toggles:

      services   wuauserv, dosvc, WaaSMedicSvc, UsoSvc, InstallService  -> Start=4
      policies   NoAutoUpdate, AUOptions, DisableWindowsUpdateAccess, ...
      tasks      \Microsoft\Windows\UpdateOrchestrator\*, \Microsoft\Windows\WindowsUpdate\*

    Every run backs up the previous values to a timestamped JSON file under
    %LOCALAPPDATA%\dsh-skill-windows-update-off\ and re-reads what it wrote.

    This is a security-relevant change: with updates blocked the machine stops receiving
    fixes. It is fully reversible with -Mode Enable or -Mode Revert.

.PARAMETER Mode
    Status (default, read-only), Disable, Enable, or Revert (restore the newest backup).

.PARAMETER BackupDir
    Where backups are written.

.EXAMPLE
    .\Disable-WindowsUpdate.ps1 -Mode Status

.EXAMPLE
    .\Disable-WindowsUpdate.ps1 -Mode Disable

.NOTES
    Everything except Status needs an elevated shell.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Disable', 'Enable', 'Revert')]
    [string]$Mode = 'Status',

    [string]$BackupDir = (Join-Path $env:LOCALAPPDATA 'dsh-skill-windows-update-off')
)

$ErrorActionPreference = 'Stop'

$SCRIPT = 'windows-update'
$SERVICES = @(
    @{ Name = 'wuauserv'; Default = 3; Label = 'Windows Update' },
    @{ Name = 'dosvc'; Default = 2; Label = 'Delivery Optimization' },
    @{ Name = 'UsoSvc'; Default = 2; Label = 'Update Orchestrator' },
    @{ Name = 'WaaSMedicSvc'; Default = 3; Label = 'Update Medic (protected)' },
    @{ Name = 'InstallService'; Default = 3; Label = 'Microsoft Store Install' }
)
$TASK_PATHS = @(
    '\Microsoft\Windows\UpdateOrchestrator\',
    '\Microsoft\Windows\WindowsUpdate\'
)
$POLICIES = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate'; On = 1; Off = 0 },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'AUOptions'; On = 1; Off = 0 },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DisableWindowsUpdateAccess'; On = 1; Off = 0 },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DoNotConnectToWindowsUpdateInternetLocations'; On = 1; Off = 0 },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetDisableUXWUAccess'; On = 1; Off = 0 }
)

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ServiceStart {
    param([string]$Name)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    try { return [int](Get-ItemProperty -LiteralPath $key -Name Start).Start } catch { return $null }
}

function Set-ServiceStart {
    param([string]$Name, [int]$Value)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $key)) { return $false }
    try {
        Set-ItemProperty -LiteralPath $key -Name Start -Value $Value -Type DWord -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-PolicyValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $null }
        return $item.$Name
    } catch { return $null }
}

function Set-PolicyValue {
    param([string]$Path, [string]$Name, [int]$Value)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Write-Backup {
    param([hashtable]$Payload)
    if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $file = Join-Path $BackupDir ('{0}-backup-{1}.json' -f $SCRIPT, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    ([ordered]@{ script = $SCRIPT; createdAt = (Get-Date).ToString('o'); kind = 'windows-update' } + $Payload) |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

function Get-Snapshot {
    $svc = @{}
    foreach ($s in $SERVICES) { $svc[$s.Name] = Get-ServiceStart -Name $s.Name }
    $pol = @{}
    foreach ($p in $POLICIES) { $pol["$($p.Path)|$($p.Name)"] = Get-PolicyValue -Path $p.Path -Name $p.Name }
    $tasks = @{}
    foreach ($path in $TASK_PATHS) {
        $items = Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue
        foreach ($t in $items) { $tasks["$($t.TaskPath)$($t.TaskName)"] = $t.State }
    }
    return @{ services = $svc; policies = $pol; tasks = $tasks }
}

function Show-Status {
    $snap = Get-Snapshot
    Write-Output 'Windows Update state:'
    Write-Output ''
    Write-Output '  services (Start: 2=auto, 3=manual, 4=disabled)'
    foreach ($s in $SERVICES) {
        $v = $snap.services[$s.Name]
        $state = switch ($v) { 2 { 'auto' } 3 { 'manual' } 4 { 'DISABLED' } default { 'missing' } }
        Write-Output ('    {0,-16} {1,-8} {2}' -f $s.Name, $state, $s.Label)
    }
    Write-Output ''
    Write-Output '  policies'
    foreach ($p in $POLICIES) {
        $v = $snap.policies["$($p.Path)|$($p.Name)"]
        Write-Output ('    {0,-45} {1}' -f $p.Name, $(if ($null -eq $v) { '(not set)' } else { $v }))
    }
    Write-Output ''
    Write-Output '  scheduled tasks'
    if ($snap.tasks.Count -eq 0) { Write-Output '    (none found)' }
    foreach ($k in ($snap.tasks.Keys | Sort-Object)) {
        Write-Output ('    {0,-70} {1}' -f $k, $snap.tasks[$k])
    }
    Write-Output ''
    $blocked = ($snap.services['wuauserv'] -eq 4)
    Write-Output ("verdict: Windows Update is {0}" -f $(if ($blocked) { 'BLOCKED (wuauserv disabled)' } else { 'not blocked' }))
}

function Apply-Disable {
    $before = Get-Snapshot
    $backup = Write-Backup -Payload @{ services = $before.services; policies = $before.policies; tasks = $before.tasks }

    foreach ($p in $POLICIES) { Set-PolicyValue -Path $p.Path -Name $p.Name -Value $p.On }

    $svcResults = @()
    foreach ($s in $SERVICES) {
        $ok = Set-ServiceStart -Name $s.Name -Value 4
        if ($ok) {
            try { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue } catch { }
        }
        $svcResults += [pscustomobject]@{ Name = $s.Name; Applied = $ok; Now = (Get-ServiceStart -Name $s.Name) }
    }

    $taskResults = @()
    foreach ($path in $TASK_PATHS) {
        foreach ($t in (Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue)) {
            $ok = $true
            try { Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null } catch { $ok = $false }
            $taskResults += [pscustomobject]@{ Task = "$($t.TaskPath)$($t.TaskName)"; Disabled = $ok }
        }
    }

    Write-Output 'Windows Update blocked:'
    foreach ($r in $svcResults) {
        $state = switch ($r.Now) { 4 { 'disabled' } 2 { 'auto' } 3 { 'manual' } default { 'missing' } }
        Write-Output ('  {0,-16} {1,-10} verified: {2}' -f $r.Name, $state, ($r.Now -eq 4))
    }
    foreach ($r in $taskResults) { Write-Output ('  task {0,-66} disabled: {1}' -f $r.Task, $r.Disabled) }
    Write-Output ''
    Write-Output ("backup: {0}" -f $backup)
    Write-Output ("undo:   {0} -Mode Enable" -f $PSCommandPath)
    Write-Output 'note: WaaSMedicSvc is protected by Windows and may stay at manual — report it, do not fight it.'
}

function Apply-Enable {
    foreach ($p in $POLICIES) { Set-PolicyValue -Path $p.Path -Name $p.Name -Value $p.Off }
    foreach ($s in $SERVICES) {
        Set-ServiceStart -Name $s.Name -Value $s.Default | Out-Null
    }
    foreach ($path in $TASK_PATHS) {
        foreach ($t in (Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue)) {
            try { Enable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null } catch { }
        }
    }
    try { Start-Service -Name wuauserv -ErrorAction SilentlyContinue } catch { }
    Write-Output 'Windows Update restored to defaults (services -> auto/manual, policies -> 0, tasks enabled).'
    Show-Status
}

# ---------------------------------------------------------------- main

switch ($Mode) {
    'Status' { Show-Status; exit 0 }

    'Revert' {
        if (-not (Test-Admin)) { Write-Output 'error: Revert needs an elevated shell.'; exit 2 }
        $latest = Get-ChildItem -LiteralPath $BackupDir -Filter "$SCRIPT-backup-*.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { Write-Output "error: no backup under $BackupDir"; exit 1 }
        $saved = Get-Content -LiteralPath $latest.FullName -Raw | ConvertFrom-Json
        foreach ($name in $saved.services.PSObject.Properties.Name) {
            $v = $saved.services.$name
            if ($null -ne $v) { Set-ServiceStart -Name $name -Value ([int]$v) | Out-Null }
        }
        foreach ($key in $saved.policies.PSObject.Properties.Name) {
            $path, $polName = $key -split '\|', 2
            $v = $saved.policies.$key
            if ($null -eq $v) {
                Remove-ItemProperty -LiteralPath $path -Name $polName -ErrorAction SilentlyContinue
            } else {
                Set-PolicyValue -Path $path -Name $polName -Value ([int]$v)
            }
        }
        foreach ($taskName in $saved.tasks.PSObject.Properties.Name) {
            $state = $saved.tasks.$taskName
            if ($state -eq 'Ready' -or $state -eq 'Running') {
                $tn = Split-Path $taskName -Leaf
                $tp = Split-Path $taskName -Parent
                try { Enable-ScheduledTask -TaskName $tn -TaskPath "$tp\" -ErrorAction Stop | Out-Null } catch { }
            }
        }
        Write-Output ("restored from {0}" -f $latest.FullName)
        Show-Status
        exit 0
    }

    default {
        if (-not (Test-Admin)) {
            Write-Output 'error: changing Windows Update needs an elevated shell (Run as administrator).'
            Write-Output "hint: Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$PSCommandPath','-Mode','$Mode'"
            exit 2
        }
        if ($Mode -eq 'Disable') { Apply-Disable } else { Apply-Enable }
        exit 0
    }
}
