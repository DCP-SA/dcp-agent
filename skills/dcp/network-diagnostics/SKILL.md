---
name: dcp-network-diagnostics
description: "Deep network troubleshooting — DNS, firewall, MTU, latency, ISP detection."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, network, diagnostics, troubleshooting, dns, firewall, latency]
---

# DCP Network Diagnostics

Deep network troubleshooting beyond simple ping. Run when connectivity issues persist after basic self-heal.

## Quick diagnosis (run all, report results)

```bash
echo "=== DCP Network Diagnostics ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# 1. Internet connectivity
echo "--- Internet ---"
curl -sf -o /dev/null -w "api.dcp.sa: %{http_code} (%{time_total}s)\n" https://api.dcp.sa/health 2>/dev/null || echo "api.dcp.sa: UNREACHABLE"
curl -sf -o /dev/null -w "google.com: %{http_code} (%{time_total}s)\n" https://google.com 2>/dev/null || echo "google.com: UNREACHABLE"

# 2. DNS resolution
echo ""
echo "--- DNS ---"
nslookup api.dcp.sa 2>/dev/null | grep "Address" | tail -1 || echo "DNS: FAILED to resolve api.dcp.sa"
echo "DNS server: $(cat /etc/resolv.conf 2>/dev/null | grep nameserver | head -1 | awk '{print $2}')"

# 3. WireGuard tunnel
echo ""
echo "--- WireGuard ---"
sudo wg show 2>/dev/null || echo "WireGuard: NOT RUNNING"
ping -c 3 -W 2 10.8.0.1 2>/dev/null | tail -1 || echo "Gateway 10.8.0.1: UNREACHABLE"

# 4. Latency profile
echo ""
echo "--- Latency ---"
ping -c 5 -W 2 76.13.179.86 2>/dev/null | tail -1  # VPS direct
ping -c 5 -W 2 10.8.0.1 2>/dev/null | tail -1       # Via WireGuard

# 5. Port checks
echo ""
echo "--- Ports ---"
# Check if Ollama is listening on all interfaces
ss -tlnp 2>/dev/null | grep 11434 || netstat -tlnp 2>/dev/null | grep 11434 || echo "Ollama port 11434: NOT LISTENING"
# Check if WireGuard UDP port is open
ss -ulnp 2>/dev/null | grep 51820 || netstat -ulnp 2>/dev/null | grep 51820 || echo "WireGuard port 51820: NOT LISTENING"

# 6. Firewall state
echo ""
echo "--- Firewall ---"
if [[ "$(uname)" == "Darwin" ]]; then
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null
elif command -v ufw &>/dev/null; then
  sudo ufw status 2>/dev/null
elif command -v iptables &>/dev/null; then
  sudo iptables -L -n 2>/dev/null | head -20
fi

# 7. MTU check
echo ""
echo "--- MTU ---"
# WireGuard typically needs MTU 1420
ping -c 1 -M do -s 1392 10.8.0.1 2>/dev/null && echo "MTU 1420: OK" || echo "MTU 1420: BLOCKED (try lowering MTU)"

# 8. Public IP
echo ""
echo "--- Identity ---"
PUBLIC_IP=$(curl -sf https://ifconfig.me 2>/dev/null || curl -sf https://api.ipify.org 2>/dev/null)
echo "Public IP: $PUBLIC_IP"
ISP=$(curl -sf "https://ipinfo.io/$PUBLIC_IP/org" 2>/dev/null)
echo "ISP: $ISP"

# 9. Route to VPS
echo ""
echo "--- Traceroute (first 10 hops) ---"
traceroute -m 10 76.13.179.86 2>/dev/null || tracepath -m 10 76.13.179.86 2>/dev/null || echo "Traceroute: not available"
```

## Common issues and fixes

### DNS not resolving
```bash
# Try Google DNS
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf.dcp > /dev/null
# Or Cloudflare
echo "nameserver 1.1.1.1" | sudo tee -a /etc/resolv.conf.dcp > /dev/null
```

### WireGuard handshake stale (>3 min)
```bash
# Force re-handshake
sudo wg-quick down wg0 2>/dev/null
sudo wg-quick up ~/.dcp/wg0.conf
```

### Ollama only on localhost
```bash
# Kill and restart with correct binding
pkill -f ollama
OLLAMA_HOST=0.0.0.0 OLLAMA_KEEP_ALIVE=-1 nohup ollama serve > ~/.dcp/logs/ollama.log 2>&1 &
```

### ISP blocking WireGuard UDP
```bash
# Check if UDP 51820 is blocked
nc -u -z -w 3 76.13.179.86 51820 2>/dev/null && echo "UDP OK" || echo "UDP BLOCKED"
# If blocked: report to DCP admin, may need TCP fallback
```

### High latency (>200ms)
- Check if ISP is throttling VPN traffic
- Check system load: `uptime`
- Check if another process is saturating bandwidth: `iftop` or `nethogs`

## Upload diagnostics to backend

After running diagnostics, upload the full report:
```bash
DIAG_FILE="/tmp/dcp-diagnostics-$(date +%s).json"
# ... collect all above into JSON ...
curl -s -X POST https://api.dcp.sa/api/providers/install-error \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" \
  -H "Content-Type: application/json" \
  -d @"$DIAG_FILE"
echo "Diagnostics uploaded to DCP backend"
```
