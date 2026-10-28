<#
.SYNOPSIS
    Stops and removes the scheduled task created by Install-Task.ps1. Run as Administrator.
#>
param([string]$TaskName = 'PIA qBittorrent Port Sync')

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Remove-Item (Join-Path $PSScriptRoot 'qbt-credential.xml') -ErrorAction SilentlyContinue
Write-Host "Removed scheduled task '$TaskName'."
