<#
.SYNOPSIS
    Keeps qBittorrent's listening port in sync with the Private Internet Access forwarded port.

.DESCRIPTION
    Polls `piactl get portforward` every few seconds. Whenever PIA reports a forwarded port that
    differs from qBittorrent's current listening port, the port is updated via the qBittorrent Web UI API.
    Polling (instead of reacting only to PIA change events) also covers qBittorrent being restarted,
    started late, or not running at the moment PIA's port changed.

    It also keeps qBittorrent connected across PIA reconnects: when the VPN IP changes, or qBittorrent
    reports no connectivity, it makes qBittorrent reopen its listening sockets, and restarts qBittorrent
    as a last resort.

.EXAMPLE
    .\Sync-PiaQbtPort.ps1 -Once
    Runs a single check and exits (handy for testing).
#>
[CmdletBinding()]
param(
    # qBittorrent Web UI address (Tools > Options > Web UI).
    [string]$QbtUrl = 'http://localhost:8080',

    # Path to a credential file created by Install-Task.ps1 (or: Get-Credential | Export-Clixml <path>).
    # Defaults to qbt-credential.xml next to this script. If the file doesn't exist, no login is attempted
    # (for when "Bypass authentication for clients on localhost" is enabled in qBittorrent).
    [string]$CredentialFile,

    [string]$PiactlPath = 'C:\Program Files\Private Internet Access\piactl.exe',

    [int]$IntervalSeconds = 30,

    # Defaults to sync.log next to this script.
    [string]$LogFile,

    # If qBittorrent reports no connectivity for this long, reopen its listening sockets.
    [int]$RebindAfterSeconds = 60,

    # If it's still stalled this long after first stalling, restart qBittorrent (at most every 15 minutes).
    [int]$RestartAfterSeconds = 240,

    # Never restart qBittorrent; only reopen its listening sockets.
    [switch]$NoRestart,

    # Run one check and exit.
    [switch]$Once
)

# $PSScriptRoot is empty inside param() defaults when Windows PowerShell runs a script via -File.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $CredentialFile) { $CredentialFile = Join-Path $scriptDir 'qbt-credential.xml' }
if (-not $LogFile) { $LogFile = Join-Path $scriptDir 'sync.log' }

$ErrorActionPreference = 'Stop'
$QbtUrl = $QbtUrl.TrimEnd('/')
$script:Session = $null

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Write-Host $line
    try {
        # Keep the log from growing forever.
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {
        # Script folder not writable (e.g. under Program Files): fall back to %LOCALAPPDATA%.
        $fallback = Join-Path $env:LOCALAPPDATA 'PiaQbtPortSync\sync.log'
        if ($LogFile -ne $fallback) {
            New-Item -ItemType Directory -Force (Split-Path $fallback) | Out-Null
            $script:LogFile = $fallback
            Add-Content -Path $LogFile -Value $line -Encoding UTF8
        }
    }
}

function Get-PiaPort {
    $out = (& $PiactlPath get portforward 2>&1 | Out-String).Trim()
    $port = 0
    if ([int]::TryParse($out, [ref]$port) -and $port -gt 0) { return $port }
    # Inactive / Attempting / Failed / Unavailable, or the PIA client isn't running.
    return $out
}

function Invoke-Qbt([string]$Path, [hashtable]$Body) {
    $params = @{
        Uri             = "$QbtUrl$Path"
        Method          = 'Post'
        WebSession      = $script:Session
        UseBasicParsing = $true
        TimeoutSec      = 10
        # qBittorrent's CSRF protection requires Referer/Origin to match the host.
        Headers         = @{ Referer = $QbtUrl; Origin = $QbtUrl }
    }
    if ($Body) { $params.Body = $Body }
    $content = (Invoke-WebRequest @params).Content
    # Windows PowerShell returns byte[] when the response has no text content type.
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    return [string]$content
}

function Connect-Qbt {
    $script:Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    if (-not ($CredentialFile -and (Test-Path $CredentialFile))) {
        throw "qBittorrent requires a login, but there is no credential file at '$CredentialFile'. " +
              "Enable 'Bypass authentication for clients on localhost' in qBittorrent, or re-run Install-Task.ps1."
    }
    $cred = Import-Clixml $CredentialFile
    $resp = Invoke-Qbt '/api/v2/auth/login' @{
        username = $cred.UserName
        password = $cred.GetNetworkCredential().Password
    }
    # Success is "Ok." (or an empty body on some versions); bad credentials return "Fails.".
    if ($resp -match 'Fails') {
        $script:Session = $null
        throw "qBittorrent login failed. Check the username/password (re-run Install-Task.ps1)."
    }
}

function Test-Forbidden($ErrorRecord) {
    $r = $ErrorRecord.Exception.Response
    return $r -and ([int]$r.StatusCode -eq 403 -or [int]$r.StatusCode -eq 401)
}

function Get-QbtPreferences {
    # Try without logging in first: this works when qBittorrent bypasses auth for localhost,
    # and with an existing session. Only log in when qBittorrent says we're not authorized.
    if (-not $script:Session) { $script:Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession }
    try {
        return (Invoke-Qbt '/api/v2/app/preferences') | ConvertFrom-Json
    } catch {
        if (-not (Test-Forbidden $_)) { throw }
    }
    Connect-Qbt
    try {
        return (Invoke-Qbt '/api/v2/app/preferences') | ConvertFrom-Json
    } catch {
        if (Test-Forbidden $_) { throw "qBittorrent rejected the login. Check the username/password (re-run Install-Task.ps1)." }
        throw
    }
}

