import XCTest
@testable import StockDeck

final class TelegramSchedulerTests: XCTestCase {

    func testBeforeAnyScheduleDoesNotFire() {
        let schedules = ["07:30", "15:30"]
        let lastSent: [String: String] = [:]
        let today = "2026-09-25"
        let currentMinutes = 6 * 60 // 06:00

        let (due, latest) = PortfolioMonitor.evaluateDueSchedules(
            schedules: schedules,
            lastSent: lastSent,
            today: today,
            currentTotalMinutes: currentMinutes
        )

        XCTAssertTrue(due.isEmpty)
        XCTAssertNil(latest)
    }

    func testMorningScheduleFiresAndDoesNotRepeatSameDay() {
        let schedules = ["07:30", "15:30"]
        var lastSent: [String: String] = [:]
        let today = "2026-09-25"
        let currentMinutes = 7 * 60 + 35 // 07:35

        let (due1, latest1) = PortfolioMonitor.evaluateDueSchedules(
            schedules: schedules,
            lastSent: lastSent,
            today: today,
            currentTotalMinutes: currentMinutes
        )

        XCTAssertEqual(due1, ["07:30"])
        XCTAssertEqual(latest1, "07:30")

        // Mark as sent
        for s in due1 { lastSent[s] = today }

        // Next tick at 07:36: should not re-fire
        let (due2, latest2) = PortfolioMonitor.evaluateDueSchedules(
            schedules: schedules,
            lastSent: lastSent,
            today: today,
            currentTotalMinutes: 7 * 60 + 36
        )

        XCTAssertTrue(due2.isEmpty)
        XCTAssertNil(latest2)
    }

    func testAfternoonScheduleFiresLaterSameDay() {
        let schedules = ["07:30", "15:30"]
        let lastSent: [String: String] = ["07:30": "2026-09-25"]
        let today = "2026-09-25"
        let currentMinutes = 15 * 60 + 30 // 15:30

        let (due, latest) = PortfolioMonitor.evaluateDueSchedules(
            schedules: schedules,
            lastSent: lastSent,
            today: today,
            currentTotalMinutes: currentMinutes
        )

        XCTAssertEqual(due, ["15:30"])
        XCTAssertEqual(latest, "15:30")
    }

    func testWakeFromSleepPastMultipleSchedulesOnlyFiresLatest() {
        let schedules = ["07:30", "15:30", "21:00"]
        let lastSent: [String: String] = [:]
        let today = "2026-09-25"
        let currentMinutes = 16 * 60 // 16:00 (both 07:30 and 15:30 passed)

        let (due, latest) = PortfolioMonitor.evaluateDueSchedules(
            schedules: schedules,
            lastSent: lastSent,
            today: today,
            currentTotalMinutes: currentMinutes
        )

        // Both should be marked as handled so 07:30 is not sent later
        XCTAssertEqual(due, ["07:30", "15:30"])
        // But only 15:30 (the latest due) is fired
        XCTAssertEqual(latest, "15:30")
    }

    func testNextDayResetsSchedules() {
        let schedules = ["07:30"]
        let lastSent: [String: String] = ["07:30": "2026-09-25"]
        let newDay = "2026-09-26"
        let currentMinutes = 7 * 60 + 31 // 07:31 on new day

        let (due, latest) = PortfolioMonitor.evaluateDueSchedules(
            schedules: schedules,
            lastSent: lastSent,
            today: newDay,
            currentTotalMinutes: currentMinutes
        )

        XCTAssertEqual(due, ["07:30"])
        XCTAssertEqual(latest, "07:30")
    }
}
