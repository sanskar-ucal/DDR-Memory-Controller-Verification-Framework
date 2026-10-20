"""Minimal dependency-free SVG line chart."""

from __future__ import annotations

from xml.sax.saxutils import escape

PALETTE = ["#2563eb", "#dc2626", "#16a34a", "#9333ea", "#ea580c"]


def line_chart(series: list[tuple[str, list[tuple[float, float]]]], title: str,
               xlabel: str, ylabel: str, ymin: float = 0, ymax: float = 100,
               width: int = 760, height: int = 360) -> str:
    ml, mr, mt, mb = 64, 24, 40, 52
    pw, ph = width - ml - mr, height - mt - mb
    xmax = max((x for _, pts in series for x, _ in pts), default=1) or 1

    def sx(x):
        return ml + pw * x / xmax

    def sy(y):
        return mt + ph * (1 - (y - ymin) / (ymax - ymin))

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
           f'font-family="Helvetica,Arial,sans-serif" font-size="12">',
           f'<rect width="{width}" height="{height}" fill="white"/>',
           f'<text x="{width / 2}" y="22" text-anchor="middle" font-size="15" font-weight="bold">'
           f'{escape(title)}</text>']
    for i in range(6):
        y = ymin + (ymax - ymin) * i / 5
        out.append(f'<line x1="{ml}" x2="{ml + pw}" y1="{sy(y):.1f}" y2="{sy(y):.1f}" stroke="#e5e7eb"/>')
        out.append(f'<text x="{ml - 8}" y="{sy(y) + 4:.1f}" text-anchor="end">{y:.0f}</text>')
    for i in range(6):
        x = xmax * i / 5
        lbl = f"{x / 1000:.0f}k" if xmax >= 5000 else f"{x:.0f}"
        out.append(f'<text x="{sx(x):.1f}" y="{mt + ph + 18}" text-anchor="middle">{lbl}</text>')
    out.append(f'<rect x="{ml}" y="{mt}" width="{pw}" height="{ph}" fill="none" stroke="#374151"/>')
    out.append(f'<text x="{ml + pw / 2}" y="{height - 12}" text-anchor="middle">{escape(xlabel)}</text>')
    out.append(f'<text transform="translate(16,{mt + ph / 2}) rotate(-90)" text-anchor="middle">'
               f'{escape(ylabel)}</text>')
    for i, (name, pts) in enumerate(series):
        col = PALETTE[i % len(PALETTE)]
        path = " ".join(f"{'M' if j == 0 else 'L'}{sx(x):.1f},{sy(y):.1f}" for j, (x, y) in enumerate(pts))
        out.append(f'<path d="{path}" fill="none" stroke="{col}" stroke-width="2.2"/>')
        for x, y in pts:
            out.append(f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="2.6" fill="{col}"/>')
        ly = mt + 18 + 18 * i
        out.append(f'<line x1="{ml + pw - 230}" x2="{ml + pw - 206}" y1="{ly}" y2="{ly}" stroke="{col}" '
                   f'stroke-width="2.2"/>')
        out.append(f'<text x="{ml + pw - 200}" y="{ly + 4}">{escape(name)}</text>')
    out.append("</svg>")
    return "\n".join(out)
