#if DEBUG
import AppKit
import Foundation

/// Non-shipping counters. Only the full settings fixture calls start().
enum ActivityRuntimeDiagnostics {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var counts: [String: Int] = [:]
    private nonisolated(unsafe) static var previous: [String: Int] = [:]
    private nonisolated(unsafe) static var records: [[String: Any]] = []
    private nonisolated(unsafe) static var checkedDates: Set<String> = []
    private nonisolated(unsafe) static var output: URL?

    static func count(_ name: String) {
        self.lock.withLock { self.counts[name, default: 0] += 1 }
    }

    static func formatted(_ date: Date, calendar: Calendar, locale: Locale, zone: TimeZone, result: String) {
        let key = "\(calendar.identifier)|\(locale.identifier)|\(zone.identifier)|\(date.timeIntervalSince1970)"
        let needsCheck = self.lock.withLock { self.checkedDates.insert(key).inserted }
        guard needsCheck else { return }
        // Compatibility oracle is intentionally outside the optimized cache and is not timed.
        let reference = DateFormatter()
        reference.locale = locale
        reference.calendar = calendar
        reference.timeZone = zone
        reference.dateStyle = .medium
        reference.timeStyle = .none
        self.count("runtime_date_checks")
        if reference.string(from: date) != result { self.count("runtime_date_mismatches") }
    }

    @MainActor
    static func start(window: NSWindow, settings: SettingsStore, controller: SpendDashboardController) {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_ACTIVITY_DIAGNOSTIC_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        self.lock.withLock { self.output = output }
        self.checkpoint("window-presented", window: window, settings: settings, controller: controller)
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let commandURL = output.appendingPathComponent("command.json")
                guard let data = try? Data(contentsOf: commandURL),
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let action = command["action"]
                else { continue }
                try? FileManager.default.removeItem(at: commandURL)
                switch action {
                case "checkpoint":
                    self.checkpoint(command["name"] ?? "checkpoint", window: window,
                                    settings: settings, controller: controller)
                case "time-zone":
                    settings.costUsageBucketTimeZoneIdentifier = command["value"] ?? "UTC"
                case "resize":
                    let width = Double(command["value"] ?? "") ?? 900
                    window.setContentSize(NSSize(width: width, height: 820))
                case "finish":
                    self.checkpoint("finished", window: window, settings: settings, controller: controller)
                    controller.stop()
                    settings.configFileWatcher?.stop()
                    NSApp.terminate(nil)
                default:
                    self.count("unknown_commands")
                }
            }
        }
    }

    @MainActor
    private static func checkpoint(_ name: String, window: NSWindow, settings: SettingsStore,
                                   controller: SpendDashboardController) {
        let scrollViews = self.scrollViews(in: window.contentView)
        let scrollState = scrollViews.filter { $0.documentView?.bounds.height ?? 0 > $0.contentSize.height }.map {
            ["offset_y": Double($0.contentView.bounds.minY),
             "document_height": Double($0.documentView?.bounds.height ?? 0),
             "viewport_height": Double($0.contentSize.height)]
        }
        self.lock.withLock {
            let delta = self.counts.mapValues { $0 }
                .map { ($0.key, $0.value - self.previous[$0.key, default: 0]) }
            self.records.append([
                "checkpoint": name,
                "counts": self.counts,
                "delta": Dictionary(uniqueKeysWithValues: delta),
                "selected_day": controller.selectedDay.map { self.dayKey($0, settings.costUsageBucketCalendar) }
                    ?? "none",
                "requested_days": controller.model.requestedDays,
                "activity_days": controller.model.tokenActivity.count,
                "refreshing": controller.isRefreshing,
                "currency_groups": controller.model.groups.count,
                "reporting_zone": settings.costUsageBucketTimeZoneIdentifier,
                "scroll": scrollState,
                "window_width": Double(window.contentLayoutRect.width),
                "window_visible": window.isVisible,
                "synthetic_only": true,
            ])
            self.previous = self.counts
            guard let output = self.output,
                  let data = try? JSONSerialization.data(withJSONObject: self.records,
                                                         options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? data.write(to: output.appendingPathComponent("runtime-diagnostics.json"), options: .atomic)
        }
    }

    @MainActor
    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? [])
            + view.subviews.flatMap { self.scrollViews(in: $0) }
    }

    private static func dayKey(_ day: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
#endif
