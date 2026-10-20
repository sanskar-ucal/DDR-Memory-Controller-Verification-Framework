#!/usr/bin/env python3
"""Render a window of a VCD file as an SVG waveform (no external dependencies).

Signals are sampled once per clock cycle (value visible after each rising
edge) and labelled with the testbench cycle counter, so the columns line up
with the cycle numbers printed in UVM/SVA messages.

    python3 scripts/vcdwave.py waves.vcd --center 1234 --out wave.svg
"""

from __future__ import annotations

import argparse
from pathlib import Path
from xml.sax.saxutils import escape

CLK = "tb_top.clk"
CYCLE = "tb_top.hif.cycle"
DUT = "tb_top.u_dut"

BANK_STATE = {0: "IDLE", 1: "ACTVTG", 2: "ACTIVE", 3: "PRECHG"}
REF_STATE = {0: "IDLE", 1: "DRAIN", 2: "PREA_W", 3: "REFRSH"}
CMD = {0b0000: "MRS", 0b0001: "REF", 0b0010: "PRE", 0b0011: "ACT", 0b0100: "WR", 0b0101: "RD"}


def parse_vcd(path: Path, wanted: set[str], c_lo: int, c_hi: int) -> list[dict]:
    """Return one dict per clock cycle in [c_lo, c_hi] mapping signal -> int value."""
    ids: dict[str, list[str]] = {}
    scope: list[str] = []
    cur: dict[str, int] = {}
    samples: list[dict] = []
    need = set(wanted) | {CLK, CYCLE}
    in_defs = True
    clk_rose = False
    prev_clk = 0

    def finalize():
        nonlocal clk_rose
        if clk_rose:
            cyc = cur.get(CYCLE, -1)
            if c_lo <= cyc <= c_hi:
                samples.append(dict(cur))
            clk_rose = False
            return cyc
        return None

    with open(path, "r", errors="replace") as fh:
        for line in fh:
            if in_defs:
                tok = line.split()
                if not tok:
                    continue
                if tok[0] == "$scope":
                    scope.append(tok[2])
                elif tok[0] == "$upscope":
                    scope.pop()
                elif tok[0] == "$var":
                    full = ".".join(scope + [tok[4]])
                    if full in need:
                        ids.setdefault(tok[3], []).append(full)
                elif tok[0] == "$enddefinitions":
                    in_defs = False
                continue
            c = line[0] if line else ""
            if c == "#":
                cyc = finalize()
                if cyc is not None and cyc > c_hi:
                    break
            elif c in "01xzXZ":
                code = line[1:].strip()
                if code in ids:
                    v = 1 if c == "1" else 0
                    for n in ids[code]:
                        if n == CLK:
                            if v == 1 and prev_clk == 0:
                                clk_rose = True
                            prev_clk = v
                        cur[n] = v
            elif c == "b":
                val, code = line[1:].split()
                if code in ids:
                    try:
                        v = int(val.replace("x", "0").replace("z", "0"), 2)
                    except ValueError:
                        v = 0
                    for n in ids[code]:
                        cur[n] = v
        finalize()
    return samples


CMD_SIGS = ["tb_top.dif.cs_n", "tb_top.dif.ras_n", "tb_top.dif.cas_n", "tb_top.dif.we_n",
            "tb_top.dif.ba", "tb_top.dif.addr"]


def dram_cmd(s: dict) -> str:
    c = (s.get("tb_top.dif.cs_n", 1) << 3) | (s.get("tb_top.dif.ras_n", 1) << 2) | \
        (s.get("tb_top.dif.cas_n", 1) << 1) | s.get("tb_top.dif.we_n", 1)
    name = CMD.get(c)
    if name == "PRE" and (s.get("tb_top.dif.addr", 0) >> 10) & 1:
        return "PREA"
    return name or ""


def dram_target(s: dict) -> str:
    name = dram_cmd(s)
    ba, addr = s.get("tb_top.dif.ba", 0), s.get("tb_top.dif.addr", 0)
    if name == "ACT":
        return f"b{ba} r{addr & 0xFFF:x}"
    if name in ("RD", "WR"):
        return f"b{ba} c{addr & 0xFF:x}"
    if name == "PRE":
        return f"b{ba}"
    return ""


def default_rows(extra: list[tuple] | None = None) -> list[tuple]:
    """(label, kind, signals, formatter)  kind: 'bit' | 'bus'."""
    rows = [
        ("DRAM command", "bus", CMD_SIGS, dram_cmd),
        ("  bank / address", "bus", CMD_SIGS, dram_target),
    ]
    for b in range(4):
        sig = f"{DUT}.bank_state[{b}]"
        rows.append((f"bank{b} FSM", "bus", [sig], lambda s, sig=sig: BANK_STATE.get(s.get(sig, 0), "?")))
    rows.append(("refresh FSM", "bus", [f"{DUT}.ref_state"],
                 lambda s: REF_STATE.get(s.get(f"{DUT}.ref_state", 0), "?")))
    rows += [
        ("dq write data valid", "bit", ["tb_top.dif.wdata_valid"], None),
        ("dq read data valid", "bit", ["tb_top.dif.rdata_valid"], None),
        ("host req_valid", "bit", ["tb_top.hif.req_valid"], None),
        ("host req_ready", "bit", ["tb_top.hif.req_ready"], None),
        ("host rd_valid", "bit", ["tb_top.hif.rd_valid"], None),
        ("host rd_id", "bus", ["tb_top.hif.rd_valid", "tb_top.hif.rd_id"],
         lambda s: str(s.get("tb_top.hif.rd_id", 0)) if s.get("tb_top.hif.rd_valid") else ""),
    ]
    return rows + (extra or [])


