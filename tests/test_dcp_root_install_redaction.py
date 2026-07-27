"""Regression tests for DCP root installer credential handling."""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO_ROOT / "install.sh"


def test_root_installer_never_echoes_provider_key_expansions() -> None:
    script = INSTALL_SH.read_text()
    echo_lines = [
        line.strip()
        for line in script.splitlines()
        if line.strip().startswith("echo ")
    ]

    leaking_lines = [
        line
        for line in echo_lines
        if "$PROVIDER_KEY" in line or "${PROVIDER_KEY" in line
    ]
    assert leaking_lines == [], (
        "install.sh must not echo the live provider key or any key prefix; "
        f"leaking echo lines: {leaking_lines!r}"
    )


def test_root_installer_rerun_help_uses_placeholder_not_live_key() -> None:
    script = INSTALL_SH.read_text()

    assert "--key $PROVIDER_KEY" not in script
    assert "--key ${PROVIDER_KEY" not in script
    assert "export DCP_PROVIDER_KEY=YOUR_DCP_PROVIDER_KEY" in script
    assert "curl -fsSL https://api.dcp.sa/install/agent | bash" in script


def test_root_installer_accepts_env_key_without_showing_it() -> None:
    script = INSTALL_SH.read_text()

    assert 'PROVIDER_KEY="${DCP_PROVIDER_KEY:-}"' in script
    assert 'echo "Provider key: received (not shown)"' in script
    assert "Provider key: ${PROVIDER_KEY" not in script


def test_root_installer_contains_no_bundled_service_credentials() -> None:
    script = INSTALL_SH.read_text()

    assert "sk-cp-" not in script
    assert "MINIMAX_KEY=" not in script
    telegram_bot_token = re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{30,}\b")
    assert telegram_bot_token.search(script) is None
