---
name: dcp-earnings
description: "Query and display provider earnings from the DCP network."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, earnings, provider, sar, money, billing]
---

# DCP Earnings

Query the provider's earnings from the DCP backend and display them clearly.

## Earnings endpoint
```bash
curl -s https://api.dcp.sa/api/providers/earnings/summary \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" | python3 -c "
import sys,json
d = json.load(sys.stdin)
print(f\"Today: {d.get('today_halala',0)/100:.2f} SAR\")
print(f\"This week: {d.get('week_halala',0)/100:.2f} SAR\")
print(f\"This month: {d.get('month_halala',0)/100:.2f} SAR\")
print(f\"All time: {d.get('total_halala',0)/100:.2f} SAR\")
print(f\"Jobs served: {d.get('total_jobs',0)}\")
"
```

## When the provider asks about earnings
Always respond with:
1. Today's earnings in SAR
2. Comparison to yesterday / last week
3. Jobs served count
4. Current hourly rate
5. Projected monthly at current rate

## Tips for earning more
- Keep the machine running 24/7 (always_on mode)
- Larger models earn more per token (qwen3:8b > qwen3:4b)
- Peak hours are 6pm-2am Saudi time — highest demand
- Low latency = more job routing (keep WireGuard healthy)
