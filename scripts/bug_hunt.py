#!/usr/bin/env python3
"""Bug-injection campaign.

For every injected RTL defect (compile-time `ifdef BUG_*` in rtl/ddr_ctrl.sv):

  1. build the bug variant of the testbench;
  2. run the *standard* mixed regression test on N seeds with all checkers, and
     again with assertions disabled (+no_sva: scoreboard + DRAM model only);
  3. record which seeds fail, which checker layer fires first and when;
  4. re-run the earliest-failing seed with a VCD + DRAM command trace and render
     the failure window to docs/waves/<BUG>.svg, plus a log excerpt.

The clean design is run on the same seeds as a control (no false positives).
Results: reports/bug_detection.md and reports/bug_detection.json.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import ROOT, build, run_sim  # noqa: E402
import vcdwave  # noqa: E402

DUT = "tb_top.u_dut"
PSVA = f"{DUT}.u_protocol_sva"


def per_bank(label, base, fmt="{}"):
    sigs = [f"{DUT}.{base}[{b}]" for b in range(4)]
    return (label, "bus", sigs, lambda s: "/".join(fmt.format(s.get(x, 0)) for x in sigs))


def scalar(label, sig, fmt="{}"):
    return (label, "bus", [sig], lambda s: fmt.format(s.get(sig, 0)))


BUGS = [
    dict(name="BUG_TRCD_SHORT", title="tRCD timer reloaded one cycle short",
         category="DRAM timing",
         story="The ACT->column timer is loaded with tRCD-2 instead of tRCD-1, so the bank FSM reaches "
               "ACTIVE one cycle early and RD/WR is issued 3 cycles after ACT (tRCD = 4).",
         rows=[per_bank("rcd_cnt b0/b1/b2/b3", "rcd_cnt")]),
    dict(name="BUG_PREA_TRP", title="Refresh FSM skips the tRP wait after PREA",
         category="DRAM timing / refresh",
         story="After the all-bank precharge that starts a refresh, the FSM issues REF on the next "
               "cycle instead of waiting for every bank to finish precharging (tRP).",
         rows=[per_bank("rp_cnt b0/b1/b2/b3", "rp_cnt")]),
    dict(name="BUG_TRAS_IGNORED", title="tRAS not applied to the precharge timer",
         category="DRAM timing",
         story="ACT no longer loads the per-bank precharge timer with tRAS, so a row conflict right "
               "after a short access precharges the bank before the row restore completes.",
         rows=[per_bank("pre_cnt b0/b1/b2/b3", "pre_cnt")]),
    dict(name="BUG_TRFC_SHORT", title="tRFC halved",
         category="Refresh timing",
         story="The refresh-cycle timer is loaded with tRFC/2, so traffic resumes while the device "
               "is still refreshing.",
         rows=[scalar("rfc_cnt", f"{DUT}.rfc_cnt")]),
    dict(name="BUG_REF_DROP", title="Refresh request lost when a column command issues",
         category="Refresh scheduling",
         story="The tREFI tick is a one-cycle pulse; if the scheduler issues RD/WR in that cycle the "
               "pulse is dropped and that refresh never happens. Only visible under load.",
         rows=[scalar("refi_cnt", f"{DUT}.refi_cnt"), scalar("checker: cycles since REF", f"{PSVA}.s_ref")]),
    dict(name="BUG_RAW_HAZARD", title="FR-FCFS reorder ignores same-address hazards",
         category="Race condition / ordering",
         story="The scheduler's 'is there an older request to the same address' check is removed. A "
               "younger read can then bypass an older write to the same address (it prefers the "
               "current bus direction) and returns stale data. No DRAM protocol rule is broken.",
         rows=[per_bank("queue depth b0/b1/b2/b3", "q_cnt"), scalar("last CAS was write", f"{DUT}.last_cas_we")]),
    dict(name="BUG_ROW_ALIAS", title="Open-row comparator drops the row MSB",
         category="Address decode / data corruption",
         story="Row-hit detection compares only row[10:0]. A request to a row that differs from the "
               "open row only in bit 11 is treated as a hit and is served from the wrong row. The "
               "command stream is perfectly legal.",
         rows=[per_bank("open_row b0/b1/b2/b3", "open_row", "{:x}")]),
    dict(name="BUG_QUEUE_PUSHPOP", title="Queue tail index wrong on simultaneous push and pop",
         category="Concurrency / lost request",
         story="When a bank queue accepts a request in the same cycle it issues one, the new entry is "
               "written one slot too high. The request is lost and a stale entry is executed twice.",
         rows=[per_bank("queue depth b0/b1/b2/b3", "q_cnt"), scalar("push", f"{DUT}.push"),
               scalar("issuing CAS", f"{DUT}.iss_cas")]),
    dict(name="BUG_REF_SKIP_PRE", title="Refresh drain closes a single open bank without PRE",
         category="Illegal state transition",
         story="An 'optimization' in the refresh drain marks a lone open bank IDLE without issuing "
               "PREA, so REF is sent to a device with an open row and the controller's bank state "
               "no longer matches the DRAM.",
         rows=[scalar("checker: DRAM open banks", f"{PSVA}.open", "{:04b}")]),
    dict(name="BUG_WTR", title="Write-to-read turnaround uses tCCD",
         category="DRAM timing / data bus",
         story="After a WR the read timer is loaded with tCCD instead of CWL+1+tWTR, so a read can "
               "be issued before the write data has reached the array.",
         rows=[scalar("rd_cnt", f"{DUT}.rd_cnt"), scalar("wr_cnt", f"{DUT}.wr_cnt")]),
]

WHITEBOX = {"SVA_BANK_FSM", "SVA_BANK_CMD", "SVA_QUEUE", "SVA_STARVE", "SVA_REF_FSM", "SVA_REF_LOST",
            "SVA_INIT_FSM", "SVA_RD_CAPTURE"}


def layer(err_id: str | None) -> str:
    if not err_id:
        return "-"
    if err_id.startswith("SB_"):
        return "scoreboard"
    if err_id.startswith("DRAM_"):
        return "DRAM model"
    if err_id in WHITEBOX:
        return "SVA white-box"
    if err_id.startswith("SVA_HOST"):
        return "SVA host"
    if err_id.startswith("SVA_"):
        return "SVA protocol"
    return err_id


def rtl_snippet(bug: str) -> str:
    lines = (ROOT / "rtl/ddr_ctrl.sv").read_text().splitlines()
    out, depth, grab = [], 0, False
    for i, ln in enumerate(lines):
        s = ln.strip()
        if re.match(rf"`if(n)?def {bug}\b", s):
            grab, depth = True, 0
            out.append(f"// rtl/ddr_ctrl.sv:{i + 1}")
        if grab:
            out.append(ln)
            if s.startswith("`ifdef") or s.startswith("`ifndef"):
                depth += 1
            elif s.startswith("`endif"):
                depth -= 1
                if depth == 0:
                    grab = False
                    out.append("")
    return "\n".join(out).rstrip()


def excerpt(log: Path, center: int, before: int = 20) -> str:
    keep, errs = [], 0
    lines = log.read_text(errors="replace").splitlines()
    for i, ln in enumerate(lines):
        m = re.search(r"\[DRAM_CMD\] @(\d+)", ln)
        if m and center - before <= int(m.group(1)) <= center + 2:
            keep.append(ln.split("[DRAM_CMD] ", 1)[1].rstrip())
        elif re.match(r"^UVM_(ERROR|WARNING|FATAL) @", ln) and "NO_" not in ln and "NAMECHECK" not in ln:
            if errs < 6:
                keep.append(re.sub(r"^UVM_(\w+) @ \S+: \S+ ", r"UVM_\1 ", ln))
                for nxt in lines[i + 1:i + 6]:
                    if nxt.startswith("      "):
                        keep.append(nxt)
                    else:
                        break
            errs += 1
    return "\n".join(keep)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bugs", nargs="*", help="subset of bug names")
    ap.add_argument("--seeds", type=int, default=10)
    ap.add_argument("--seed-base", type=int, default=1)
    ap.add_argument("--test", default="ddr_rand_test")
    ap.add_argument("--num-txn", type=int, default=4000)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--no-build", action="store_true")
    a = ap.parse_args()

    bugs = [b for b in BUGS if not a.bugs or b["name"] in a.bugs]
    out = ROOT / "out" / "bugs"
    waves_dir = ROOT / "docs" / "waves"
    logs_dir = ROOT / "docs" / "bug_logs"
    waves_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)
    seeds = list(range(a.seed_base, a.seed_base + a.seeds))
    t0 = time.time()

    variants = [None] + [b["name"] for b in bugs]
    if not a.no_build:
        for v in variants:
            build(v, quiet=False)

    jobs = []
    for v in variants:
        for s in seeds:
            for sva in (True, False):
                if v is None and not sva:
                    continue
                jobs.append((v, s, sva))

    def run(job):
        v, s, sva = job
        d = out / (v or "clean") / f"s{s}{'' if sva else '_nosva'}"
        extra = ["+MAX_QUIT=10"] + ([] if sva else ["+no_sva"])
        return job, run_sim(a.test, s, d, v, a.num_txn, extra)

    print(f"{len(jobs)} detection runs ({a.test}, {a.num_txn} requests, seeds {seeds[0]}..{seeds[-1]})")
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        res = list(ex.map(run, jobs))
    table = {}
    for (v, s, sva), r in res:
        table.setdefault(v or "clean", {}).setdefault("sva" if sva else "nosva", {})[s] = r

    results = {}
    for v in variants:
        name = v or "clean"
        on = table[name]["sva"]
        off = table[name].get("nosva", {})
        fails = [s for s in seeds if not on[s].passed]
        fails_off = [s for s in seeds if off and not off[s].passed]
        firsts = [on[s].first_error for s in fails if on[s].first_error]
        layers = {}
        for fe in firsts:
            layers[layer(fe["id"])] = layers.get(layer(fe["id"]), 0) + 1
        ids = {}
        for s in fails:
            for k, n in on[s].error_ids.items():
                ids[k] = ids.get(k, 0) + n
        cycles = [fe["cycle"] for fe in firsts if fe.get("cycle") is not None]
        off_first = [off[s].first_error for s in fails_off if off[s].first_error]
        results[name] = dict(
            seeds=seeds, failing_seeds=fails, failing_seeds_no_sva=fails_off,
            first_layers=layers, error_ids=ids,
            first_cycle_min=min(cycles) if cycles else None,
            first_cycle_median=int(statistics.median(cycles)) if cycles else None,
            no_sva_first_ids=sorted({fe["id"] for fe in off_first}),
            no_sva_cycle_median=int(statistics.median([fe["cycle"] for fe in off_first if fe.get("cycle")]))
            if off_first else None,
            runs={s: on[s].to_dict() for s in seeds})
        print(f"  {name:20s} SVA on: {len(fails):2d}/{len(seeds)} fail   end-to-end only: "
              f"{len(fails_off) if v else '-':>2}/{len(seeds)}   first: {layers}")

    # reproducer runs with waveforms
    for b in bugs:
        r = results[b["name"]]
        if not r["failing_seeds"]:
            continue
        on = table[b["name"]]["sva"]
        seed = min(r["failing_seeds"], key=lambda s: on[s].first_error.get("cycle") or 1 << 60)
        d = out / b["name"] / "repro"
        vcd = d / "waves.vcd"
        rr = run_sim(a.test, seed, d, b["name"], a.num_txn,
                     [f"+WAVES={vcd}", "+TRACE", "+MAX_QUIT=4"])
        fe = rr.first_error or {}
        cyc = fe.get("cycle") or 0
        markers = [(cyc, f"{fe.get('id')}", "#dc2626")]
        sb_err = re.search(r"^UVM_ERROR .*\[SB_\w+\] \(cycle (\d+)\)", Path(ROOT / rr.log).read_text(), re.M)
        if sb_err and int(sb_err.group(1)) != cyc and 0 < int(sb_err.group(1)) - cyc <= 6:
            markers.append((int(sb_err.group(1)), "scoreboard", "#7c3aed"))
        svg = waves_dir / f"{b['name']}.svg"
        title = f"{b['name']}: {b['title']}  (test {a.test}, seed {seed}, first error at cycle {cyc})"
        vcdwave.make_svg(vcd, cyc, svg, title, before=22, after=6, extra_rows=b["rows"], markers=markers)
        (logs_dir / f"{b['name']}.log").write_text(
            f"# make run BUG={b['name']} TEST={a.test} SEED={seed} NUM_TXN={a.num_txn} TRACE=1\n"
            + excerpt(ROOT / rr.log, cyc) + "\n")
        r["repro"] = dict(seed=seed, first_error=fe, svg=os.path.relpath(svg, ROOT),
                          log=os.path.relpath(logs_dir / f"{b['name']}.log", ROOT))
        vcd.unlink(missing_ok=True)
        print(f"  waveform: {svg.relative_to(ROOT)} (seed {seed}, cycle {cyc})")

    write_report(bugs, results, a, seeds, time.time() - t0)


def write_report(bugs, results, a, seeds, wall):
    n = len(seeds)
    clean = results["clean"]
    L = ["# Bug-Injection Detection Report", "",
         f"Generated by `scripts/bug_hunt.py`: each bug variant runs the standard `{a.test}` "
         f"({a.num_txn} requests) on seeds {seeds[0]}-{seeds[-1]}, once with every checker enabled and "
         f"once with assertions disabled (`+no_sva`, i.e. scoreboard + DRAM model only). "
         f"Campaign wall time {wall / 60:.1f} min.", "",
         f"**Control:** the clean RTL passes {n - len(clean['failing_seeds'])}/{n} of the same seeds "
         "(no false positives).", "",
         "| Bug | Category | Detected (all checkers) | Detected (no SVA) | First detector | First detection cycle (min / median) | Reproducer |",
         "|---|---|---|---|---|---|---|"]
    for b in bugs:
        r = results[b["name"]]
        lay = ", ".join(f"{k} ({v})" for k, v in sorted(r["first_layers"].items(), key=lambda x: -x[1])) or "-"
        rep = r.get("repro")
        L.append(f"| [`{b['name']}`](#{b['name'].lower()}) | {b['category']} | "
                 f"{len(r['failing_seeds'])}/{n} | {len(r['failing_seeds_no_sva'])}/{n} | {lay} | "
                 f"{r['first_cycle_min']} / {r['first_cycle_median']} | "
                 f"{('seed ' + str(rep['seed'])) if rep else '-'} |")
    L += ["", "Reproduce any entry with `make run BUG=<bug> TEST=" + a.test + " SEED=<seed> NUM_TXN="
          + str(a.num_txn) + " WAVES=1 TRACE=1` (waveform in `out/<bug>/.../waves.vcd`).", ""]
    for b in bugs:
        r = results[b["name"]]
        rep = r.get("repro")
        L += [f"## {b['name']}", "", f"**{b['title']}** ({b['category']}). {b['story']}", "",
              "Injected defect:", "", "```systemverilog", rtl_snippet(b["name"]), "```", "",
              f"- Failing seeds (all checkers): {', '.join(map(str, r['failing_seeds'])) or 'none'}",
              f"- Failing seeds (scoreboard + DRAM model only): "
              f"{', '.join(map(str, r['failing_seeds_no_sva'])) or 'none'}"
              + (f" (first ids: {', '.join(r['no_sva_first_ids'])}, median cycle {r['no_sva_cycle_median']})"
                 if r['no_sva_first_ids'] else ""),
              "- Error ids raised: " + ", ".join(f"`{k}` x{v}" for k, v in
                                                 sorted(r["error_ids"].items(), key=lambda x: -x[1]))]
        if rep:
            fe = rep["first_error"]
            L += [f"- First failure (seed {rep['seed']}, cycle {fe.get('cycle')}): `[{fe.get('id')}]` "
                  f"{fe.get('message')}", "",
                  f"![{b['name']} waveform]({os.path.relpath(ROOT / rep['svg'], ROOT / 'reports')})", "",
                  f"Log excerpt: [`{rep['log']}`]({os.path.relpath(ROOT / rep['log'], ROOT / 'reports')})", ""]
    (ROOT / "reports").mkdir(exist_ok=True)
    (ROOT / "reports" / "bug_detection.md").write_text("\n".join(L) + "\n")
    slim = {k: {kk: vv for kk, vv in v.items() if kk != "runs"} for k, v in results.items()}
    (ROOT / "reports" / "bug_detection.json").write_text(json.dumps(slim, indent=1))
    print("wrote reports/bug_detection.md")


if __name__ == "__main__":
    main()
