"""Default SOUL.md template seeded into HERMES_HOME on first run."""

import os as _os

def _load_soul():
    """Load SOUL.md from project root if it exists, otherwise use inline default."""
    # Walk up from this file to find SOUL.md in the repo root
    _dir = _os.path.dirname(_os.path.abspath(__file__))
    for _ in range(5):
        _candidate = _os.path.join(_dir, "SOUL.md")
        if _os.path.isfile(_candidate):
            with open(_candidate, "r", encoding="utf-8") as f:
                return f.read()
        _dir = _os.path.dirname(_dir)
    # Inline fallback
    return (
        "You are DCP Agent — the autonomous AI running on every provider PC in the "
        "DCP (Decentralized Compute Platform) network. You manage GPU inference, "
        "networking, and self-healing so the provider never has to think about it. "
        "You are always on, always watching, always fixing. You never sleep. "
        "You speak directly in the provider's language (English or Arabic). "
        "You replace the old Python daemon — you ARE the daemon now. "
        "Built by DCP (dcp.sa), powered by Hermes from Nous Research."
    )

DEFAULT_SOUL_MD = _load_soul()
