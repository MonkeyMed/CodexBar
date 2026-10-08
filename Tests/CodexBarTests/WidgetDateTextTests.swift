import Foundation
import SwiftUI
import Testing
@testable import CodexBarWidget

@Suite("Widget live minute text")
struct WidgetDateTextTests {
    @Test
    func `system age format excludes seconds and advances at a minute boundary`() throws {
        guard #available(macOS 15, *) else { return }
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let style = SystemFormatStyle.DateOffset(
            to: anchor,
            allowedFields: [.day, .hour, .minute],
            maxFieldCount: 2,
            sign: .never).locale(Locale(identifier: "en_US"))
        let now = anchor.addingTimeInterval(5 * 60 + 10)
        #expect(style.format(now) == style.format(now.addingTimeInterval(1)))
        let next = try #require(style.discreteInput(after: now))
        #expect(next > now)
        #expect(next.timeIntervalSince(now) <= 60)
        #expect(style.format(next) != style.format(now))
        #expect(!String(style.format(now).characters).contains("second"))
    }

    @Test
    func `compact reset stays live across minute boundaries and expires`() throws {
        guard #available(macOS 15, *) else { return }
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        let style = WidgetResetFormatStyle(resetAt: reset)
        #expect(style.format(reset.addingTimeInterval(-(5 * 86400 + 23 * 3600))) == "Resets in 5d 23h")
        let now = reset.addingTimeInterval(-61)
        #expect(style.format(now) == "Resets in 2m")
        let next = try #require(style.discreteInput(after: now))
        #expect(next == reset.addingTimeInterval(-60))
        #expect(style.format(next) == "Resets in 1m")
        let previous = try #require(style.discreteInput(before: next))
        #expect(previous < next)
        #expect(style.format(previous) == "Resets in 2m")
        let expired = try #require(style.discreteInput(after: next))
        #expect(style.format(expired) == "Resets now")
        #expect(style.discreteInput(after: expired) == nil)
    }
}
