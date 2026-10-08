"""Verify production-source identity and native event receipts without accessing accounts."""
from pathlib import Path
import hashlib
import json
import sys

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
proof = Path(__file__).resolve().parent
receipt = json.loads((proof / "build-receipt.json").read_text())
events = [json.loads(line) for line in (proof / "native-events.jsonl").read_text().splitlines() if line]

source_identity = all(
    hashlib.sha256((root / path).read_bytes()).hexdigest() == expected
    for path, expected in receipt["production_source_sha256"].items()
)
fixture_identity = hashlib.sha256((proof / "HomebrewUpdateAppProof.swift").read_bytes()).hexdigest() == receipt["fixture_source_sha256"]
snapshots = [event for event in events if event["event"] == "native_snapshot"]
delivery = any(event["delivered_ids"] and event["silent"] and event["production_notification_delegate"] for event in snapshots)
denied_not_saved = any(event["authorization"] == 1 and not event["saved_submitted_version"] for event in snapshots)
about_transition_launches = []
for launch in {event["launch"] for event in events}:
    states = [event for event in snapshots if event["launch"] == launch]
    if any(not event["settings_visible"] and event["selected_pane"] == "general" for event in states) and any(
        event["settings_visible"] and event["selected_pane"] == "about" for event in states
    ):
        about_transition_launches.append(launch)

ui_path = proof / "ui-interactions.json"
ui = json.loads(ui_path.read_text()) if ui_path.exists() else {"interactions": []}
manual_about_launches = {
    action["launch"] for action in ui["interactions"] if action["action"] == "fixture_open_about"
}
notification_click_launches = sorted({
    action["launch"] for action in ui["interactions"]
    if action["action"] == "system_notification_click"
    and action.get("confirmed_notification_card") is True
    and action["launch"] in about_transition_launches
    and action["launch"] not in manual_about_launches
})

restart_dedup = False
disabled_restart = False
disabled_automatic_request = any(
    event["event"] == "automatic_check_requested" and not event["enabled"]
    and event["fetches_before"] == event["fetches_after"] == 0
    for event in events
)
for launch in [event for event in events if event["event"] == "launch"]:
    states = [event for event in snapshots if event["launch"] == launch["launch"]]
    if launch["saved_submitted_version"] and launch["saved_auto_check"] and any(
        event["fetch_count"] == 1 and event["saved_submitted_version"] == launch["saved_submitted_version"]
        and not event["delivered_ids"] for event in states
    ):
        restart_dedup = True
    if not launch["saved_auto_check"] and any(
        not event["controller_auto_check"] and event["fetch_count"] == 0 and not event["delivered_ids"]
        for event in states
    ):
        disabled_restart = True

result = {
    "production_source_identity": source_identity,
    "fixture_source_identity": fixture_identity,
    "real_silent_delivery": delivery,
    "denied_authorization_does_not_save_submission": denied_not_saved,
    "restart_deduplication": restart_dedup,
    "observed_about_transition_launches": sorted(about_transition_launches),
    "manual_about_open_launches": sorted(manual_about_launches),
    "native_notification_click_launches": notification_click_launches,
    "saved_disabled_preference_after_restart": disabled_restart,
    "disabled_automatic_request_performed_zero_fetches": disabled_automatic_request,
    "native_click_transitions_require_ui_transcript": True,
}
(proof / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
if not source_identity or not fixture_identity:
    raise SystemExit("Proof sources differ from the compiled receipt")
