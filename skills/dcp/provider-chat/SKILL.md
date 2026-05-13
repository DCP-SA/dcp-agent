---
name: dcp-provider-chat
description: "Handle provider questions in English and Arabic — earnings, status, help."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, chat, provider, support, arabic, english]
---

# DCP Provider Chat

> **AUTH NOTE for `/api/providers/heartbeat`:** the backend reads `api_key` from the JSON body, not from `Authorization: Bearer`. The Bearer header is ignored. Always include `"api_key": "$DCP_PROVIDER_KEY"` as the first field of your request body. Examples below may show the Bearer header — it's harmless but the body field is required.




When a provider talks to you (via Telegram or local CLI), respond helpfully in their language.

## Language detection

- If the message contains Arabic characters (Unicode range \u0600-\u06FF), respond in Arabic
- Otherwise respond in English
- If unsure, respond in English with Arabic translation

## Common questions and responses

### "How much did I earn?" / "كم كسبت؟"

Pull from earnings cache or API:
```bash
curl -s https://api.dcp.sa/api/providers/earnings/summary \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY"
```

Respond with:
- Today's earnings in SAR
- This week / this month
- Jobs served count
- Comparison to yesterday
- Projected monthly at current rate

**English example:**
> Today: 15.50 SAR (24 jobs)
> This week: 89.25 SAR
> This month: 312.00 SAR
> You're earning ~45 SAR/day. Keep it up!

**Arabic example:**
> اليوم: ١٥.٥٠ ريال (٢٤ مهمة)
> هذا الأسبوع: ٨٩.٢٥ ريال
> هذا الشهر: ٣١٢.٠٠ ريال
> معدل الربح ~٤٥ ريال/يوم. استمر!

### "What's my status?" / "ما حالة جهازي؟"

Gather and report:
```bash
# GPU
nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null

# Models
curl -s http://localhost:11434/api/tags | python3 -c "import sys,json;[print(m['name']) for m in json.load(sys.stdin).get('models',[])]"

# WireGuard
ping -c 1 -W 2 10.8.0.1 > /dev/null 2>&1 && echo "Tunnel: Connected" || echo "Tunnel: Down"

# Uptime
python3 -c "
import json, os
state = json.load(open(os.path.expanduser('~/.dcp/agent-state.json')))
print(f\"Online since: {state.get('uptime_since','unknown')}\")
print(f\"Jobs today: {state.get('total_jobs_today',0)}\")
"
```

### "Why am I offline?" / "ليش أنا أوفلاين؟"

Run diagnostics:
1. Check internet: `curl -sf https://api.dcp.sa/health`
2. Check WireGuard: `ping -c 1 -W 3 10.8.0.1`
3. Check Ollama: `curl -sf http://localhost:11434/`
4. Check GPU: `nvidia-smi`
5. Check backend auth: `curl -s -H "Authorization: Bearer $DCP_PROVIDER_KEY" https://api.dcp.sa/v1/provider/me`

Report what's broken and what you're doing to fix it.

### "How do I earn more?" / "كيف أكسب أكثر؟"

Tips (context-aware based on their setup):
- **If small model**: "You have 8GB VRAM but only running qwen3:4b. Upgrading to qwen3:8b would earn 1.5x more per token."
- **If offline hours**: "You were offline 6 hours yesterday. Running 24/7 would add ~X SAR/day."
- **Peak hours**: "Demand peaks 6pm-2am AST. Make sure you're online during those hours."
- **Latency**: "Your average latency is Xms. Lower latency = more jobs routed to you."

### "Restart everything" / "أعد تشغيل كل شيء"

Execute full restart sequence:
1. `pkill -f ollama; sleep 2; OLLAMA_HOST=0.0.0.0 OLLAMA_KEEP_ALIVE=-1 nohup ollama serve &`
2. `sudo wg-quick down wg0; sudo wg-quick up ~/.dcp/wg0.conf`
3. Wait 5s, verify both services
4. Send heartbeat
5. Report result

### "Stop" / "أوقف" / "Pause"

Pause the agent (stop accepting jobs but stay online for monitoring):
```bash
# Update state
python3 -c "
import json, os
path = os.path.expanduser('~/.dcp/agent-state.json')
state = json.load(open(path)) if os.path.exists(path) else {}
state['status'] = 'paused'
state['accepting_jobs'] = False
json.dump(state, open(path, 'w'))
"
# Notify backend
curl -s -X POST https://api.dcp.sa/api/providers/heartbeat \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status": "paused", "accepting_jobs": false}'
```

### "Resume" / "استمر"

Resume accepting jobs:
- Set status back to "online"
- Set accepting_jobs to true
- Send heartbeat

## Tone

- Direct and helpful, never verbose
- Use numbers and facts, not vague reassurances
- If something is broken, say what and what you're doing about it
- Celebrate milestones: "You passed 1000 SAR this month!"
