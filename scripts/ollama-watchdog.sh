#!/bin/bash
# DCP Ollama Watchdog — runs every 2min
set -uo pipefail

DCP_DIR="$HOME/.dcp"
LOG="$DCP_DIR/logs/watchdog-ollama.log"
TRACKER="$DCP_DIR/failure-tracker.json"
mkdir -p "$DCP_DIR/logs"

# Check if Ollama responds
if curl -sf http://localhost:11434/ > /dev/null 2>&1; then
  # Reset failure counter
  python3 -c "
import json, os
p = os.path.expanduser('$TRACKER')
t = json.load(open(p)) if os.path.exists(p) else {}
if 'ollama' in t: t['ollama']['consecutive_fails'] = 0
with open(p, 'w') as f: json.dump(t, f, indent=2)
" 2>/dev/null
  exit 0
fi

echo "[$(date -u +%H:%M:%S)] Ollama DOWN — restarting" >> "$LOG"

# Kill existing
pkill -f "ollama serve" 2>/dev/null
sleep 2

# Restart with correct env
OLLAMA_HOST=0.0.0.0 OLLAMA_KEEP_ALIVE=-1 nohup ollama serve >> "$DCP_DIR/logs/ollama.log" 2>&1 &
sleep 5

# Verify
if curl -sf http://localhost:11434/ > /dev/null 2>&1; then
  echo "[$(date -u +%H:%M:%S)] Ollama RECOVERED" >> "$LOG"
  # Re-warm models
  MODELS=$(curl -s http://localhost:11434/api/tags | python3 -c "import sys,json;[print(m['name']) for m in json.load(sys.stdin).get('models',[])]" 2>/dev/null)
  for MODEL in $MODELS; do
    curl -s -X POST http://localhost:11434/api/generate -d "{\"model\":\"$MODEL\",\"prompt\":\"warmup\",\"stream\":false}" > /dev/null 2>&1 &
  done
else
  echo "[$(date -u +%H:%M:%S)] Ollama STILL DOWN after restart" >> "$LOG"
  # Track failure
  python3 -c "
import json, os
from datetime import datetime
p = os.path.expanduser('$TRACKER')
t = json.load(open(p)) if os.path.exists(p) else {}
o = t.get('ollama', {'consecutive_fails':0,'total_fails_24h':0})
o['consecutive_fails'] = o.get('consecutive_fails',0) + 1
o['last_fail'] = datetime.utcnow().isoformat() + 'Z'
o['total_fails_24h'] = o.get('total_fails_24h',0) + 1
t['ollama'] = o
with open(p, 'w') as f: json.dump(t, f, indent=2)
if o['consecutive_fails'] >= 3:
    print('ESCALATE: Ollama failed 3 times')
" 2>/dev/null
fi
