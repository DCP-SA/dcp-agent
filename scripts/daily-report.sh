#!/bin/bash
# DCP Daily Report — runs at 8am AST, messages provider
set -uo pipefail

DCP_DIR="$HOME/.dcp"
STATE="$DCP_DIR/agent-state.json"
PROVIDER_KEY="${DCP_PROVIDER_KEY:-$(grep DCP_PROVIDER_KEY "$DCP_DIR/agent/.env" 2>/dev/null | cut -d= -f2)}"

# Fetch earnings
EARNINGS=$(curl -sf https://api.dcp.sa/api/providers/earnings/summary \
  -H "Authorization: Bearer $PROVIDER_KEY" 2>/dev/null)

TODAY_SAR=$(echo "$EARNINGS" | python3 -c "import sys,json;print(f'{json.load(sys.stdin).get(\"yesterday_halala\",0)/100:.2f}')" 2>/dev/null || echo "0.00")
WEEK_SAR=$(echo "$EARNINGS" | python3 -c "import sys,json;print(f'{json.load(sys.stdin).get(\"week_halala\",0)/100:.2f}')" 2>/dev/null || echo "0.00")
MONTH_SAR=$(echo "$EARNINGS" | python3 -c "import sys,json;print(f'{json.load(sys.stdin).get(\"month_halala\",0)/100:.2f}')" 2>/dev/null || echo "0.00")
JOBS=$(echo "$EARNINGS" | python3 -c "import sys,json;print(json.load(sys.stdin).get('yesterday_jobs',0))" 2>/dev/null || echo "0")

# GPU stats
GPU_TEMP_AVG=$(python3 -c "
import json,os
s = json.load(open(os.path.expanduser('$STATE'))) if os.path.exists(os.path.expanduser('$STATE')) else {}
print(s.get('gpu_temp_avg', s.get('gpu_temp', '?')))
" 2>/dev/null || echo "?")

# Uptime
UPTIME=$(uptime | awk -F'( |,)+' '{print $4 " " $5}' 2>/dev/null || echo "unknown")

# Disk
DISK_PCT=$(df -h / | awk 'NR==2{print $5}')

# Error count
ERRORS=$(python3 -c "
import json,os
t = json.load(open(os.path.expanduser('$DCP_DIR/failure-tracker.json'))) if os.path.exists(os.path.expanduser('$DCP_DIR/failure-tracker.json')) else {}
total = sum(v.get('total_fails_24h',0) for v in t.values())
print(total)
" 2>/dev/null || echo "0")

# Build report
REPORT="Daily Report:
  Yesterday: $TODAY_SAR SAR ($JOBS jobs)
  This week: $WEEK_SAR SAR
  This month: $MONTH_SAR SAR
  GPU temp avg: ${GPU_TEMP_AVG}C
  Uptime: $UPTIME
  Disk: $DISK_PCT
  Errors (24h): $ERRORS"

echo "$REPORT"

# Reset 24h failure counters
python3 -c "
import json, os
p = os.path.expanduser('$DCP_DIR/failure-tracker.json')
if os.path.exists(p):
    t = json.load(open(p))
    for k in t:
        t[k]['total_fails_24h'] = 0
    with open(p, 'w') as f: json.dump(t, f, indent=2)
" 2>/dev/null
