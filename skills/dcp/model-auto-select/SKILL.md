---
name: dcp-model-auto-select
description: "Detect VRAM and auto-select the best models for this GPU."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, models, vram, auto-select, optimization]
---

# DCP Model Auto-Select

> **AUTH NOTE for `/api/providers/heartbeat`:** the backend reads `api_key` from the JSON body, not from `Authorization: Bearer`. The Bearer header is ignored. Always include `"api_key": "$DCP_PROVIDER_KEY"` as the first field of your request body. Examples below may show the Bearer header — it's harmless but the body field is required.




Automatically pick and pull the best-earning models that fit in this GPU's VRAM.

## VRAM detection

```bash
# NVIDIA
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)

# Apple Silicon (unified memory — use 75% for inference)
if [ -z "$VRAM_MB" ] && [[ "$(uname)" == "Darwin" ]]; then
  TOTAL_MB=$(sysctl -n hw.memsize | awk '{print int($1/1024/1024)}')
  VRAM_MB=$((TOTAL_MB * 75 / 100))
fi

# AMD ROCm
if [ -z "$VRAM_MB" ]; then
  VRAM_MB=$(rocm-smi --showmeminfo vram 2>/dev/null | grep "Total" | awk '{print int($3/1024/1024)}')
fi

echo "Available VRAM: ${VRAM_MB}MB"
```

## Model tiers by VRAM

Pick the LARGEST models that fit. Bigger models = more earnings per token.

### 4-6 GB VRAM (e.g., GTX 1650, RTX 3050)
```
Primary:   qwen3:4b     (~2.5GB)
Secondary: phi4-mini:3.8b (~2.3GB)
Total:     ~4.8GB
```

### 8 GB VRAM (e.g., RTX 3060 Ti, RTX 4060)
```
Primary:   qwen3:8b     (~4.9GB)
Secondary: qwen3:4b     (~2.5GB)
Total:     ~7.4GB
```

### 12 GB VRAM (e.g., RTX 3060 12GB, RTX 4070)
```
Primary:   qwen3:14b    (~8.7GB)
Secondary: qwen3:4b     (~2.5GB)
Total:     ~11.2GB
```

### 16 GB VRAM (e.g., RTX 4080 SUPER, Apple M1 Pro 16GB)
```
Primary:   qwen3:14b    (~8.7GB)
Secondary: qwen3:8b     (~4.9GB)
Total:     ~13.6GB
```

### 24 GB VRAM (e.g., RTX 3090, RTX 4090)
```
Primary:   qwen3:32b    (~19.8GB)
Secondary: qwen3:4b     (~2.5GB)
Total:     ~22.3GB
```

### 32+ GB VRAM (e.g., Apple M2 Ultra, dual GPU)
```
Primary:   qwen3:32b    (~19.8GB)
Secondary: qwen3:14b    (~8.7GB)
Total:     ~28.5GB
```

## Selection algorithm

```python
# Pseudocode
MODEL_CATALOG = [
    {"name": "qwen3:32b",  "vram_mb": 19800, "earnings_multiplier": 4.0},
    {"name": "qwen3:14b",  "vram_mb": 8700,  "earnings_multiplier": 2.5},
    {"name": "qwen3:8b",   "vram_mb": 4900,  "earnings_multiplier": 1.5},
    {"name": "qwen3:4b",   "vram_mb": 2500,  "earnings_multiplier": 1.0},
    {"name": "phi4-mini:3.8b", "vram_mb": 2300, "earnings_multiplier": 0.8},
]

def select_models(vram_mb):
    selected = []
    remaining = vram_mb - 500  # 500MB headroom for system
    for model in MODEL_CATALOG:
        if model["vram_mb"] <= remaining:
            selected.append(model["name"])
            remaining -= model["vram_mb"]
    return selected
```

## Pull and verify

```bash
# Pull each selected model
for MODEL in $SELECTED_MODELS; do
  echo "Pulling $MODEL..."
  ollama pull "$MODEL"

  # Verify it loads
  RESULT=$(curl -s -X POST http://localhost:11434/api/generate \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"test\",\"stream\":false}" | \
    python3 -c "import sys,json;d=json.load(sys.stdin);print(f'{d.get(\"eval_count\",0)} tokens')" 2>/dev/null)
  echo "  Verified: $RESULT"
done
```

## Register models with backend

After pulling, report available models to the backend so it can route traffic:

```bash
curl -s -X POST https://api.dcp.sa/api/providers/heartbeat \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"models_available\": $(ollama list --json 2>/dev/null | python3 -c "
import sys,json
models = []
for line in sys.stdin:
    try:
        d = json.loads(line)
        models.append(d.get('name',''))
    except: pass
print(json.dumps(models))
" || curl -s http://localhost:11434/api/tags | python3 -c "import sys,json;print(json.dumps([m['name'] for m in json.load(sys.stdin).get('models',[])]))")
  }"
```

## When to re-run model selection

- On first boot (no models loaded)
- When GPU changes (e.g., driver update changes reported VRAM)
- When backend pushes a model catalog update
- When provider manually requests different models
- When a model fails inference 3 times (replace it)
