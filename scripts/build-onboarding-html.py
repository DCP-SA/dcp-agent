#!/usr/bin/env python3
"""Render DCP-ONBOARDING.md to a branded HTML file.

DCP brand:
- Wordmark: DCP (Geist Bold / Inter Bold, uppercase, white)
- Underline: ∞ gradient L→R: D=teal #00E5C8 → P=orange #FF6B00
- Background: deep navy #0D1B2A
- Tagline: "Infinite Compute. Real Power."
"""
import sys
import datetime
from pathlib import Path
import markdown

SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("DCP-ONBOARDING.md")
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("DCP-ONBOARDING.html")

md_text = SRC.read_text(encoding="utf-8")
html_body = markdown.markdown(
    md_text,
    extensions=["fenced_code", "tables", "toc", "sane_lists", "attr_list"],
    extension_configs={"toc": {"permalink": False}},
)
generated_at = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")

template = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
<title>DCP Agent — Onboarding</title>
<meta name="description" content="DCP Agent repo onboarding for new contributors — clone, run, test, ship a PR. Updated automatically from DCP-ONBOARDING.md." />
<meta name="theme-color" content="#0D1B2A" />
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
<style>
:root {{
  --bg: #0D1B2A;
  --bg-elev: #142537;
  --bg-card: #1A2E45;
  --teal: #00E5C8;
  --orange: #FF6B00;
  --fg: #E8EEF7;
  --fg-muted: #94A3B8;
  --border: rgba(255,255,255,0.08);
  --code-bg: #0A1420;
  --gradient: linear-gradient(90deg, var(--teal) 0%, var(--orange) 100%);
}}
* {{ box-sizing: border-box; }}
html, body {{ margin: 0; padding: 0; background: var(--bg); color: var(--fg); font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.65; -webkit-font-smoothing: antialiased; }}
body {{ font-size: 16px; }}
.page {{ max-width: 920px; margin: 0 auto; padding: 48px 32px 80px; }}

