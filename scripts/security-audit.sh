#!/bin/bash
# DCP Security Audit — runs daily at 4am
set -uo pipefail

DCP_DIR="$HOME/.dcp"
LOG="$DCP_DIR/logs/security.log"
mkdir -p "$DCP_DIR/logs"

echo "=== Security Audit $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$LOG"

# 1. Check Ollama not publicly exposed
PUBLIC_IP=$(curl -sf https://ifconfig.me 2>/dev/null || echo "")
if [ -n "$PUBLIC_IP" ]; then
  if curl -sf --connect-timeout 3 "http://$PUBLIC_IP:11434/" > /dev/null 2>&1; then
    echo "CRITICAL: Ollama publicly accessible on $PUBLIC_IP:11434!" >> "$LOG"
    # Re-apply firewall
    if [[ "$(uname)" == "Darwin" ]]; then
      sudo pfctl -ef /etc/pf.conf 2>/dev/null
    elif command -v iptables &>/dev/null; then
      sudo iptables -I INPUT -p tcp --dport 11434 -s 10.8.0.0/24 -j ACCEPT
      sudo iptables -I INPUT -p tcp --dport 11434 -s 127.0.0.1 -j ACCEPT
      sudo iptables -I INPUT -p tcp --dport 11434 -j DROP
    fi
  else
    echo "OK: Ollama not publicly accessible" >> "$LOG"
  fi
fi

# 2. Check file permissions
for f in "$DCP_DIR/agent/.env" "$DCP_DIR/wg0.conf"; do
  if [ -f "$f" ]; then
    perms=$(stat -f "%Lp" "$f" 2>/dev/null || stat -c "%a" "$f" 2>/dev/null)
    if [ "$perms" != "600" ]; then
      chmod 600 "$f"
      echo "Fixed permissions on $f ($perms -> 600)" >> "$LOG"
    fi
  fi
done

# 3. Check no API keys in logs
PROVIDER_KEY="${DCP_PROVIDER_KEY:-$(grep DCP_PROVIDER_KEY "$DCP_DIR/agent/.env" 2>/dev/null | cut -d= -f2)}"
if [ -n "$PROVIDER_KEY" ] && grep -rq "$PROVIDER_KEY" "$DCP_DIR/logs/" 2>/dev/null; then
  echo "WARN: Provider key found in logs — redacting" >> "$LOG"
  find "$DCP_DIR/logs/" -type f -exec sed -i'' "s/$PROVIDER_KEY/[REDACTED]/g" {} \; 2>/dev/null
fi

# 4. Check for unexpected listeners
echo "Listening ports:" >> "$LOG"
(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep LISTEN >> "$LOG" 2>/dev/null

echo "=== Audit complete ===" >> "$LOG"
