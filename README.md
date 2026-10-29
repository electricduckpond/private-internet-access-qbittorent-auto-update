# PIA → qBittorrent port forward sync (Windows)

Runs in the background and sets qBittorrent's listening port to whatever port Private Internet Access
has forwarded. It checks every 30 seconds, so it also catches PIA picking a new port after a reconnect
and qBittorrent being restarted.

### Keeping qBittorrent connected after PIA reconnects

When qBittorrent is bound to the PIA network adapter, a PIA reconnect gives that adapter a new IP.
qBittorrent can keep listening on the old IP and stall with no connections until it's restarted. The script
handles this in three steps:

1. **PIA's VPN IP changes:** it makes qBittorrent reopen its listening sockets right away. It does this by
   briefly switching the port to port+1 and back. qBittorrent never unbinds from the VPN.
2. **qBittorrent reports `disconnected` or 0 DHT nodes for 1 minute:** it reopens the sockets the same way.
3. **Still stalled after 4 minutes:** it closes qBittorrent cleanly through the Web UI and starts it again,
   at most once every 15 minutes. It never force-kills qBittorrent. Install with `-NoRestart` to turn this off.

Every connection status change is written to `sync.log`, so you can see what happened.

## 1. Set up the target PC

**PIA**
- Settings → Network (or Connection) → turn on **Request Port Forwarding**.
- `piactl` only answers while the PIA app is running. If you don't keep it open, run this once:
  `& "C:\Program Files\Private Internet Access\piactl.exe" background enable`

**qBittorrent**: Tools → Options → **Web UI**
- Tick **Web User Interface (Remote control)**. Leave the port at 8080 unless you need another one.
- Set a username and password, **or** tick **Bypass authentication for clients on localhost**.
  If you tick the bypass, add `-NoCredential` when you install.
- Optional but recommended: Options → Connection → untick **Use UPnP / NAT-PMP port forwarding from my router**.
  It doesn't help through the VPN.

## 2. Install

Copy this folder somewhere permanent (for example `C:\Tools\pia-qbt-port-sync`). Open **PowerShell as Administrator** in that folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1
```

Options: `-QbtUrl http://localhost:9090`, `-NoCredential`, `-IntervalSeconds 15`, `-NoRestart`.

This creates a scheduled task called **PIA qBittorrent Port Sync**. It starts at logon and runs hidden.
It also writes your qBittorrent login to `qbt-credential.xml`, encrypted so only your Windows account can read it.

## 3. Check it's working

```powershell
Get-Content .\sync.log -Tail 20
```

You should see a line like `Updated qBittorrent listening port 6881 -> 47123`. You can also run one check by hand:

```powershell
powershell -ExecutionPolicy Bypass -File .\Sync-PiaQbtPort.ps1 -Once
```

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\Uninstall-Task.ps1
```
