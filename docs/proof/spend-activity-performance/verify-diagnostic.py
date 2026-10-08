"""Verify captured full-settings runtime evidence and its source provenance."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

proof = Path(__file__).resolve().parent
root = proof.parents[2]
output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else proof
receipt = json.loads((output / "build-receipt.json").read_text())
records = json.loads((output / "runtime-diagnostics.json").read_text())
by_name = {record["checkpoint"]: record for record in records}
required = ["daily-loaded", "daily-scrolled-bottom", "date-inspection-Oct-5", "weekly-mode",
            "cumulative-mode", "date-selected-Apr-7", "refresh-completed", "time-zone-UTC",
            "return-to-Shanghai", "finished"]
assert all(name in by_name for name in required)
for name in required:
    record = by_name[name]
    assert record["synthetic_only"] and record["window_visible"]
    assert record["activity_days"] == 365 and not record["refreshing"]

initial = by_name["daily-loaded"]["counts"]
assert initial["heatmap_body_daily"] > 0 and initial["daily_grid_body"] > 0
assert initial["formatter_cache_miss"] == 1 and initial["formatter_cache_hit"] >= 364
assert initial.get("weekly_aggregate", 0) == 0
assert max(s["offset_y"] for s in by_name["daily-scrolled-bottom"]["scroll"]) > 1000
assert by_name["date-inspection-Oct-5"]["delta"]["tooltip_render"] > 0
assert by_name["weekly-mode"]["delta"]["weekly_aggregate"] == 1
assert by_name["cumulative-mode"]["delta"]["weekly_aggregate"] == 1
assert by_name["date-selected-Apr-7"]["selected_day"] == "2026-04-07"
assert by_name["refresh-completed"]["selected_day"] == "none"
assert by_name["refresh-completed"]["delta"]["heatmap_body_daily"] > 0
assert by_name["time-zone-UTC"]["reporting_zone"] == "UTC"
assert by_name["time-zone-UTC"]["delta"]["formatter_cache_miss"] == 1
assert by_name["return-to-Shanghai"]["reporting_zone"] == "Asia/Shanghai"
assert by_name["return-to-Shanghai"]["delta"]["formatter_cache_miss"] == 0
assert by_name["return-to-Shanghai"]["delta"]["formatter_cache_hit"] > 0
final = by_name["finished"]["counts"]
assert final["runtime_date_checks"] >= 730
assert final.get("runtime_date_mismatches", 0) == 0
assert final.get("unexpected_provider_refresh", 0) == 0
assert final.get("unknown_commands", 0) == 0
assert receipt["real_accounts_or_history"] is False and receipt["video_recorded"] is False
for path, expected in receipt["original_production_source_sha256"].items():
    pinned = subprocess.check_output(["git", "show", receipt["code_revision"] + ":" + path], cwd=root)
    assert hashlib.sha256(pinned).hexdigest() == expected
    assert hashlib.sha256((root / path).read_bytes()).hexdigest() == expected
assert hashlib.sha256((output / "diagnostic-instrumentation.patch").read_bytes()).hexdigest() \
    == receipt["instrumentation_sha256"]
assert hashlib.sha256((proof / "ActivityRuntimeDiagnostics.swift").read_bytes()).hexdigest() \
    == receipt["diagnostic_helper_sha256"]
if (output / "fixture-launcher.swift").exists():
    assert hashlib.sha256((output / "fixture-launcher.swift").read_bytes()).hexdigest() == receipt["fixture_sha256"]
print(json.dumps({"status": "passed", "checkpoints": len(records), "runtime_date_checks": final["runtime_date_checks"],
                  "date_mismatches": final.get("runtime_date_mismatches", 0),
                  "formatter_cache_hits": final["formatter_cache_hit"],
                  "formatter_creations": final["formatter_cache_miss"],
                  "cached_date_lookups": final["cached_date_lookup"],
                  "weekly_aggregations": final["weekly_aggregate"]}, indent=2))
