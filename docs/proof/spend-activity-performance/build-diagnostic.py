"""Build the complete production settings UI with synthetic data and temporary diagnostic taps.

Run from a clean checkout: python3 docs/proof/spend-activity-performance/build-diagnostic.py OUTPUT_DIR
The shipping entry point and heatmap are restored in finally. No new shipping code is retained.
"""
from pathlib import Path
import difflib
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
proof = Path(__file__).resolve().parent
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
entry = root / "Sources/CodexBar/CodexbarApp.swift"
heatmap = root / "Sources/CodexBar/SpendActivityHeatmap.swift"
fixture = root / "Sources/CodexBar/SpendDashboardAppProof.swift"
diagnostics = root / "Sources/CodexBar/ActivityRuntimeDiagnostics.swift"
template = root / "docs/proof/spend-chart-readability/SpendDashboardAppProof.swift"
originals = {path: path.read_bytes() for path in [entry, heatmap]}
assert not fixture.exists() and not diagnostics.exists(), "Do not overwrite existing work"


def replace_once(text, old, new):
    assert text.count(old) == 1, f"Expected exactly one instrumentation anchor: {old[:80]}"
    return text.replace(old, new, 1)


try:
    source = originals[entry].decode()
    source = replace_once(source, "        if MenuBarLayoutNativeProof.runIfRequested() {",
                          "        if SpendDashboardAppProof.runIfRequested() { return }\n"
                          "        if MenuBarLayoutNativeProof.runIfRequested() {")
    entry.write_text(source)
    source = originals[heatmap].decode()
    source = replace_once(source, "        let visible = dates.indices.filter { index in\n",
                          '        ActivityRuntimeDiagnostics.count("series_snapshot")\n'
                          '        let visible = dates.indices.filter { index in\n')
    source = replace_once(source, "        if self.dates.indices.contains(index) { return self.dates[index] }",
                          '        if self.dates.indices.contains(index) {\n'
                          '            ActivityRuntimeDiagnostics.count("cached_date_lookup")\n'
                          '            return self.dates[index]\n        }\n'
                          '        ActivityRuntimeDiagnostics.count("fallback_date_lookup")')
    source = replace_once(source, "            if let formatter = self.formatters[context] { return formatter }",
                          '            if let formatter = self.formatters[context] {\n'
                          '                ActivityRuntimeDiagnostics.count("formatter_cache_hit")\n'
                          '                return formatter\n            }\n'
                          '            ActivityRuntimeDiagnostics.count("formatter_cache_miss")')
    source = replace_once(source, "        return formatter.string(from: date)",
                          '        let result = formatter.string(from: date)\n'
                          '        ActivityRuntimeDiagnostics.formatted(date, calendar: context.calendar,\n'
                          '                                             locale: context.locale, zone: context.timeZone, result: result)\n'
                          '        return result')
    source = replace_once(source, "        let hasActivity = (self.series.daily.max() ?? 0) > 0",
                          '        let _ = ActivityRuntimeDiagnostics.count("heatmap_body_\\(self.mode.rawValue)")\n'
                          '        let hasActivity = (self.series.daily.max() ?? 0) > 0')
    source = replace_once(source, "        let levels = SpendActivityLevels.dailyLevels(self.series.daily)",
                          '        let _ = ActivityRuntimeDiagnostics.count("daily_grid_body")\n'
                          '        let levels = SpendActivityLevels.dailyLevels(self.series.daily)')
    source = replace_once(source, "            let anchorX = CGFloat(col) * pitch + pitch / 2",
                          '            let _ = ActivityRuntimeDiagnostics.count("tooltip_render")\n'
                          '            let anchorX = CGFloat(col) * pitch + pitch / 2')
    source = replace_once(source, "    func weeklyActivity() -> SpendActivityAggregateSeries {",
                          '    func weeklyActivity() -> SpendActivityAggregateSeries {\n'
                          '        ActivityRuntimeDiagnostics.count("weekly_aggregate")')
    heatmap.write_text(source)
    source = template.read_text()
    # The isolated bundle must never fall through to ordinary account/provider startup,
    # including when a UI automation client launches it without command-line arguments.
    source = source.replace(
        '        guard CommandLine.arguments.contains("--spend-dashboard-app-proof") else { return false }',
        '        let proofRoot = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()\n'
        '        let syntheticHome = proofRoot.appendingPathComponent("synthetic-home", isDirectory: true)\n'
        '        try? FileManager.default.createDirectory(at: syntheticHome, withIntermediateDirectories: true)\n'
        '        setenv("HOME", syntheticHome.path, 1)\n'
        '        setenv("CFFIXED_USER_HOME", syntheticHome.path, 1)\n'
        '        setenv("CODEXBAR_ACTIVITY_DIAGNOSTIC_DIR", proofRoot.path, 1)')
    source = source.replace('"settingsSpendDashboardPeriod": "rolling:90"',
                            '"settingsSpendDashboardPeriod": "all"')
    source = source.replace('ProofFixtures.inputs(days: 120, multipleProviders: true)',
                            'ProofFixtures.inputs(days: 365, multipleProviders: true)')
    source = replace_once(source, '                snapshot: snapshot)',
                          '                snapshot: snapshot,\n'
                          '                tokenActivityCache: try self.activityCache(now: now, source: source))')
    source = replace_once(source, '    static func inputs(days: Int = 14, multipleProviders: Bool = false)',
                          '''    static func activityCache(now: Date, source: Int) throws -> CostUsageTokenActivityCache {
        let calendar = self.calendar
        let today = calendar.startOfDay(for: now)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let daily = try (0..<365).map { (offset: Int) -> CostUsageDailyReport.Entry in
            let day = try self.unwrap(calendar.date(byAdding: .day, value: -offset, to: today))
            let tokens: Int? = source == 0 && [9, 37].contains(offset) ? nil
                : (offset.isMultiple(of: 11) ? 0 : 1000 * (source + 1) * (offset % 5 + 1))
            return CostUsageDailyReport.Entry(
                date: dayFormatter.string(from: day),
                inputTokens: nil, outputTokens: nil, totalTokens: tokens, costUSD: nil,
                modelsUsed: nil, modelBreakdowns: nil)
        }
        return CostUsageTokenActivityCache(
            daily: daily,
            coverageSinceKey: daily.last!.date,
            coverageUntilKey: daily.first!.date)
    }

    static func inputs(days: Int = 14, multipleProviders: Bool = false)''')
    source = source.replace('controller?.open(pane: .general)', 'controller?.open(pane: .usageSpend)')
    source = source.replace('UserDefaults.standard.set("en", forKey: "appLanguage")',
                            'UserDefaults.standard.set("en", forKey: "appLanguage")\n'
                            '        KeychainAccessGate.isDisabled = true')
    source = source.replace('settings.costUsageEnabled = true',
                            'settings.costUsageEnabled = true\n'
                            '                settings.refreshFrequency = .manual\n'
                            '                settings.statusChecksEnabled = false')
    source = replace_once(source, '                let inputs = try ProofFixtures.inputs',
                          '                store._test_providerRefreshOverride = { _ in\n'
                          '                    ActivityRuntimeDiagnostics.count("unexpected_provider_refresh")\n'
                          '                }\n'
                          '                store._test_widgetSnapshotSaveOverride = { _ in }\n'
                          '                let inputs = try ProofFixtures.inputs')
    source = replace_once(source, '                let selection = PreferencesSelection',
                          '                spendController.selectPeriod(.allTime)\n'
                          '                let selection = PreferencesSelection')
    source = replace_once(source, '                print("SYNTHETIC route:',
                          '                if let window = controller.window {\n'
                          '                    ActivityRuntimeDiagnostics.start(window: window, settings: settings,\n'
                          '                                                     controller: spendController)\n'
                          '                }\n'
                          '                print("SYNTHETIC route:')
    fixture.write_text(source)
    shutil.copyfile(proof / diagnostics.name, diagnostics)
    patch = "".join("".join(difflib.unified_diff(
        original.decode().splitlines(keepends=True), path.read_text().splitlines(keepends=True),
        fromfile="a/" + str(path.relative_to(root)), tofile="b/" + str(path.relative_to(root)), n=0))
        for path, original in originals.items())
    (output / "diagnostic-instrumentation.patch").write_text(patch)
    (output / "fixture-launcher.swift").write_text(fixture.read_text())
    subprocess.run(["swift", "build", "--product", "CodexBar"], cwd=root, check=True)
    binary_dir = root / ".build/debug"
    bundle = output / "ActivitySettingsDiagnostic.app"
    executable = bundle / "Contents/MacOS/ActivitySettingsDiagnostic"
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources = bundle / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    frameworks = bundle / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(binary_dir / "CodexBar", executable)
    executable.chmod(0o755)
    for resource in binary_dir.glob("*.bundle"):
        subprocess.run(["ditto", str(resource), str(resources / resource.name)], check=True)
    sparkle = next((root / ".build/artifacts").rglob("Sparkle.framework"))
    subprocess.run(["ditto", str(sparkle), str(frameworks / "Sparkle.framework")], check=True)
    with (bundle / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({
            "CFBundleName": "Activity Settings Diagnostic",
            "CFBundleDisplayName": "Activity Settings Diagnostic",
            "CFBundleIdentifier": "local.codexbar.activity-settings-diagnostic",
            "CFBundleExecutable": executable.name,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "NSHighResolutionCapable": True,
        }, file)
    subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(executable)], check=True)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    receipt = {
        "kind": "fresh full production settings UI; synthetic inputs; temporary diagnostic counters",
        "code_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "instrumentation_sha256": hashlib.sha256(patch.encode()).hexdigest(),
        "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
        "diagnostic_helper_sha256": hashlib.sha256(diagnostics.read_bytes()).hexdigest(),
        "launch_argument": "--spend-dashboard-app-proof",
        "route": ["SettingsWindowController", "PreferencesView", "SpendDashboardPane",
                  "UsageStore.sharedSpendDashboardController", "SpendActivityHeatmapView"],
        "real_accounts_or_history": False,
        "video_recorded": False,
        "configuration": "debug; measurements validate execution and compatibility, not FPS",
        "original_production_source_sha256": {
            str(path.relative_to(root)): hashlib.sha256(original).hexdigest()
            for path, original in originals.items()
        },
    }
    (output / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
finally:
    for path, original in originals.items():
        path.write_bytes(original)
    fixture.unlink(missing_ok=True)
    diagnostics.unlink(missing_ok=True)
