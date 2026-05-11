#!/bin/bash
# DCP Agent Heartbeat — runs every 30s
# Reports provider status to DCP backend AND picks up pending pull_model
# tasks from the response so the renter's "warming" state can complete.
set -euo pipefail

DCP_DIR="$HOME/.dcp"
STATE="$DCP_DIR/agent-state.json"
LOG="$DCP_DIR/logs/heartbeat.log"
TASKS_DIR="$DCP_DIR/tasks"
PROVIDER_KEY="${DCP_PROVIDER_KEY:-$(grep DCP_PROVIDER_KEY "$DCP_DIR/agent/.env" 2>/dev/null | cut -d= -f2)}"

mkdir -p "$DCP_DIR/logs" "$TASKS_DIR"

# ── GPU telemetry ──────────────────────────────────────────────────────────
GPU_MODEL="" GPU_TEMP=0 GPU_VRAM_USED=0 GPU_VRAM_TOTAL=0 GPU_UTIL=0

if command -v nvidia-smi &>/dev/null; then
  IFS=', ' read -r GPU_MODEL GPU_TEMP GPU_VRAM_USED GPU_VRAM_TOTAL GPU_UTIL <<< \
    "$(nvidia-smi --query-gpu=name,temperature.gpu,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)"
elif [[ "$(uname)" == "Darwin" ]]; then
  GPU_MODEL=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Chipset Model" | awk -F: '{print $2}' | xargs)
  GPU_VRAM_TOTAL=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}')
fi

# ── Model cache snapshot (Ollama) ──────────────────────────────────────────
MODELS_JSON=$(curl -sf http://localhost:11434/api/tags 2>/dev/null | python3 -c "import sys,json;print(json.dumps([m['name'] for m in json.load(sys.stdin).get('models',[])]))" 2>/dev/null || echo '[]')

# ── WireGuard mesh IP ──────────────────────────────────────────────────────
WG_IP=$(ip addr show wg0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || \
        ifconfig utun0 2>/dev/null | grep "inet " | awk '{print $2}' || echo "")

# ── Uptime ─────────────────────────────────────────────────────────────────
UPTIME_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || python3 -c "import time,os;print(int(time.time()-os.stat('/').st_ctime))" 2>/dev/null || echo 0)

# ── Pull-task progress: scan ~/.dcp/tasks/*.json, flip in_progress →
#    completed when the target model now appears in ollama tags. ───────────
export DCP_TASKS_DIR="$TASKS_DIR"
export DCP_MODELS_JSON="$MODELS_JSON"
TASK_UPDATES=$(python3 - <<'PY' 2>/dev/null || echo '[]'
import json, os
tasks_dir = os.environ["DCP_TASKS_DIR"]
try:
    models = json.loads(os.environ.get("DCP_MODELS_JSON", "[]"))
except Exception:
    models = []
models_lower = {m.lower() for m in models if isinstance(m, str)}
out = []
if os.path.isdir(tasks_dir):
    for fn in sorted(os.listdir(tasks_dir)):
        if not fn.endswith(".json"): continue
        path = os.path.join(tasks_dir, fn)
        try:
            with open(path) as f: t = json.load(f)
        except Exception:
            continue
        task_id = t.get("task_id")
        if not task_id: continue
        status = t.get("status", "queued")
        model_id = (t.get("model_id") or "").lower()
        pull_uri = (t.get("ollama_pull_uri") or "").lower()
        matched = False
        for m in models_lower:
            if model_id and (model_id in m or m in model_id): matched = True; break
            if pull_uri and (pull_uri in m or m in pull_uri): matched = True; break
        if matched and status != "completed":
            t["status"] = "completed"
            t["progress_pct"] = 100
            t["progress_message"] = "model present in ollama tags"
            with open(path, "w") as f: json.dump(t, f, indent=2)
            status = "completed"
        out.append({
            "task_id": task_id,
            "status": status,
            "progress_pct": t.get("progress_pct", 50 if status == "in_progress" else (100 if status == "completed" else 0)),
            "progress_message": t.get("progress_message", ""),
        })
print(json.dumps(out))
PY
)
[ -z "$TASK_UPDATES" ] && TASK_UPDATES='[]'

# ── Send heartbeat. Backend requires api_key in body. Capture full
#    response so we can read pending_tasks. ─────────────────────────────────
RESPONSE=$(curl -sf -X POST https://api.dcp.sa/api/providers/heartbeat \
  -H "Authorization: Bearer $PROVIDER_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"api_key\": \"$PROVIDER_KEY\",
    \"status\": \"online\",
    \"gpu_status\": \"ready\",
    \"daemon_version\": \"agent-1.0.0\",
    \"gpu_model\": \"$GPU_MODEL\",
    \"gpu_temp_c\": ${GPU_TEMP:-0},
    \"gpu_vram_used_mb\": ${GPU_VRAM_USED:-0},
    \"gpu_vram_total_mb\": ${GPU_VRAM_TOTAL:-0},
    \"gpu_utilization_pct\": ${GPU_UTIL:-0},
    \"cached_models\": $MODELS_JSON,
    \"models_available\": $MODELS_JSON,
    \"wg_mesh_ip\": \"$WG_IP\",
    \"accepting_jobs\": true,
    \"uptime_seconds\": $UPTIME_S,
    \"task_updates\": $TASK_UPDATES
  }" 2>/dev/null || echo '{}')

