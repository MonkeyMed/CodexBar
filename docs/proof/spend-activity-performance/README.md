# Full Usage & Spend runtime diagnostics

Captured on 2026-10-08 from a freshly built macOS settings bundle using the production code at
`f7a9968e3c4ebf8e958ebb86627f4b2ff10287fe`. Subsequent proof-only changes do not change that production source.
This is a running full settings window, not an isolated heatmap or copied helper benchmark.
No video was recorded. The artifacts contain only synthetic data, relative source paths, and aggregate counters.

The 2026-10-08 synchronizations with main (`f8b75cf2a`, then `08eb56931`) preserve the heatmap and app entry
source byte for byte; the committed verifier still passes. They also import upstream provider, menu, account,
and spend-trend changes. This capture documents the pinned build above; it does not claim runtime validation
of those newer upstream changes.

The route is `SettingsWindowController` → `PreferencesView` → `SpendDashboardPane` →
`UsageStore.sharedSpendDashboardController` → `SpendActivityHeatmapView`. The fixture reuses the repository's
existing full-settings launcher with four synthetic sources and explicit annual token-history coverage.
It includes nonzero, zero, unavailable, and trailing unscanned days. Real provider startup is bypassed;
dictionary-backed settings, temporary config files, a synthetic home, and test isolation flags are used.

The diagnostic build temporarily adds counters at the production cache, date lookup, body, aggregation,
and tooltip call sites. [The exact taps](diagnostic-instrumentation.patch) are disclosed and restored after
building; the shipping source has no diagnostic branches. [The build receipt](build-receipt.json) pins the
original source hashes, executable hash, launcher hash, and diagnostic helper hash.

Native accessibility actions were used to scroll the complete page, inspect daily dates, switch to weekly
and cumulative modes, click a calendar date, clear it, refresh, change the reporting time zone to UTC,
and return to Asia/Shanghai. [The action transcript](ui-actions.json) records the observed UI results.
[The runtime log](runtime-diagnostics.json) records actual production call counts and controller state.

| Runtime observation | Result |
| --- | --- |
| Initial daily accessibility labels | 365 distinct dates checked; one formatter creation, 729 cache hits |
| Complete settings-page scroll | Main content offset changed from the top to 2,243 points |
| Daily date inspection | Four tooltip renders; 1,468 additional formatter hits; no new formatter |
| Weekly and cumulative mode | One aggregation in each mode; none in daily-mode checkpoints |
| Calendar click | Selected `2026-04-07` reached the shared controller and the page's date chip |
| Refresh | Completed with 365 activity days and retained formatter cache |
| UTC → Asia/Shanghai | One new UTC formatter; zero creations when returning to the retained Shanghai context |
| Whole diagnostic session | 9,375 formatter hits, two creations, 19,760 cached date lookups |
| Runtime compatibility oracle | 731 distinct date/context combinations; zero output mismatches |

The independent date oracle formats each unique date/context once using the pre-cache implementation.
It does not call the optimized helper, so its construction work is excluded from the cache counters.
The diagnostic build and accessibility queries add overhead: this evidence establishes after-fix execution,
UI updates, date inspection, and output compatibility. It is not a whole-app FPS or 120 Hz acceptance test.
Absent error counters in the JSON mean zero occurrences, which the verifier checks explicitly.

## Reproduce

From a clean checkout on macOS with the project toolchain:

```sh
python3 docs/proof/spend-activity-performance/build-diagnostic.py "$TMPDIR/activity-settings-diagnostic"
open "$TMPDIR/activity-settings-diagnostic/ActivitySettingsDiagnostic.app"
python3 docs/proof/spend-activity-performance/verify-diagnostic.py
```

The last command verifies the committed capture and that the production source still matches it. For a new
capture, perform the native actions listed in the transcript and write `{"action":"checkpoint","name":"…"}`
to `command.json` in the output directory after each step, using the recorded checkpoint names. The app writes
the counters and controller state to `runtime-diagnostics.json`. A `{"action":"finish"}` command captures the
final state and terminates the isolated app. Run the verifier with the output directory to check the new capture.
The fixture's historical dates are fixed; later captures can have different coverage and counters.
