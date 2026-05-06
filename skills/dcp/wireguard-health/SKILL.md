---
name: dcp-wireguard-health
description: "Monitor and auto-heal the WireGuard mesh tunnel connection to DCP."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, wireguard, networking, mesh, tunnel, self-heal]
---

# DCP WireGuard Health

Monitor the WireGuard mesh tunnel and automatically reconnect if it drops.

## What this skill does

The DCP network uses WireGuard to create a secure mesh between the VPS (76.13.179.86) and all provider machines. This skill monitors the tunnel and fixes it if it breaks.

## Check tunnel status

### macOS
```bash
# Check if WireGuard interface exists
ifconfig utun | grep -A5 "utun" 2>/dev/null
# Or check wg-quick
sudo wg show 2>/dev/null || echo "WireGuard not running"
```

### Windows
```powershell
# Check WireGuard service
Get-Service WireGuardTunnel* | Select-Object Name, Status
# Or check interface
wg show 2>$null
```

### Linux
```bash
sudo wg show wg0
```

## Health checks
1. **Interface exists**: Is the WG interface up?
2. **Handshake recent**: Last handshake < 3 minutes ago?
3. **Ping VPS**: Can we reach 10.8.0.1 (the VPS gateway)?
4. **Latency acceptable**: Ping < 500ms?

```bash
# Quick health check
ping -c 1 -W 3 10.8.0.1 && echo "TUNNEL OK" || echo "TUNNEL DOWN"
```

## Auto-heal actions
If tunnel is down:
1. Try `wg-quick down wg0 && wg-quick up wg0`
2. If that fails, check if WireGuard config exists at `~/.dcp/wg0.conf`
3. If config missing, re-register with `POST /api/providers/wg/register`
4. Report status to DCP backend

## Cron schedule
Check every 30 seconds. Auto-heal on failure. Report to backend every 5 minutes.