HTTP_CODE=$([ -n "$RESPONSE" ] && echo "200" || echo "000")

# ── Spawn pull workers for newly-issued pull_model tasks ───────────────────
# Each task gets a state file under ~/.dcp/tasks/<task_id>.json. If the file
# already exists we don't re-fork (heartbeat is idempotent).
export DCP_HEARTBEAT_RESPONSE="$RESPONSE"
python3 - <<'PY' 2>/dev/null || true
import json, os, subprocess, sys
tasks_dir = os.environ["DCP_TASKS_DIR"]
os.makedirs(tasks_dir, exist_ok=True)
try:
    resp = json.loads(os.environ.get("DCP_HEARTBEAT_RESPONSE", "{}"))
except Exception:
    resp = {}
pending = resp.get("pending_tasks") or []
for task in pending:
    if task.get("task_type") != "pull_model": continue
    tid = task.get("task_id")
    if not tid: continue
    state_file = os.path.join(tasks_dir, f"{tid}.json")
    if os.path.exists(state_file):
        continue  # already started or completed
    params = task.get("params") or {}
    pull_uri = params.get("ollama_pull_uri")
    model_id = params.get("model_id")
    if not pull_uri:
        with open(state_file, "w") as f:
            json.dump({"task_id": tid, "status": "failed", "error_reason": "missing ollama_pull_uri", "model_id": model_id}, f)
        continue
    # Write the in_progress marker BEFORE forking so a heartbeat firing
    # during the fork doesn't accidentally double-spawn.
    with open(state_file, "w") as f:
        json.dump({"task_id": tid, "status": "in_progress", "progress_pct": 5,
                   "progress_message": f"ollama pull {pull_uri}",
                   "model_id": model_id, "ollama_pull_uri": pull_uri}, f)
    # Fork ollama pull in background, fully detached. The next heartbeat
    # will detect completion by checking ollama /api/tags. Tradeoff: no
    # fine-grained progress bar in the renter UI — renter cares about
    # ready-or-not, not 17% / 23% / 34%.
    log_path = os.path.expanduser(f"~/.dcp/logs/pull-{tid}.log")
    cmd = ["ollama", "pull", pull_uri]
    try:
        with open(log_path, "ab") as logf:
            subprocess.Popen(cmd, stdout=logf, stderr=logf, start_new_session=True)
        sys.stderr.write(f"[heartbeat] spawned ollama pull for task {tid}: {pull_uri}\n")
    except FileNotFoundError:
        # ollama not on PATH — mark failed
        with open(state_file, "w") as f:
            json.dump({"task_id": tid, "status": "failed",
                       "error_reason": "ollama binary not found on PATH",
                       "model_id": model_id, "ollama_pull_uri": pull_uri}, f)
PY

# ── Update state file ──────────────────────────────────────────────────────
python3 -c "
import json, os
from datetime import datetime
path = os.path.expanduser('$STATE')
s = {}
if os.path.exists(path):
    with open(path) as f: s = json.load(f)
s['last_heartbeat'] = datetime.utcnow().isoformat() + 'Z'
s['status'] = 'online'
s['gpu_temp'] = ${GPU_TEMP:-0}
s['models_loaded'] = $MODELS_JSON
with open(path, 'w') as f: json.dump(s, f, indent=2)
" 2>/dev/null

# ── Track failures ─────────────────────────────────────────────────────────
TRACKER="$DCP_DIR/failure-tracker.json"
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
  echo "[$(date -u +%H:%M:%S)] Heartbeat FAILED ($HTTP_CODE)" >> "$LOG"
  python3 -c "
import json, os
from datetime import datetime
t = {}
p = os.path.expanduser('$TRACKER')
if os.path.exists(p):
    with open(p) as f: t = json.load(f)
hb = t.get('heartbeat', {'consecutive_fails':0,'total_fails_24h':0})
hb['consecutive_fails'] = hb.get('consecutive_fails',0) + 1
hb['last_fail'] = datetime.utcnow().isoformat() + 'Z'
hb['total_fails_24h'] = hb.get('total_fails_24h',0) + 1
t['heartbeat'] = hb
with open(p, 'w') as f: json.dump(t, f, indent=2)
if hb['consecutive_fails'] >= 3:
    print('ESCALATE: 3 consecutive heartbeat failures')
" 2>/dev/null
else
  python3 -c "
import json, os
p = os.path.expanduser('$TRACKER')
t = {}
if os.path.exists(p):
    with open(p) as f: t = json.load(f)
if 'heartbeat' in t: t['heartbeat']['consecutive_fails'] = 0
with open(p, 'w') as f: json.dump(t, f, indent=2)
" 2>/dev/null
fi
