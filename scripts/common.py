"""Shared helpers: build/run the Verilator testbench, parse logs, merge coverage."""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def sim_path(bug: str | None = None) -> Path:
    return ROOT / "build" / (bug or "clean") / "Vtb_top"


def build(bug: str | None = None, quiet: bool = True) -> Path:
    cmd = ["make", "--no-print-directory", "build"]
    if bug:
        cmd.append(f"BUG={bug}")
    t0 = time.time()
    res = subprocess.run(cmd, cwd=ROOT, capture_output=quiet, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"build failed for {bug or 'clean'}:\n{res.stdout}\n{res.stderr}")
    if not quiet:
        print(f"built {bug or 'clean'} in {time.time() - t0:.0f}s")
    return sim_path(bug)


@dataclass
class RunResult:
    test: str
    seed: int
    variant: str
    log: str
    passed: bool = False
    n_error: int = 0
    n_fatal: int = 0
    error_ids: dict = field(default_factory=dict)
    first_error: dict | None = None
    requests: int = 0
    reads_ok: int = 0
    writes_ok: int = 0
    mismatches: int = 0
    end_cycle: int = 0
    coverage_pct: float = 0.0
    wall_s: float = 0.0
    cov_file: str = ""
    extra: list = field(default_factory=list)

    def to_dict(self):
        return asdict(self)


ERR_RE = re.compile(r"^(UVM_ERROR|UVM_FATAL) @ \S+: (\S+) \[(\S+)\] (?:\(cycle (\d+)\) )?(.*)$")
ID_COUNT_RE = re.compile(r"^\[(\S+)\]\s+(\d+)$")


def parse_log(path: Path, res: RunResult) -> RunResult:
    text = path.read_text(errors="replace")
    lines = text.splitlines()
    in_ids = False
    error_ids_seen = set()
    for i, ln in enumerate(lines):
        m = ERR_RE.match(ln)
        if m:
            sev, src, rid, cyc, msg = m.groups()
            error_ids_seen.add(rid)
            if res.first_error is None:
                # multi-line messages (scoreboard) continue on indented lines
                cont = []
                for nxt in lines[i + 1:i + 6]:
                    if nxt.startswith("      "):
                        cont.append(nxt.strip())
                    else:
                        break
                res.first_error = {
                    "severity": sev, "id": rid, "source": src,
                    "cycle": int(cyc) if cyc else None,
                    "message": " | ".join([msg.strip()] + cont),
                }
        if ln.startswith("** Report counts by id"):
            in_ids = True
            continue
        if in_ids:
            m2 = ID_COUNT_RE.match(ln.strip())
            if m2:
                if m2.group(1) in error_ids_seen:
                    res.error_ids[m2.group(1)] = int(m2.group(2))
            elif ln.strip() == "":
                in_ids = False
    m = re.search(r"^UVM_ERROR :\s+(\d+)", text, re.M)
    res.n_error = int(m.group(1)) if m else 0
    m = re.search(r"^UVM_FATAL :\s+(\d+)", text, re.M)
    res.n_fatal = int(m.group(1)) if m else 0
    m = re.search(r"requests accepted : (\d+)", text)
    res.requests = int(m.group(1)) if m else 0
    m = re.search(r"reads checked OK  : (\d+)", text)
    res.reads_ok = int(m.group(1)) if m else 0
    m = re.search(r"writes acked      : (\d+)", text)
    res.writes_ok = int(m.group(1)) if m else 0
    m = re.search(r"data mismatches   : (\d+)", text)
    res.mismatches = int(m.group(1)) if m else 0
    m = re.search(r"finished at cycle (\d+)", text)
    res.end_cycle = int(m.group(1)) if m else 0
    m = re.search(r"functional coverage ([0-9.]+)%", text)
    res.coverage_pct = float(m.group(1)) if m else 0.0
    if res.requests == 0:
        # quit early on errors: estimate progress from the progress messages
        prog = re.findall(r"\[SB_PROGRESS\] (?:\(cycle \d+\) )?(\d+) requests accepted", text)
        if prog:
            res.requests = int(prog[-1])
    res.passed = ("*** TEST PASSED ***" in text) and res.n_error == 0 and res.n_fatal == 0
    return res


def run_sim(test: str, seed: int, out_dir: Path, bug: str | None = None,
            num_txn: int | None = None, extra: list[str] | None = None,
            timeout: int = 3600) -> RunResult:
    out_dir.mkdir(parents=True, exist_ok=True)
    log = out_dir / "sim.log"
    cov = out_dir / "cov.json"
    args = [str(sim_path(bug)), f"+UVM_TESTNAME={test}", f"+verilator+seed+{seed}",
            "+verilator+error+limit+100000", f"+COV_FILE={cov}"]
    if num_txn:
        args.append(f"+NUM_TXN={num_txn}")
    args += extra or []
    t0 = time.time()
    with open(log, "w") as fh:
        fh.write("# cmd: " + " ".join(args) + "\n")
        fh.flush()
        try:
            subprocess.run(args, cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT, timeout=timeout)
        except subprocess.TimeoutExpired:
            fh.write("\n# TIMEOUT\n")
    res = RunResult(test=test, seed=seed, variant=bug or "clean", log=str(log.relative_to(ROOT)),
                    extra=list(extra or []))
    res.wall_s = round(time.time() - t0, 1)
    parse_log(log, res)
    if cov.exists():
        res.cov_file = str(cov.relative_to(ROOT))
    return res


# ---------------------------------------------------------------------------
# Coverage
# ---------------------------------------------------------------------------
def load_cov(path: Path) -> dict[str, int]:
    return json.loads(Path(path).read_text())["bins"]


def group_of(bin_name: str) -> str:
    return bin_name.split(".", 1)[0]


def fmt_count(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1e6:.1f}M"
    if n >= 10_000:
        return f"{n / 1e3:.0f}k"
    if n >= 1000:
        return f"{n / 1e3:.1f}k"
    return str(n)


def rel(p: Path | str) -> str:
    return os.path.relpath(p, ROOT)
