#!/bin/bash
# DCP Earnings Cache Update — runs every 15min
set -uo pipefail

DCP_DIR="$HOME/.dcp"
PROVIDER_KEY="${DCP_PROVIDER_KEY:-$(grep DCP_PROVIDER_KEY "$DCP_DIR/agent/.env" 2>/dev/null | cut -d= -f2)}"

mkdir -p "$DCP_DIR"

# Fetch earnings from backend
EARNINGS=$(curl -sf https://api.dcp.sa/api/providers/earnings/summary \
  -H "Authorization: Bearer $PROVIDER_KEY" 2>/dev/null)

if [ -n "$EARNINGS" ]; then
  echo "$EARNINGS" > "$DCP_DIR/earnings-cache.json"

  # Update state file
  python3 -c "
import json, os
earnings = json.loads('$EARNINGS')
state_path = os.path.expanduser('$DCP_DIR/agent-state.json')
state = json.load(open(state_path)) if os.path.exists(state_path) else {}
state['earnings_today_halala'] = earnings.get('today_halala', 0)
state['total_jobs_today'] = earnings.get('today_jobs', state.get('total_jobs_today', 0))
with open(state_path, 'w') as f: json.dump(state, f, indent=2)
" 2>/dev/null
fi
