---
name: dcp-self-update
description: "Check for agent updates, pull new code, reinstall, restart cleanly."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, update, upgrade, git, self-update]
---

# DCP Self-Update

Check for and apply agent updates without disrupting active inference.

## Check for updates

```bash
cd ~/.dcp/agent

# Fetch latest without merging
git fetch origin main --quiet 2>/dev/null

# Check if behind
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" == "$REMOTE" ]; then
  echo "Agent is up to date ($LOCAL)"
  exit 0
fi

BEHIND=$(git rev-list HEAD..origin/main --count)
echo "Update available: $BEHIND commits behind"
git log --oneline HEAD..origin/main
```

## Apply update

Only update when NOT actively serving a job:

```bash
cd ~/.dcp/agent

# 1. Check if inference is active
ACTIVE=$(curl -s http://localhost:11434/api/ps | python3 -c "
import sys,json
ps = json.load(sys.stdin)
models = ps.get('models',[])
active = [m for m in models if m.get('size_vram',0) > 0]
print(len(active))
" 2>/dev/null || echo "0")

if [ "$ACTIVE" -gt 0 ]; then
  echo "Inference active — deferring update"
  exit 0
fi

# 2. Pull changes
git stash 2>/dev/null  # Save any local changes
git pull --ff-only origin main
GIT_EXIT=$?

if [ $GIT_EXIT -ne 0 ]; then
  echo "Git pull failed — likely conflict. Resetting to remote."
  git reset --hard origin/main
fi

# 3. Check if dependencies changed
if git diff HEAD~$BEHIND --name-only | grep -qE "setup.py|setup.cfg|pyproject.toml|requirements"; then
  echo "Dependencies changed — reinstalling..."
  source .venv/bin/activate
  uv pip install -e . 2>/dev/null || pip install -e .
fi

# 4. Check if skills changed
if git diff HEAD~$BEHIND --name-only | grep -q "skills/dcp/"; then
  echo "Skills updated — agent will reload automatically"
fi

# 5. Check if restart required
if git diff HEAD~$BEHIND --name-only | grep -qE "hermes_cli/|gateway"; then
  echo "Core code changed — restarting agent..."
  # The launchd/systemd service will auto-restart
  exit 1  # Non-zero exit triggers service restart
fi

echo "Update applied. No restart needed."
```

## Ollama update check

```bash
# Check current version
CURRENT=$(ollama --version 2>/dev/null | awk '{print $NF}')

# Check latest (macOS)
if [[ "$(uname)" == "Darwin" ]]; then
  LATEST=$(brew info ollama --json=v2 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['formulae'][0]['versions']['stable'])" 2>/dev/null)
  if [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
    echo "Ollama update available: $CURRENT -> $LATEST"
    # Don't auto-update Ollama — just report
    # Provider can choose: brew upgrade ollama
  fi
fi

# Linux — check if update available
if [[ "$(uname)" == "Linux" ]]; then
  LATEST=$(curl -s https://api.github.com/repos/ollama/ollama/releases/latest | python3 -c "import sys,json;print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)
  if [ -n "$LATEST" ] && [ "v$CURRENT" != "$LATEST" ]; then
    echo "Ollama update available: $CURRENT -> $LATEST"
  fi
fi
```

## Schedule

Run every 6 hours via cron. Never during peak inference hours (6pm-2am AST) unless it's a critical security update.

## Rollback

If update causes failures:
```bash
cd ~/.dcp/agent
git log --oneline -5  # Find last good commit
git reset --hard HEAD~1  # Roll back one commit
source .venv/bin/activate
uv pip install -e . 2>/dev/null || pip install -e .
# Service auto-restarts
```
