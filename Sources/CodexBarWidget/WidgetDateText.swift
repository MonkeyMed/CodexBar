import CodexBarCore
import SwiftUI

enum WidgetDateText {
    static func age(_ date: Date) -> Text {
        self.offset(date)
    }

    static func offset(_ date: Date) -> Text {
        if #available(macOS 15, *) {
            return Text(.currentDate, format: .offset(
                to: date,
                allowedFields: [.day, .hour, .minute],
                maxFieldCount: 2,
                sign: .never))
        }
        return Text(date, style: .relative)
    }

    static func reset(_ date: Date) -> Text {
        if #available(macOS 15, *) {
            return Text(.currentDate, format: WidgetResetFormatStyle(resetAt: date))
        }
        return Text("Resets in \(Text(date, style: .relative))")
    }
}

/// Reuses the menu's compact countdown while letting WidgetKit advance the text without a reload.
@available(macOS 15, *)
struct WidgetResetFormatStyle: DiscreteFormatStyle {
    let resetAt: Date

    func format(_ now: Date) -> String {
        "Resets \(UsageFormatter.resetCountdownDescription(from: self.resetAt, now: now))"
    }

    func discreteInput(after input: Date) -> Date? {
        let remaining = self.resetAt.timeIntervalSince(input)
        guard remaining >= 1 else { return nil }
        if remaining <= 60 { return self.resetAt.addingTimeInterval(-1).addingTimeInterval(0.001) }
        let minutes = ceil(remaining / 60)
        return self.resetAt.addingTimeInterval(-(minutes - 1) * 60)
    }

    func discreteInput(before input: Date) -> Date? {
        let remaining = self.resetAt.timeIntervalSince(input)
        if remaining < 1 { return self.resetAt.addingTimeInterval(-1) }
        let minutes = ceil(remaining / 60)
        return self.resetAt.addingTimeInterval(-minutes * 60 - 0.001)
    }
}
