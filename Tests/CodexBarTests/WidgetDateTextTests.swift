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
        let style = WidgetDateText.ageFormat(anchor).locale(Locale(identifier: "en_US"))
        let now = anchor.addingTimeInterval(5 * 60 + 10)
        #expect(style.format(now) == style.format(now.addingTimeInterval(1)))
        let next = try #require(style.discreteInput(after: now))
        #expect(next > now)
        #expect(next.timeIntervalSince(now) <= 60)
        #expect(style.format(next) != style.format(now))
        #expect(!String(style.format(now).characters).contains("second"))
    }

    @Test
    func `system reset format has compact minute precision and a zero endpoint`() {
        guard #available(macOS 15, *) else { return }
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        let style = WidgetDateText.resetFormat().locale(Locale(identifier: "en_US"))
        #expect(style.format(reset.addingTimeInterval(-(5 * 86400 + 23 * 3600))..<reset) == "5d 23h")
        #expect(style.format(reset.addingTimeInterval(-61)..<reset) == "1m")
        #expect(style.format(reset.addingTimeInterval(-60)..<reset) == "1m")
        #expect(style.format(reset.addingTimeInterval(-59)..<reset) == "0m")
        #expect(style.format(reset..<reset) == "0m")
    }
}