/* Header */
.hdr {{ padding-bottom: 32px; border-bottom: 1px solid var(--border); margin-bottom: 48px; }}
.brand {{ display: flex; align-items: center; gap: 14px; margin-bottom: 8px; }}
.brand-mark {{ display: inline-block; font-family: 'Inter', sans-serif; font-weight: 700; font-size: 32px; letter-spacing: -0.02em; color: #fff; line-height: 1; position: relative; }}
.brand-mark::after {{ content: ''; display: block; height: 3px; border-radius: 3px; background: var(--gradient); margin-top: 6px; }}
.brand-mark .infinity {{ background: var(--gradient); -webkit-background-clip: text; background-clip: text; color: transparent; padding-left: 4px; }}
.tagline {{ color: var(--fg-muted); font-size: 13px; letter-spacing: 0.04em; text-transform: uppercase; }}
h1.title {{ margin: 24px 0 6px; font-size: 36px; font-weight: 700; letter-spacing: -0.02em; color: #fff; }}
.subtitle {{ color: var(--fg-muted); font-size: 16px; margin-top: 0; }}
.meta {{ display: flex; gap: 16px; flex-wrap: wrap; margin-top: 16px; font-size: 13px; color: var(--fg-muted); }}
.meta span {{ display: inline-flex; align-items: center; gap: 6px; }}
.meta a {{ color: var(--teal); text-decoration: none; }}
.meta a:hover {{ text-decoration: underline; }}
.pill {{ display: inline-block; padding: 2px 10px; border-radius: 999px; background: rgba(0,229,200,0.1); color: var(--teal); font-size: 11px; letter-spacing: 0.05em; text-transform: uppercase; font-weight: 600; }}

/* Body */
.content h1, .content h2, .content h3, .content h4 {{ color: #fff; font-weight: 600; letter-spacing: -0.01em; }}
.content h1 {{ font-size: 28px; margin-top: 56px; margin-bottom: 16px; padding-bottom: 10px; border-bottom: 1px solid var(--border); }}
.content h2 {{ font-size: 22px; margin-top: 40px; margin-bottom: 12px; }}
.content h3 {{ font-size: 18px; margin-top: 28px; margin-bottom: 10px; }}
.content h4 {{ font-size: 16px; margin-top: 20px; margin-bottom: 8px; color: var(--teal); }}
.content p {{ margin: 12px 0; }}
.content a {{ color: var(--teal); text-decoration: none; border-bottom: 1px solid rgba(0,229,200,0.25); }}
.content a:hover {{ border-bottom-color: var(--teal); }}
.content strong {{ color: #fff; }}
.content em {{ color: var(--fg-muted); }}
.content hr {{ border: 0; border-top: 1px solid var(--border); margin: 48px 0; }}
.content ul, .content ol {{ padding-left: 24px; }}
.content li {{ margin: 6px 0; }}
.content blockquote {{ margin: 16px 0; padding: 12px 18px; border-left: 3px solid var(--orange); background: rgba(255,107,0,0.05); color: var(--fg); border-radius: 0 6px 6px 0; }}

/* Code */
.content code {{ font-family: 'JetBrains Mono', ui-monospace, Menlo, monospace; font-size: 13px; background: var(--code-bg); padding: 2px 6px; border-radius: 4px; color: var(--teal); border: 1px solid var(--border); }}
.content pre {{ background: var(--code-bg); border: 1px solid var(--border); border-radius: 8px; padding: 16px 20px; overflow-x: auto; margin: 16px 0; }}
.content pre code {{ background: transparent; border: 0; padding: 0; color: var(--fg); font-size: 13px; line-height: 1.6; }}

/* Tables */
.content table {{ width: 100%; border-collapse: collapse; margin: 16px 0; font-size: 14px; background: var(--bg-card); border-radius: 8px; overflow: hidden; }}
.content th {{ background: var(--bg-elev); color: var(--teal); text-align: left; padding: 10px 14px; font-weight: 600; font-size: 13px; letter-spacing: 0.02em; }}
.content td {{ padding: 10px 14px; border-top: 1px solid var(--border); vertical-align: top; }}
.content tr:hover td {{ background: rgba(255,255,255,0.02); }}

/* Footer */
.ftr {{ margin-top: 64px; padding-top: 24px; border-top: 1px solid var(--border); font-size: 12px; color: var(--fg-muted); display: flex; justify-content: space-between; flex-wrap: wrap; gap: 12px; }}
.ftr a {{ color: var(--teal); }}

@media (max-width: 720px) {{
  .page {{ padding: 32px 20px 60px; }}
  h1.title {{ font-size: 28px; }}
  .content h1 {{ font-size: 24px; }}
  .content table {{ font-size: 13px; }}
}}

/* Print */
@media print {{
  body {{ background: #fff; color: #0D1B2A; }}
  .page {{ padding: 20px; max-width: 100%; }}
  .content h1, .content h2, .content h3, .content h4 {{ color: #0D1B2A; }}
  .content code {{ background: #f4f4f4; color: #0D1B2A; border-color: #ddd; }}
  .content pre {{ background: #f4f4f4; border-color: #ddd; }}
  .content pre code {{ color: #0D1B2A; }}
  .brand-mark {{ color: #0D1B2A; }}
  .content table {{ background: #fff; border: 1px solid #ddd; }}
  .content th {{ background: #f4f4f4; color: #0D1B2A; }}
  .meta a {{ color: #0D1B2A; }}
}}
</style>
</head>
<body>
<div class="page">
  <header class="hdr">
    <div class="brand">
      <div class="brand-mark">D<span class="infinity">∞</span>P</div>
      <div class="tagline">Infinite Compute. Real Power.</div>
    </div>
    <h1 class="title">DCP Agent — Onboarding</h1>
    <p class="subtitle">First-PR guide for new contributors to the DCP Agent fork. Auto-rendered from <code>DCP-ONBOARDING.md</code>.</p>
    <div class="meta">
      <span class="pill">Living doc</span>
      <span>Last build: {generated_at}</span>
      <span>Source: <a href="https://github.com/dhnpmp-tech/dcp-agent/blob/main/DCP-ONBOARDING.md">DCP-ONBOARDING.md</a></span>
      <span>Repo: <a href="https://github.com/dhnpmp-tech/dcp-agent">dhnpmp-tech/dcp-agent</a></span>
    </div>
  </header>

  <main class="content">
{html_body}
  </main>

  <footer class="ftr">
    <span>© DCP — Decentralized Compute Provider. <a href="https://dcp.sa">dcp.sa</a></span>
    <span>Rendered {generated_at} · <a href="https://github.com/dhnpmp-tech/dcp-agent/blob/main/DCP-ONBOARDING.md">edit source</a></span>
  </footer>
</div>
</body>
</html>
"""

# The MD has its own H1 "# DCP Agent — onboarding for first contribution".
# Strip duplicate H1 to avoid two big titles on the page.
import re
html_body = re.sub(r"<h1[^>]*>DCP Agent — onboarding for first contribution</h1>\s*", "", html_body, count=1)
# Also strip the now-trailing horizontal rule if duplicated
html_body = re.sub(r"^\s*<hr\s*/?>\s*", "", html_body)

out_html = template.format(generated_at=generated_at, html_body=html_body)
OUT.write_text(out_html, encoding="utf-8")
print(f"wrote {OUT} ({len(out_html):,} bytes)")
