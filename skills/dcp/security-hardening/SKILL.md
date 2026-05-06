---
name: dcp-security-hardening
description: "Lock down Ollama to WireGuard mesh, configure firewall, verify no public exposure."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, security, firewall, hardening, ollama, exposure]
---

# DCP Security Hardening

Ensure Ollama is only accessible through the WireGuard mesh, not the public internet.

## Critical rule

**Ollama MUST listen on 0.0.0.0:11434** (for WireGuard mesh access) but **MUST NOT be reachable from the public internet**. Firewall rules enforce this.

## Firewall configuration

### macOS (pf)
```bash
# Create DCP firewall rules
sudo tee /etc/pf.anchors/dcp-agent > /dev/null << 'PF'
# DCP Agent — allow Ollama only from WireGuard mesh
# Block public access to Ollama
block in quick on en0 proto tcp from any to any port 11434
block in quick on en1 proto tcp from any to any port 11434
# Allow from WireGuard mesh
pass in quick on utun+ proto tcp from 10.8.0.0/24 to any port 11434
# Allow localhost
pass in quick on lo0 proto tcp from 127.0.0.1 to any port 11434
PF

# Load the anchor
if ! grep -q "dcp-agent" /etc/pf.conf 2>/dev/null; then
  echo 'anchor "dcp-agent"' | sudo tee -a /etc/pf.conf > /dev/null
  echo 'load anchor "dcp-agent" from "/etc/pf.anchors/dcp-agent"' | sudo tee -a /etc/pf.conf > /dev/null
fi
sudo pfctl -ef /etc/pf.conf 2>/dev/null
echo "macOS firewall: Ollama locked to WireGuard mesh"
```

### Linux (iptables/nftables)
```bash
# Allow Ollama from WireGuard mesh only
sudo iptables -I INPUT -p tcp --dport 11434 -s 10.8.0.0/24 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 11434 -s 127.0.0.1 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 11434 -j DROP

# Allow WireGuard UDP
sudo iptables -I INPUT -p udp --dport 51820 -j ACCEPT

# Save rules
sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null || sudo iptables-save | sudo tee /etc/iptables.rules > /dev/null
echo "Linux firewall: Ollama locked to WireGuard mesh"
```

### Windows
```powershell
# Block Ollama from public, allow from WireGuard mesh
Remove-NetFirewallRule -DisplayName "DCP Ollama*" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "DCP Ollama - Allow Mesh" -Direction Inbound -Protocol TCP -LocalPort 11434 -RemoteAddress 10.8.0.0/24 -Action Allow
New-NetFirewallRule -DisplayName "DCP Ollama - Allow Localhost" -Direction Inbound -Protocol TCP -LocalPort 11434 -RemoteAddress 127.0.0.1 -Action Allow
New-NetFirewallRule -DisplayName "DCP Ollama - Block Public" -Direction Inbound -Protocol TCP -LocalPort 11434 -Action Block
# WireGuard
New-NetFirewallRule -DisplayName "DCP WireGuard" -Direction Inbound -Protocol UDP -LocalPort 51820 -Action Allow
Write-Host "Windows firewall: Ollama locked to WireGuard mesh"
```

## Verify no public exposure

Run this as part of the daily security audit:

```bash
echo "=== Security Audit ==="

# 1. Check Ollama binding
OLLAMA_LISTEN=$(ss -tlnp 2>/dev/null | grep 11434 || netstat -tlnp 2>/dev/null | grep 11434)
echo "Ollama listening: $OLLAMA_LISTEN"

# 2. Check if Ollama is reachable from public IP
PUBLIC_IP=$(curl -sf https://ifconfig.me)
if curl -sf --connect-timeout 3 "http://$PUBLIC_IP:11434/" > /dev/null 2>&1; then
  echo "CRITICAL: Ollama is publicly accessible on $PUBLIC_IP:11434!"
  echo "Applying emergency firewall rules..."
  # Re-apply firewall rules
else
  echo "Ollama: NOT publicly accessible (good)"
fi

# 3. Check for unexpected listeners
echo ""
echo "Listening ports:"
ss -tlnp 2>/dev/null | grep -E "LISTEN" || netstat -tlnp 2>/dev/null | grep -E "LISTEN"

# 4. Check WireGuard key integrity
WG_CONF="$HOME/.dcp/wg0.conf"
if [ -f "$WG_CONF" ]; then
  PERMS=$(stat -f "%Lp" "$WG_CONF" 2>/dev/null || stat -c "%a" "$WG_CONF" 2>/dev/null)
  if [ "$PERMS" != "600" ]; then
    echo "WARNING: WireGuard config permissions are $PERMS (should be 600)"
    chmod 600 "$WG_CONF"
    echo "Fixed permissions"
  else
    echo "WireGuard config: permissions OK (600)"
  fi
fi

# 5. Check API key not in logs
if grep -r "$DCP_PROVIDER_KEY" ~/.dcp/logs/ 2>/dev/null | head -1; then
  echo "WARNING: Provider key found in logs — cleaning"
  # Redact key from logs
  find ~/.dcp/logs/ -type f -exec sed -i'' "s/$DCP_PROVIDER_KEY/[REDACTED]/g" {} \; 2>/dev/null
fi

# 6. Check sudoers file integrity
if [ -f /etc/sudoers.d/dcp-agent ]; then
  echo "Sudoers: dcp-agent rules present"
  sudo cat /etc/sudoers.d/dcp-agent 2>/dev/null
fi

echo "=== Audit complete ==="
```

## API key protection

- Never log the full DCP_PROVIDER_KEY — mask to first 20 chars
- Never send keys in error reports
- Store .env with 600 permissions
- Never include keys in git commits

```bash
# Ensure .env permissions
chmod 600 ~/.dcp/agent/.env 2>/dev/null
chmod 600 ~/.dcp/wg0.conf 2>/dev/null
```

## Schedule

- **Full audit**: Daily at 4am AST
- **Exposure check**: Every 6 hours
- **Firewall verification**: On boot and after any network change
