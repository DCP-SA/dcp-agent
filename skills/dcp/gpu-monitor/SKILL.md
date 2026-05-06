---
name: dcp-gpu-monitor
description: "Monitor GPU health, temperature, VRAM, and utilization for DCP providers."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, gpu, monitoring, nvidia, apple-silicon, provider]
---

# DCP GPU Monitor

Monitor the provider's GPU health and report to the DCP backend.

## What this skill does

Detects and monitors the GPU on this machine:
- **NVIDIA GPUs**: Uses `nvidia-smi` for temperature, VRAM usage, GPU utilization, power draw
- **Apple Silicon**: Uses `system_profiler` and `powermetrics` for Metal GPU stats
- **AMD GPUs**: Uses `rocm-smi` for ROCm-compatible cards

## Commands

### Check GPU status now
```bash
# NVIDIA
nvidia-smi --query-gpu=name,temperature.gpu,memory.used,memory.total,utilization.gpu,power.draw --format=csv,noheader

# Apple Silicon
system_profiler SPDisplaysDataType
sudo powermetrics --samplers gpu_power -i 1000 -n 1 2>/dev/null | grep -E "GPU|frequency|power"

# AMD
rocm-smi --showtemp --showuse --showmemuse
```

### Alert thresholds
- Temperature > 80°C: WARN — reduce load or check cooling
- Temperature > 90°C: CRITICAL — throttle inference immediately
- VRAM usage > 95%: WARN — model may OOM on next request
- GPU utilization at 0% for 10+ minutes while online: CHECK — inference engine may be stuck

### Report to DCP backend
```bash
curl -s -X POST https://api.dcp.sa/api/providers/heartbeat \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"gpu_temp\": $TEMP, \"gpu_util\": $UTIL, \"vram_used\": $VRAM_USED, \"vram_total\": $VRAM_TOTAL}"
```

## Cron schedule
Run every 60 seconds as a background monitor. Alert the provider if temperature exceeds thresholds.