function Set-QbtPrefs([hashtable]$Prefs) {
    $json = $Prefs | ConvertTo-Json -Compress
    Invoke-Qbt '/api/v2/app/setPreferences' @{ json = $json } | Out-Null
}

function Reset-QbtListen([int]$Port) {
    # qBittorrent only works out the bound interface's IP address when it (re)opens its listening
    # sockets. After a PIA reconnect the VPN adapter has a new IP, so qBittorrent keeps listening on a
    # dead address. Bouncing the port forces it to reopen the sockets without ever unbinding from the VPN.
    $tmp = if ($Port -lt 65535) { $Port + 1 } else { $Port - 1 }
    Set-QbtPrefs @{ listen_port = $tmp }
    Start-Sleep -Seconds 3
    Set-QbtPrefs @{ listen_port = $Port; random_port = $false }
}

function Restart-Qbt {
    $proc = Get-Process qbittorrent -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc -or -not $proc.Path) {
        Write-Log "Can't restart qBittorrent: process not found (or running as another user)."
        return
    }
    $exe = $proc.Path
    try { Invoke-Qbt '/api/v2/app/shutdown' | Out-Null } catch { }
    # Give it time to save resume data. Never kill it, so no torrent state is lost.
    if (-not $proc.WaitForExit(120000)) {
        Write-Log "qBittorrent didn't exit within 2 minutes; not restarting."
        return
    }
    Start-Sleep -Seconds 2
    Start-Process -FilePath $exe
    $script:Session = $null
    Write-Log "Restarted qBittorrent."
}

function Test-QbtHealth($Prefs, [int]$Port) {
    $info = (Invoke-Qbt '/api/v2/transfer/info') | ConvertFrom-Json
    $status = "$($info.connection_status), DHT nodes: $($info.dht_nodes)"
    if ($status -ne $script:LastHealth) { Write-Log "qBittorrent connection status: $status" }
    $script:LastHealth = $status

    # "disconnected" means libtorrent has no working listen socket. Zero DHT nodes (with DHT on) means
    # nothing is getting in or out. "firewalled" alone is normal until the first incoming connection.
    $stalled = $info.connection_status -eq 'disconnected' -or ($Prefs.dht -and [int]$info.dht_nodes -eq 0)
    if (-not $stalled) {
        $script:StalledSince = $null
        $script:Rebound = $false
        return
    }

    if (-not $script:StalledSince) { $script:StalledSince = Get-Date }
    $stalledFor = ((Get-Date) - $script:StalledSince).TotalSeconds

    if (-not $script:Rebound -and $stalledFor -ge $RebindAfterSeconds) {
        Write-Log "qBittorrent looks stalled for $([int]$stalledFor)s; reopening its listening sockets."
        Reset-QbtListen $Port
        $script:Rebound = $true
    } elseif ($script:Rebound -and $stalledFor -ge $RestartAfterSeconds -and -not $NoRestart) {
        $sinceRestart = if ($script:LastRestart) { ((Get-Date) - $script:LastRestart).TotalMinutes } else { [double]::MaxValue }
        if ($sinceRestart -ge 15) {
            Write-Log "qBittorrent still stalled after $([int]$stalledFor)s; restarting it."
            $script:LastRestart = Get-Date
            Restart-Qbt
            $script:StalledSince = $null
            $script:Rebound = $false
        }
    }
}

function Sync-Once {
    $piaPort = Get-PiaPort
    if ($piaPort -isnot [int]) {
        if ($script:LastStatus -ne "pia:$piaPort") { Write-Log "PIA port forward not available: $piaPort" }
        $script:LastStatus = "pia:$piaPort"
        $script:StalledSince = $null
        return
    }
    $vpnIp = (& $PiactlPath get vpnip 2>&1 | Out-String).Trim()

    $prefs = Get-QbtPreferences
    if ([int]$prefs.listen_port -ne $piaPort) {
        # Changing the port also reopens the listening sockets, so this covers a reconnect too.
        Set-QbtPrefs @{ listen_port = $piaPort; random_port = $false }
        Write-Log "Updated qBittorrent listening port $($prefs.listen_port) -> $piaPort"
    } elseif ($script:LastVpnIp -and $vpnIp -ne $script:LastVpnIp) {
        Write-Log "PIA reconnected (VPN IP changed); reopening qBittorrent's listening sockets on port $piaPort."
        Reset-QbtListen $piaPort
    } elseif ($script:LastStatus -ne "ok:$piaPort") {
        Write-Log "qBittorrent already listening on PIA port $piaPort"
    }
    $script:LastVpnIp = $vpnIp
    $script:LastStatus = "ok:$piaPort"

    Test-QbtHealth $prefs $piaPort
}

if (-not (Test-Path $PiactlPath)) {
    Write-Log "FATAL: piactl not found at '$PiactlPath'. Is PIA installed somewhere else?"
    exit 1
}

Write-Log "Starting PIA -> qBittorrent port sync (qBittorrent: $QbtUrl, every ${IntervalSeconds}s)"
$script:LastStatus = ''
$script:LastHealth = ''
$script:LastVpnIp = ''
$script:StalledSince = $null
$script:Rebound = $false
$script:LastRestart = $null
while ($true) {
    try {
        Sync-Once
    } catch {
        $msg = "Error: $($_.Exception.Message)"
        # Avoid flooding the log while qBittorrent is simply closed.
        if ($script:LastStatus -ne $msg) { Write-Log $msg }
        $script:LastStatus = $msg
        $script:Session = $null
    }
    if ($Once) { break }
    Start-Sleep -Seconds $IntervalSeconds
}