def render(samples: list[dict], rows: list[tuple], markers: list[tuple], title: str) -> str:
    cw, lw, rh, top = 46, 170, 26, 64
    n = len(samples)
    width = lw + cw * n + 20
    height = top + rh * len(rows) + 40
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
         f'font-family="Menlo,Consolas,monospace" font-size="10">',
         f'<rect width="{width}" height="{height}" fill="white"/>',
         f'<text x="10" y="18" font-size="13" font-weight="bold" font-family="Helvetica,Arial,sans-serif">'
         f'{escape(title)}</text>']
    cycles = [s.get(CYCLE, 0) for s in samples]
    # markers (behind everything)
    for cyc, label, color in markers:
        if cyc in cycles:
            x = lw + cw * cycles.index(cyc)
            o.append(f'<rect x="{x}" y="{top - 14}" width="{cw}" height="{rh * len(rows) + 14}" '
                     f'fill="{color}" fill-opacity="0.13" stroke="{color}" stroke-width="1.2"/>')
            o.append(f'<text x="{x + cw / 2}" y="{top - 18}" text-anchor="middle" fill="{color}" '
                     f'font-weight="bold">{escape(label)}</text>')
    # cycle ruler
    for i, cyc in enumerate(cycles):
        x = lw + cw * i
        o.append(f'<line x1="{x}" x2="{x}" y1="{top - 8}" y2="{top + rh * len(rows)}" stroke="#eef0f3"/>')
        o.append(f'<text x="{x + cw / 2}" y="{top - 3}" text-anchor="middle" fill="#6b7280">{cyc}</text>')
    o.append(f'<text x="8" y="{top - 3}" fill="#6b7280">cycle</text>')
    for r, (label, kind, _sigs, fmt) in enumerate(rows):
        y0 = top + rh * r
        ym = y0 + rh / 2
        o.append(f'<text x="8" y="{ym + 4}" fill="#111827">{escape(label)}</text>')
        o.append(f'<line x1="{lw}" x2="{lw + cw * n}" y1="{y0 + rh}" y2="{y0 + rh}" stroke="#f3f4f6"/>')
        if kind == "bit":
            sig = _sigs[0]
            pts = []
            for i, s in enumerate(samples):
                v = s.get(sig, 0)
                y = y0 + 5 if v else y0 + rh - 5
                pts += [(lw + cw * i, y), (lw + cw * (i + 1), y)]
            d = " ".join(f"{'M' if j == 0 else 'L'}{x},{y}" for j, (x, y) in enumerate(pts))
            o.append(f'<path d="{d}" fill="none" stroke="#059669" stroke-width="1.6"/>')
        else:
            vals = [fmt(s) for s in samples]
            i = 0
            while i < n:
                j = i
                while j + 1 < n and vals[j + 1] == vals[i]:
                    j += 1
                x0, x1 = lw + cw * i, lw + cw * (j + 1)
                v = vals[i]
                if v in ("", "IDLE"):
                    o.append(f'<line x1="{x0}" x2="{x1}" y1="{ym}" y2="{ym}" stroke="#9ca3af"/>')
                    if v:
                        o.append(f'<text x="{(x0 + x1) / 2}" y="{ym - 3}" text-anchor="middle" '
                                 f'fill="#9ca3af">{v}</text>')
                else:
                    e = 4
                    fill = "#dbeafe" if _sigs is CMD_SIGS else "#fef3c7"
                    o.append(f'<path d="M{x0},{ym} L{x0 + e},{y0 + 4} L{x1 - e},{y0 + 4} L{x1},{ym} '
                             f'L{x1 - e},{y0 + rh - 4} L{x0 + e},{y0 + rh - 4} Z" fill="{fill}" '
                             f'stroke="#374151" stroke-width="0.8"/>')
                    max_chars = max(1, int((x1 - x0 - 6) / 6.1))
                    txt = v if len(v) <= max_chars else v[:max_chars]
                    o.append(f'<text x="{(x0 + x1) / 2}" y="{ym + 3.5}" text-anchor="middle">{escape(txt)}</text>')
                i = j + 1
    o.append("</svg>")
    return "\n".join(o)


def make_svg(vcd: Path, center: int, out: Path, title: str, before: int = 22, after: int = 6,
             extra_rows: list[tuple] | None = None, markers: list[tuple] | None = None):
    rows = default_rows(extra_rows)
    wanted = {s for _, _, sigs, _ in rows for s in sigs}
    samples = parse_vcd(vcd, wanted, center - before, center + after)
    out.write_text(render(samples, rows, markers or [(center, "error", "#dc2626")], title))
    return len(samples)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("vcd")
    ap.add_argument("--center", type=int, required=True, help="cycle to highlight")
    ap.add_argument("--before", type=int, default=22)
    ap.add_argument("--after", type=int, default=6)
    ap.add_argument("--out", default="wave.svg")
    ap.add_argument("--title", default="")
    a = ap.parse_args()
    n = make_svg(Path(a.vcd), a.center, Path(a.out), a.title or a.vcd, a.before, a.after)
    print(f"wrote {a.out} ({n} cycles)")


if __name__ == "__main__":
    main()
