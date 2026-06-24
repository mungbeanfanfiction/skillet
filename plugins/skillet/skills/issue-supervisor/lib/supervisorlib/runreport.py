"""Render the cycle run-report markdown (inherited from drain-queue).
The shell layer captures the date and writes the file to docs/superpowers/runs/."""


def _section(title: str, lines: list) -> str:
    body = "\n".join(lines) if lines else "_none_"
    return f"## {title}\n{body}\n"


def render(*, date: str, shipped: list, skipped: list, flagged: list) -> str:
    shipped_lines = [f"- {s['title']} → {s['pr_url']} — {s['summary']}" for s in shipped]
    skipped_lines = [f"- {s['title']} — {s['reason']}" for s in skipped]
    flagged_lines = [f"- {f['title']} — {f['note']}" for f in flagged]
    return (
        f"# Run report — {date}\n\n"
        + _section("Shipped", shipped_lines) + "\n"
        + _section("Skipped", skipped_lines) + "\n"
        + _section("Needs your attention", flagged_lines)
    )
