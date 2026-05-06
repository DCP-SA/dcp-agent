---
name: dcp-provider-registration
description: "Register with DCP backend, fetch WireGuard config, verify connectivity."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, registration, wireguard, onboarding, setup]
---

# DCP Provider Registration

Handle the full provider onboarding flow: register with backend, get WireGuard peer config, set up tunnel, verify end-to-end.

## Pre-requisites

- `DCP_PROVIDER_KEY` set in .env (from install.sh --key argument)
- Internet connectivity to api.dcp.sa
- WireGuard installed (`wg` and `wg-quick` available)

## Step 1: Verify provider key

```bash
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" \
  https://api.dcp.sa/v1/provider/me)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -1)

if [ "$HTTP_CODE" == "200" ]; then
  PROVIDER_NAME=$(echo "$BODY" | python3 -c "import sys,json;print(json.load(sys.stdin).get('name','Unknown'))")
  echo "Provider: $PROVIDER_NAME"
else
  echo "ERROR: Invalid provider key (HTTP $HTTP_CODE)"
  echo "Get a valid key from https://dcp.sa/setup"
  exit 1
fi
```

## Step 2: Collect machine info for registration

```bash
# Build registration payload
python3 << 'COLLECT'
import json, subprocess, platform, os

def run(cmd):
    try: return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL).decode().strip()
    except: return ""

info = {
    "hostname": platform.node(),
    "os": platform.system(),
    "os_version": platform.release(),
    "arch": platform.machine(),
    "cpu": platform.processor() or run("sysctl -n machdep.cpu.brand_string") or run("lscpu | grep 'Model name' | cut -d: -f2"),
    "ram_mb": int(os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES') / 1024 / 1024) if hasattr(os, 'sysconf') else 0,
}

# GPU
nvidia = run("nvidia-smi --query-gpu=name,memory.total --format=csv,noheader")
if nvidia:
    parts = nvidia.split(", ")
    info["gpu_model"] = parts[0]
    info["gpu_vram_mb"] = int(parts[1].replace(" MiB","")) if len(parts)>1 else 0
else:
    apple = run("system_profiler SPDisplaysDataType 2>/dev/null | grep 'Chipset Model' | head -1")
    if apple:
        info["gpu_model"] = apple.split(":")[1].strip() if ":" in apple else apple
        info["gpu_vram_mb"] = int(run("sysctl -n hw.memsize")) // 1024 // 1024

print(json.dumps(info, indent=2))
COLLECT
```

## Step 3: Register and get WireGuard config

```bash
# POST registration — backend assigns a WireGuard peer IP and returns config
RESPONSE=$(curl -s -X POST https://api.dcp.sa/api/providers/wg/register \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" \
  -H "Content-Type: application/json" \
  -d "$MACHINE_INFO")

# Extract WireGuard config
echo "$RESPONSE" | python3 -c "
import sys, json, os
d = json.load(sys.stdin)
wg_conf = d.get('wg_config', '')
mesh_ip = d.get('mesh_ip', '')
if wg_conf:
    os.makedirs(os.path.expanduser('~/.dcp'), exist_ok=True)
    with open(os.path.expanduser('~/.dcp/wg0.conf'), 'w') as f:
        f.write(wg_conf)
    os.chmod(os.path.expanduser('~/.dcp/wg0.conf'), 0o600)
    print(f'WireGuard config saved. Mesh IP: {mesh_ip}')
else:
    print('ERROR: No WireGuard config in response')
    print(json.dumps(d, indent=2))
"
```

## Step 4: Activate WireGuard tunnel

```bash
# macOS / Linux
sudo wg-quick down wg0 2>/dev/null
sudo wg-quick up ~/.dcp/wg0.conf

# Verify
sleep 2
if ping -c 1 -W 3 10.8.0.1 > /dev/null 2>&1; then
  echo "WireGuard tunnel: CONNECTED"
  WG_IP=$(sudo wg show wg0 2>/dev/null | grep "allowed ips" | head -1)
  echo "Mesh: $WG_IP"
else
  echo "WireGuard tunnel: FAILED"
  echo "Trying fallback..."
  sudo wg-quick up /etc/wireguard/wg0.conf 2>/dev/null
fi
```

## Step 5: Verify end-to-end inference path

```bash
# The backend routes inference to provider via WireGuard mesh IP + Ollama port
# Verify this machine is reachable from the VPS perspective
curl -s -X POST https://api.dcp.sa/api/providers/connectivity-check \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"check\": \"inference_reachability\"}"
```

## Step 6: Mark registration complete

```bash
mkdir -p ~/.dcp
echo "{\"registered\": true, \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > ~/.dcp/registration.json
echo "Registration complete."
```

## Re-registration triggers

Run registration again if:
- WireGuard config file is missing (~/.dcp/wg0.conf)
- Provider key changed
- Backend returns 401 on heartbeat
- Machine hardware changed (new GPU)
- Provider requests re-registration via chat
