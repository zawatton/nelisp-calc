"""Check fresh-process private-memory improvement against a matched baseline."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("baseline", type=Path)
parser.add_argument("candidate", type=Path)
args = parser.parse_args()
baseline, candidate = [json.loads(p.read_text(encoding="utf-8-sig"))
                       for p in (args.baseline, args.candidate)]
assert baseline["session"] != candidate["session"], "Fresh independent processes required"
assert baseline["runtimeSha256"] == candidate["runtimeSha256"], "Runtime mismatch"
for report in (baseline, candidate):
    assert report["exitCode"] == 0 and not report["stderr"], "Probe process failed"
    assert "MEMORY-STAGES-PASS" in report["stdout"], "Incomplete probe"
for stage in ("startup", "history"):
    before, after = [next(row["privateMiB"] for row in report["rows"]
                          if row["stage"] == stage)
                     for report in (baseline, candidate)]
    assert after <= before * 0.9, f"{stage}: private memory reduction below 10 percent"
    print(f"{stage}: {before:.3f} -> {after:.3f} MiB ({100 * (1-after/before):.2f} percent)")
print("MEMORY-FOOTPRINT-PASS")
