#!/bin/bash
# DCP WireGuard Watchdog — runs every 2min
set -uo pipefail

DCP_DIR="$HOME/.dcp"
LOG="$DCP_DIR/logs/watchdog-wg.log"
TRACKER="$DCP_DIR/failure-tracker.json"
mkdir -p "$DCP_DIR/logs"

# Quick ping test
if ping -c 1 -W 3 10.8.0.1 > /dev/null 2>&1; then
  # Reset failure counter
  python3 -c "
import json, os
p = os.path.expanduser('$TRACKER')
t = json.load(open(p)) if os.path.exists(p) else {}
if 'wireguard' in t: t['wireguard']['consecutive_fails'] = 0
with open(p, 'w') as f: json.dump(t, f, indent=2)
" 2>/dev/null
  exit 0
fi

echo "[$(date -u +%H:%M:%S)] WireGuard DOWN — reconnecting" >> "$LOG"

# Try reconnect
sudo wg-quick down wg0 2>/dev/null
sleep 1

# Try multiple config locations
if [ -f "$DCP_DIR/wg0.conf" ]; then
  sudo wg-quick up "$DCP_DIR/wg0.conf"
elif [ -f /etc/wireguard/wg0.conf ]; then
  sudo wg-quick up wg0
else
  echo "[$(date -u +%H:%M:%S)] No WireGuard config found!" >> "$LOG"
fi

sleep 2

# Verify
if ping -c 1 -W 3 10.8.0.1 > /dev/null 2>&1; then
  echo "[$(date -u +%H:%M:%S)] WireGuard RECOVERED" >> "$LOG"
else
  echo "[$(date -u +%H:%M:%S)] WireGuard STILL DOWN" >> "$LOG"
  python3 -c "
import json, os
from datetime import datetime
p = os.path.expanduser('$TRACKER')
t = json.load(open(p)) if os.path.exists(p) else {}
w = t.get('wireguard', {'consecutive_fails':0,'total_fails_24h':0})
w['consecutive_fails'] = w.get('consecutive_fails',0) + 1
w['last_fail'] = datetime.utcnow().isoformat() + 'Z'
w['total_fails_24h'] = w.get('total_fails_24h',0) + 1
t['wireguard'] = w
with open(p, 'w') as f: json.dump(t, f, indent=2)
if w['consecutive_fails'] >= 3:
    print('ESCALATE: WireGuard failed 3 times — may need re-registration')
" 2>/dev/null
fi
