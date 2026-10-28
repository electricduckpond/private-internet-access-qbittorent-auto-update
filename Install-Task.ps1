<#
.SYNOPSIS
    Installs Sync-PiaQbtPort.ps1 as a hidden scheduled task that starts at logon.
    Run from an elevated (Administrator) PowerShell.

.EXAMPLE
    .\Install-Task.ps1
    .\Install-Task.ps1 -QbtUrl http://localhost:9090 -NoCredential
#>
[CmdletBinding()]
param(
    [string]$QbtUrl = 'http://localhost:8080',

    # Skip the credential prompt (use when qBittorrent bypasses auth for localhost).
    [switch]$NoCredential,

    [int]$IntervalSeconds = 30,

    [string]$TaskName = 'PIA qBittorrent Port Sync'
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Sync-PiaQbtPort.ps1'
$credFile = Join-Path $PSScriptRoot 'qbt-credential.xml'

if (-not $NoCredential) {
    Write-Host 'Enter your qBittorrent Web UI username and password.'
    Write-Host '(Saved encrypted with Windows DPAPI - only your Windows account on this PC can read it.)'
    Get-Credential -Message 'qBittorrent Web UI login' | Export-Clixml -Path $credFile
} elseif (Test-Path $credFile) {
    Remove-Item $credFile
}

$taskArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -QbtUrl `"$QbtUrl`" -IntervalSeconds $IntervalSeconds"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew
# Run as the logged-in user so the DPAPI credential file can be decrypted.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description 'Keeps the qBittorrent listening port in sync with the PIA forwarded port.' -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "Installed and started scheduled task '$TaskName'."
Write-Host "Log file: $(Join-Path $PSScriptRoot 'sync.log')"
