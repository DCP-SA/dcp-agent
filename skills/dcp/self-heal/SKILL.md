---
name: dcp-self-heal
description: "Automatically diagnose and fix common DCP provider issues."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, self-heal, diagnostics, troubleshooting, auto-fix]
---

# DCP Self-Heal

Automatically diagnose and fix issues on the provider's machine.

## Issue detection and resolution

### 1. Ollama not responding
```bash
# Check
curl -sf http://localhost:11434/ > /dev/null && echo "OK" || echo "DOWN"

# Fix
pkill -f ollama; sleep 2
OLLAMA_HOST=0.0.0.0 OLLAMA_KEEP_ALIVE=-1 nohup ollama serve > /dev/null 2>&1 &
sleep 5
curl -sf http://localhost:11434/ && echo "FIXED" || echo "STILL DOWN - escalate"
```

### 2. WireGuard tunnel dropped
```bash
# Check
ping -c 1 -W 3 10.8.0.1 > /dev/null 2>&1 && echo "OK" || echo "DOWN"

# Fix (macOS)
sudo wg-quick down wg0 2>/dev/null; sudo wg-quick up ~/.dcp/wg0.conf

# Fix (Windows)
wireguard /uninstalltunnelservice wg0; wireguard /installtunnelservice "$env:LOCALAPPDATA\dc1-provider\wg0.conf"
```

### 3. Model not loaded / corrupted
```bash
# Check
curl -s http://localhost:11434/api/tags | grep -q "qwen3" && echo "OK" || echo "MISSING"

# Fix
ollama pull qwen3:4b
```

### 4. Disk full (can't serve inference)
```bash
# Check
df -h / | awk 'NR==2{print $5}' | tr -d '%'  # If > 90%, alert

# Fix - clean old models
ollama list | sort -k2 -h | head -3  # Show smallest models
# Remove unused models to free space
```

### 5. Heartbeat failing
If heartbeat returns non-200 for 3+ consecutive attempts:
1. Check internet connectivity: `curl -sf https://api.dcp.sa/health`
2. Check API key validity: `curl -s -H "Authorization: Bearer $DCP_PROVIDER_KEY" https://api.dcp.sa/v1/provider/me`
3. If auth fails, re-register
4. If network fails, check DNS, check firewall

## Escalation
If self-heal fails after 3 attempts:
1. Log the full diagnostic state
2. Upload logs to `POST https://api.dcp.sa/api/providers/install-error`
3. Notify the provider via chat: "I couldn't fix [issue]. Here's what I tried..."
4. Alert the DCP admin team via backend event
