---
summary: "Synthetic helper benchmarks and pixel-equivalent token activity renders for PR #4328."
read_when:
  - Reviewing annual token activity update performance
---

# Token activity update proof

The immutable annual series reuses normalized calendar dates, visible indices and coverage counts.
Medium-date labels share at most 16 immutable formatter contexts, keyed by calendar, locale and time
zone. Weekly aggregates are built only in weekly/cumulative modes. The UI shares its existing
saturating addition and navigation data; direct fixture construction stays in the tests.

## Synthetic helper measurements

Measured on an Apple M3 Ultra using Apple Swift 6.4, the native build backend, four jobs and `-gnone`
in **debug** configuration. Both versions use the same `SpendActivityBenchmarkTests` helper with
365 synthetic days, Gregorian `Asia/Shanghai` and `zh_Hans_CN`. Each number is the median of 21
samples after three warmups. The baseline is `c3c6ce06120`; the updated measurements run the benchmark
alone after the focused compatibility tests. The shared host was busy, so these are diagnostic CPU
measurements, not frame-rate claims or timing assertions.

| Operation | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| 365 medium-date labels | 41.120750 ms | 0.471375 ms | 98.85% |
| Visit dates, count coverage, aggregate weeks | 1.564250 ms | 0.295834 ms | 81.09% |
| Build annual series and read coverage | 1.035000 ms | 0.816917 ms | 21.07% |

Run from the repository root in Bash:

```sh
source Scripts/test_environment.sh
CODEXBAR_ACTIVITY_BENCHMARK=1 \
  swift test --build-system native --jobs 4 -Xswiftc -gnone --filter SpendActivityBenchmarkTests
CODEXBAR_ACTIVITY_READABILITY_PROOF_DIR="$PWD/.build/activity-proof" \
  swift test --build-system native --jobs 4 -Xswiftc -gnone \
  --filter 'SpendActivityPerformanceTests|SpendActivityHeatmapTests|SpendActivityAppearanceTests|SpendActivityReadabilityRenderTests'
```

For a baseline comparison, apply only `SpendActivityBenchmarkTests.swift` to the baseline checkout.
The benchmark prints observations and checks a consumed result; it never asserts elapsed time.

## Visual and behavior equivalence

All **120** before/after images have identical dimensions and identical decoded RGBA bytes. The
matrix covers English, Chinese and Arabic/RTL, light/dark, widths 339/520/760, daily/weekly/cumulative,
and partial or recorded-zero data. All four native render/navigation tests passed on isolated retry;
the initial navigation run missed its first event-loop click. The unchanged scroll fixture does not
use the cached series. The 40 model/appearance/formatting tests also passed, including eight locales,
five calendars, three zones, concurrent formatters and midnight DST normalization.

These production-component captures use synthetic data and do not replace the installed application.
The additional [full settings runtime diagnostics](spend-activity-performance/README.md) exercise a freshly
built settings bundle at `f7a9968e3c4ebf8e958ebb86627f4b2ff10287fe` through scrolling, date inspection,
mode changes, day selection, refresh and time-zone changes. They include the diagnostic call-site patch,
source/executable hashes, a native action transcript and machine-verifiable runtime counters. No video
was recorded; no ProMotion frame-rate claim is made.

Before:

![Synthetic narrow dark annual heatmap before caching](https://github.com/user-attachments/assets/5b099e5f-8c6f-4c90-af4a-2c137170019c)

After (pixel-identical):

![Synthetic narrow dark annual heatmap after caching](https://github.com/user-attachments/assets/b02cdd31-c12c-4bfb-b55e-99185bacba86)
