---
name: dcp-power-management
description: "Prevent machine sleep, handle wake events, reconnect everything on resume."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, power, sleep, wake, caffeinate, always-on]
---

# DCP Power Management

Keep the provider's machine awake and handle sleep/wake events gracefully.

## Prevent sleep

### macOS
```bash
# Use caffeinate to prevent sleep (runs indefinitely)
# -d = prevent display sleep, -i = prevent idle sleep, -s = prevent system sleep
if ! pgrep -f "caffeinate.*dcp" > /dev/null 2>&1; then
  nohup caffeinate -dis -w $$ > /dev/null 2>&1 &
  echo "Sleep prevention active (caffeinate PID: $!)"
fi

# Also set system preferences via pmset
sudo pmset -a sleep 0          # Never sleep
sudo pmset -a disksleep 0      # Never sleep disk
sudo pmset -a displaysleep 15  # Display can sleep after 15min (saves energy)
sudo pmset -a autopoweroff 0   # Don't auto power off
sudo pmset -a standby 0        # Don't standby
```

### Linux
```bash
# Disable suspend/hibernate via systemd
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null

# Or via logind.conf
if ! grep -q "HandleLidSwitch=ignore" /etc/systemd/logind.conf 2>/dev/null; then
  echo "HandleLidSwitch=ignore" | sudo tee -a /etc/systemd/logind.conf > /dev/null
  echo "HandleLidSwitchExternalPower=ignore" | sudo tee -a /etc/systemd/logind.conf > /dev/null
  sudo systemctl restart systemd-logind 2>/dev/null
fi
```

### Windows
```powershell
# Disable sleep
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 15
# Set high performance power plan
powercfg /setactive SCHEME_MIN
```

## Handle wake from sleep

If the machine somehow sleeps and wakes (lid close on laptop, manual sleep), run recovery:

### macOS wake hook
```bash
# Create a sleepwatcher hook (if sleepwatcher is installed)
# Or detect wake via uptime change in the always-on loop

# Wake recovery script at ~/.dcp/on-wake.sh
cat > ~/.dcp/on-wake.sh << 'WAKE'
#!/bin/bash
echo "[$(date)] Machine woke from sleep — running recovery" >> ~/.dcp/logs/wake.log

# 1. Wait for network
for i in {1..30}; do
  ping -c 1 -W 1 8.8.8.8 > /dev/null 2>&1 && break
  sleep 1
done

# 2. Reconnect WireGuard
sudo wg-quick down wg0 2>/dev/null
sudo wg-quick up ~/.dcp/wg0.conf 2>/dev/null
sleep 2

# 3. Verify Ollama still running
if ! curl -sf http://localhost:11434/ > /dev/null 2>&1; then
  OLLAMA_HOST=0.0.0.0 OLLAMA_KEEP_ALIVE=-1 nohup ollama serve > ~/.dcp/logs/ollama.log 2>&1 &
  sleep 5
fi

# 4. Re-warm models (they get evicted on sleep)
MODELS=$(curl -s http://localhost:11434/api/tags | python3 -c "import sys,json;[print(m['name']) for m in json.load(sys.stdin).get('models',[])]" 2>/dev/null)
for MODEL in $MODELS; do
  curl -s -X POST http://localhost:11434/api/generate -d "{\"model\":\"$MODEL\",\"prompt\":\"warmup\",\"stream\":false}" > /dev/null 2>&1 &
done

# 5. Send heartbeat
curl -s -X POST https://api.dcp.sa/api/providers/heartbeat \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status": "online", "event": "wake_recovery"}'

echo "[$(date)] Wake recovery complete" >> ~/.dcp/logs/wake.log
WAKE
chmod +x ~/.dcp/on-wake.sh
```

### Detect sleep/wake in the always-on loop

```bash
# Track last check time. If gap >2 minutes, machine probably slept.
LAST_CHECK=$(cat ~/.dcp/last-check-ts 2>/dev/null || echo "0")
NOW=$(date +%s)
GAP=$((NOW - LAST_CHECK))

if [ "$GAP" -gt 120 ] && [ "$LAST_CHECK" -gt 0 ]; then
  echo "Detected sleep gap of ${GAP}s — running wake recovery"
  bash ~/.dcp/on-wake.sh
fi

echo "$NOW" > ~/.dcp/last-check-ts
```

## Energy awareness

- Display sleep is OK (saves power, doesn't affect inference)
- System sleep is NOT OK (kills inference, drops WireGuard)
- If provider is on a laptop, warn them: "Running on battery will drain quickly. Plug in for best performance."
- Track power source on macOS: `pmset -g batt | grep "AC Power"` vs "Battery Power"

## Provider controls

Provider can say:
- **"Let my machine sleep"** — disable caffeinate, restore default pmset
- **"Keep it awake"** — re-enable everything (default)
- **"Battery mode"** — pause jobs, reduce monitoring frequency, allow display sleep
