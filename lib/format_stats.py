"""Render headroom's /stats JSON as a compact human-readable summary.

Reads the /stats JSON on stdin; if a second JSON document (headroom's
/stats-history) is provided as argv[1] (a file path), its lifetime totals are
shown too. Defensive against missing keys so it never crashes on a partial or
future stats payload.

Usage: curl .../stats | python3 format_stats.py [stats-history.json]
"""

from __future__ import annotations

import json
import sys


def _num(x, default=0):
    return x if isinstance(x, (int, float)) else default


def _fmt_int(n):
    return f"{int(_num(n)):,}"


def _pct(saved, before):
    before = _num(before)
    return (100.0 * _num(saved) / before) if before else 0.0


def _table(rows, indent="  "):
    """Render [(label, value)] as a light box table sized to content."""
    w1 = max((len(r[0]) for r in rows), default=0)
    w2 = max((len(r[1]) for r in rows), default=0)
    top = f"{indent}┌─{'─' * w1}─┬─{'─' * w2}─┐"
    sep = f"{indent}├─{'─' * w1}─┼─{'─' * w2}─┤"
    bot = f"{indent}└─{'─' * w1}─┴─{'─' * w2}─┘"
    out = [top]
    for i, (a, b) in enumerate(rows):
        out.append(f"{indent}│ {a.ljust(w1)} │ {b.ljust(w2)} │")
    out.append(bot)
    return "\n".join(out)


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        print("token-saver: could not parse headroom stats", file=sys.stderr)
        sys.exit(1)

    s = data.get("summary", {}) if isinstance(data, dict) else {}
    comp = s.get("compression", {}) or {}
    unc = s.get("uncompressed_requests", {}) or {}
    cost = s.get("cost", {}) or {}

    reqs = int(_num(s.get("api_requests")))
    model = s.get("primary_model") or "—"
    before = _num(comp.get("total_tokens_before_with_cli_filtering"))
    saved = _num(comp.get("total_tokens_removed"))
    saved_pct = _pct(saved, before)
    compressed = int(_num(comp.get("requests_compressed")))
    frozen = int(_num(unc.get("prefix_frozen")))
    nocomp = int(_num(unc.get("no_compressible_content")))
    saved_usd = _num(cost.get("total_saved_usd"))
    cost_pct = _num(cost.get("savings_pct"))
    best = comp.get("best_detail") or ""

    print()
    print("  Token-saver — headroom savings")
    print(f"  Model:    {model}")
    breakdown = []
    if compressed:
        breakdown.append(f"{compressed} compressed")
    if frozen:
        breakdown.append(f"{frozen} prefix-frozen")
    if nocomp:
        breakdown.append(f"{nocomp} no-compressible-content")
    detail = f"  ({', '.join(breakdown)})" if breakdown else ""
    print(f"  Requests: {reqs}{detail}")
    print()

    rows = [
        ("Input tokens seen", _fmt_int(before)),
        ("Tokens saved", f"{_fmt_int(saved)}  ({saved_pct:.2f}%)"),
        ("Cost saved", f"${saved_usd:,.4f}  ({cost_pct:.1f}%)"),
    ]
    if best:
        rows.append(("Best single request", best))

    # Lifetime totals from /stats-history, if provided.
    if len(sys.argv) > 1:
        try:
            hist = json.load(open(sys.argv[1], encoding="utf-8"))
            life = hist.get("lifetime", {}) if isinstance(hist, dict) else {}
            lt_before = _num(life.get("total_input_tokens"))
            lt_saved = _num(life.get("tokens_saved"))
            if lt_before:
                rows.append((
                    "Lifetime saved",
                    f"{_fmt_int(lt_saved)} / {_fmt_int(lt_before)}"
                    f"  ({_pct(lt_saved, lt_before):.2f}%)",
                ))
        except (ValueError, OSError, KeyError):
            pass

    print(_table(rows))
    print()

    # One-line interpretation so the number means something.
    if reqs == 0:
        note = "No requests proxied yet — run pi-token-saver / hermes-token-saver first."
    elif saved_pct < 1.0:
        note = ("Minimal compression here — headroom mostly pays off on JSON/log/"
                "tool-output-heavy context, not code or prose.")
    else:
        note = f"Headroom trimmed {saved_pct:.1f}% of input tokens across {reqs} requests."
    print(f"  {note}")
    print()
    print("  Run 'token-saver-ctl stats --full-raw-json' for the complete payload.")


if __name__ == "__main__":
    main()
