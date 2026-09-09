import XCTest

/// Drives Empo and the Settings app on a phone for the device checks
/// of ticket 020 that need taps. Run one check at a time:
///
///   xcodebuild test -project Empo.xcodeproj -scheme EmpoChecks \
///     -destination 'id=<udid>' -only-testing:EmpoChecks/DeviceChecks/testLowDataModeMidRun
///
/// Every step writes a timestamped line to the test log and a
/// screenshot to the result bundle.
///
/// This is a hand-run device pass and never a CI job: a check holds
/// the phone for minutes, toggles Low Data Mode and Low Power Mode in
/// Settings, and its teardown closes Empo, which ends a run or a game.
final class DeviceChecks: XCTestCase {

    private let empo = XCUIApplication(bundleIdentifier: "sh.mateo.empo.dev2")
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Probes

    /// Prints the element trees of the two Settings pages the checks
    /// touch, so the paths below match this iOS build.
    func testDumpSettings() {
        settings.launch()
        openWiFiNetworkDetails()
        note("Wi-Fi network details:\n\(settings.debugDescription)")
        shot("wifi-details")
        settings.terminate()
        settings.launch()
        openBattery()
        note("Battery:\n\(settings.debugDescription)")
        shot("battery")
    }

    /// Launches Empo and prints its tree, to learn the pill and the
    /// library labels.
    func testDumpEmpo() {
        launchEmpo(arguments: ["-debugLogs", "YES"])
        sleep(3)
        note("Empo:\n\(empo.debugDescription)")
        shot("empo")
    }

    // MARK: - 007 check 5

    func testLowDataModeMidRun() {
        setLowDataMode(false)
        launchEmpo(arguments: ["-debugLogs", "YES", "-backupPressNow", "YES"])
        waitForPill(prefix: "Backing up", timeout: 600)
        setLowDataMode(true)
        empo.activate()
        sleep(20)
        note("pill 20 s after Low Data Mode on: \(pillLine())")
        shot("low-data-on")
        sleep(40)
        note("pill 60 s after Low Data Mode on: \(pillLine())")
        setLowDataMode(false)
        empo.activate()
        waitForPill(prefix: "Backup complete", timeout: 1800)
        shot("low-data-done")
    }

    func testLowDataModeBeforeRun() {
        setLowDataMode(true)
        launchEmpo(arguments: ["-debugLogs", "YES", "-backupPressNow", "YES"])
        // The pill needs a plan with bytes, and the run stands at its
        // first request. The Backups screen run block reads the hold.
        sleep(30)
        note("pill 30 s after the press: \(pillLine())")
        shot("low-data-before-hold")
        setLowDataMode(false)
        empo.activate()
        waitForPill(prefix: "Backing up", timeout: 60)
        waitForPill(prefix: "Backup complete", timeout: 900)
        shot("low-data-before-done")
    }

    // MARK: - 007 check 6

    func testLowPowerModeMidRun() {
        setLowPowerMode(false)
        launchEmpo(arguments: ["-debugLogs", "YES", "-backupPressNow", "YES"])
        waitForPill(prefix: "Checking", timeout: 60)
        setLowPowerMode(true)
        empo.activate()
        sleep(10)
        note("pill 10 s after Low Power Mode on: \(pillLine())")
        shot("low-power-on")
        sleep(50)
        note("pill 60 s after Low Power Mode on: \(pillLine())")
        setLowPowerMode(false)
        empo.activate()
        sleep(10)
        note("pill 10 s after Low Power Mode off: \(pillLine())")
        waitForPill(prefix: "Backup complete", timeout: 600)
    }

    // MARK: - 007 check 7

    /// Opens a game while the run uploads. The game keeps running at
    /// the end, because Empo has no quit button. Close it from the
    /// app switcher by hand.
    func testGameLaunchMidRun() {
        launchEmpo(arguments: ["-debugLogs", "YES", "-backupPressNow", "YES"])
        waitForPill(prefix: "Backing up", timeout: 600)
        let card = empo.buttons["In Search of Immortality"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no game card")
        card.tap()
        note("tapped the game card")
        sleep(15)
        shot("game-open")
        note("pill exists after 15 s in the game: \(pill.exists)")
        sleep(45)
        note("pill exists after 60 s in the game: \(pill.exists)")
    }

    // MARK: - 018 checks 1 to 4, and 016 check 5

    /// Watches a large first backup from the first pill to past 100 MB,
    /// taps the pill into the Backups sheet, then kills Empo. The next
    /// launch asks the resume question. A second kill with the
    /// question open, then a third launch, shows whether it asks again.
    func testForceQuitPast100MB() {
        launchEmpo(arguments: ["-debugLogs", "YES", "-backupPressNow", "YES"])
        watchPill(until: "Backing up", timeout: 900)
        shot("uploading")
        pill.tap()
        note("tapped the pill")
        let title = empo.navigationBars["Backups"].firstMatch
        note("Backups sheet opens: \(title.waitForExistence(timeout: 10))")
        note("run block header shows: \(empo.staticTexts["Backing up"].firstMatch.exists)")
        note("Pause button shows: \(empo.buttons["Pause"].firstMatch.exists)")
        note("Targets header shows: \(empo.staticTexts["Targets"].firstMatch.exists)")
        shot("backups-sheet-mid-run")
        title.swipeDown()
        sleep(2)
        note("sheet closed: \(!title.exists), pill: \(pillLine())")
        killPast100MB()
        launchEmpo(arguments: ["-debugLogs", "YES"])
        note("resume question shows: \(resumeTitle.waitForExistence(timeout: 15))")
        note("detail: \(resumeDetail)")
        shot("resume-question")
        empo.terminate()
        note("killed Empo with the question open")
        sleep(3)
        launchEmpo(arguments: ["-debugLogs", "YES"])
        note("resume question shows after the second kill: \(resumeTitle.waitForExistence(timeout: 15))")
        shot("third-launch")
    }

    /// Answers Not now. The record stays, and the next trigger, the
    /// foreground pass 30 s after launch, picks the run up.
    func testResumeLater() {
        ensureResumeQuestion()
        empo.buttons["Not now"].firstMatch.tap()
        note("tapped Not now, question gone: \(!resumeTitle.waitForExistence(timeout: 3))")
        shot("after-not-now")
        watchPill(until: "Backing up", timeout: 240)
        shot("resumed-after-not-now")
        sleep(10)
        note("pill 10 s later: \(pillLine())")
    }

    /// Answers Stop backup twice. The staging and the outbox go, and
    /// the foreground pass treats the game as any other.
    func testResumeStop() {
        ensureResumeQuestion()
        empo.buttons["Stop backup"].firstMatch.tap()
        let stopTitle = empo.staticTexts["Stop the backup?"].firstMatch
        note("stop step shows: \(stopTitle.waitForExistence(timeout: 5))")
        shot("stop-step")
        empo.buttons["Stop backup"].firstMatch.tap()
        note("tapped Stop backup, question gone: \(!stopTitle.waitForExistence(timeout: 3))")
        shot("after-stop")
        sleep(3)
        // The foreground pass would stage the game again 30 s in.
        // The container is read from the Mac after this kill.
        empo.terminate()
        note("killed Empo so the staging and the outbox can be read")
    }

    // MARK: - 017 checks 1 to 3, and 018 check 5

    /// Opens the per-game Backup sheet during a run for that game,
    /// reads the locks of 13.17, then pauses the run from the sheet.
    func testGameSheetDuringRun() {
        launchEmpo(arguments: ["-debugLogs", "YES", "-backupPressNow", "YES"], answeringNotNow: true)
        watchPill(until: "Backing up", timeout: 900)
        openGameBackupSheet()
        note("sheet tree:\n\(empo.debugDescription)")
        shot("sheet-during-run")
        noteLocks()
        let pause = empo.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.exists, "no Pause button in the sheet during the run")
        pause.tap()
        note("tapped Pause in the sheet")
        sleep(3)
        noteLocks()
        shot("sheet-after-pause")
        note("pill after the pause: \(pillLine())")
        sleep(5)
        empo.terminate()
        note("killed Empo so the staging and the outbox can be read")
    }

    /// Plays the game, pauses it to the library, and reads the sheet's
    /// second lock state. Then changes the mode and force quits, so the
    /// next launch runs with the new mode.
    func testGameSheetWithGamePaused() {
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        let card = empo.buttons["In Search of Immortality"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no game card")
        card.tap()
        sleep(12)
        shot("in-game")
        let menu = empo.buttons["Menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no Menu button in the game")
        menu.tap()
        let pauseRow = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pause '")).firstMatch
        XCTAssertTrue(pauseRow.waitForExistence(timeout: 5), "no Pause row in the menu")
        pauseRow.tap()
        note("paused the game to the library, card exists: \(card.waitForExistence(timeout: 10))")
        shot("library-game-paused")
        openGameBackupSheet()
        note("sheet tree:\n\(empo.debugDescription)")
        shot("sheet-game-paused")
        noteLocks()
        let modeRow = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'What gets backed up'")).firstMatch
        modeRow.tap()
        sleep(1)
        let slim = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Saves and settings only'")).firstMatch
        let slimText = empo.staticTexts["Saves and settings only"].firstMatch
        (slim.exists ? slim : slimText).tap()
        sleep(1)
        note("mode picker after the tap:\n\(empo.debugDescription)")
        shot("mode-picker")
        empo.navigationBars.buttons.firstMatch.tap()
        sleep(1)
        note("mode row now: \(modeRow.exists ? modeRow.label : "(no row)")")
        empo.terminate()
        note("killed Empo with the game paused, so the next launch can run")
        launchEmpo(arguments: ["-debugLogs", "YES", "-backupPressNow", "YES"], answeringNotNow: true)
        sleep(60)
        note("pill 60 s after the press with the slim mode: \(pillLine())")
        openGameBackupSheet()
        modeRow.tap()
        sleep(1)
        let full = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The whole game'")).firstMatch
        let fullText = empo.staticTexts["The whole game"].firstMatch
        (full.exists ? full : fullText).tap()
        sleep(1)
        empo.navigationBars.buttons.firstMatch.tap()
        sleep(1)
        note("mode row at the end: \(modeRow.exists ? modeRow.label : "(no row)")")
    }

    /// Long-presses the game card, opens Settings, then the Backup row.
    private func openGameBackupSheet() {
        let card = empo.buttons["In Search of Immortality"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no game card")
        card.press(forDuration: 1.2)
        sleep(1)
        shot("context-menu")
        // The library's gear is also a "Settings" button. The menu
        // item sits lower on the screen.
        let items = empo.buttons.matching(identifier: "Settings").allElementsBoundByIndex
        guard let settings = items.max(by: { $0.frame.minY < $1.frame.minY }), items.count > 1 else {
            XCTFail("no Settings item in the context menu, \(items.count) Settings button(s)")
            return
        }
        settings.tap()
        let row = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backup'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Backup row in the game settings")
        note("Backup row reads \"\(row.label)\"")
        row.tap()
        XCTAssertTrue(empo.buttons["Done"].firstMatch.waitForExistence(timeout: 10), "no Backup sheet")
    }

    private func noteLocks() {
        let names = ["What gets backed up", "Save files", "Back up now", "Pause", "Restore from backup", "Export backup"]
        for name in names {
            let element = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            note("\(name): \(element.exists ? (element.isEnabled ? "enabled" : "disabled") : "absent")")
        }
        for line in ["A backup of this game is running.", "Close In Search of Immortality to use these."] {
            if empo.staticTexts[line].firstMatch.exists { note("footer: \(line)") }
        }
    }

    private var resumeTitle: XCUIElement {
        empo.staticTexts["Resume the backup?"].firstMatch
    }

    private var resumeDetail: String {
        let text = empo.staticTexts.matching(NSPredicate(format: "label CONTAINS 'left'")).firstMatch
        return text.exists ? text.label : "(no detail)"
    }

    /// Launches Empo. When no question waits, it makes one: a run
    /// killed past 100 MB, then a new launch.
    private func ensureResumeQuestion() {
        launchEmpo(arguments: ["-debugLogs", "YES"])
        if resumeTitle.waitForExistence(timeout: 10) {
            note("a resume question waited from the last check")
            return
        }
        empo.terminate()
        launchEmpo(arguments: ["-debugLogs", "YES", "-backupPressNow", "YES"])
        watchPill(until: "Backing up", timeout: 900)
        killPast100MB()
        launchEmpo(arguments: ["-debugLogs", "YES"])
        XCTAssertTrue(resumeTitle.waitForExistence(timeout: 15), "no resume question")
        note("detail: \(resumeDetail)")
    }

    /// Kills Empo once the pill says under 60 MB is left. With six
    /// 40 MB planted files and one upload at a time, that is at least
    /// 140 MB confirmed.
    private func killPast100MB() {
        let start = Date()
        while Date().timeIntervalSince(start) < 900 {
            let line = pillLine()
            if let left = remainingMB(in: line), left < 60 {
                note("pill reads \"\(line)\", killing Empo")
                empo.terminate()
                sleep(3)
                return
            }
            if !line.hasPrefix("Backing up") { note("pill: \(line)") }
            sleep(2)
        }
        XCTFail("the pill never came under 60 MB left, last: \(pillLine())")
    }

    /// "about 152 MB left" gives 152, "about 1.2 GB left" gives 1200.
    private func remainingMB(in line: String) -> Double? {
        let pattern = /about ([\d.,]+) (MB|GB|KB) left/
        guard let match = line.firstMatch(of: pattern),
            let number = Double(match.1.replacingOccurrences(of: ",", with: "."))
        else { return nil }
        switch match.2 {
        case "GB": return number * 1000
        case "KB": return number / 1000
        default: return number
        }
    }

    /// Logs every change of the pill line until it starts with
    /// `prefix`.
    private func watchPill(until prefix: String, timeout: TimeInterval) {
        let start = Date()
        var last = ""
        while Date().timeIntervalSince(start) < timeout {
            let line = pillLine()
            if line != last {
                note("pill reads \"\(line)\" after \(Int(Date().timeIntervalSince(start))) s")
                last = line
            }
            if line.hasPrefix(prefix) { return }
            sleep(2)
        }
        XCTFail("the pill never read \"\(prefix)\" within \(Int(timeout)) s, last: \(pillLine())")
    }

    // MARK: - Empo

    private func launchEmpo(arguments: [String], answeringNotNow: Bool = false) {
        empo.launchArguments = arguments
        empo.launch()
        note("Empo launched with \(arguments.joined(separator: " "))")
        guard answeringNotNow, resumeTitle.waitForExistence(timeout: 3) else { return }
        empo.buttons["Not now"].firstMatch.tap()
        note("a resume question waited, answered Not now")
    }

    private var pill: XCUIElement {
        let prefixes = ["Checking", "Backing up", "Paused", "Backup stopped", "Backup complete", "Waiting"]
        let format = prefixes.map { _ in "label BEGINSWITH %@" }.joined(separator: " OR ")
        return empo.buttons.matching(NSPredicate(format: format, argumentArray: prefixes)).firstMatch
    }

    private func pillLine() -> String {
        pill.exists ? pill.label : "(no pill)"
    }

    private func waitForPill(prefix: String, timeout: TimeInterval) {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let line = pillLine()
            if line.hasPrefix(prefix) {
                note("pill reads \"\(line)\" after \(Int(Date().timeIntervalSince(start))) s")
                return
            }
            sleep(2)
        }
        XCTFail("the pill never read \"\(prefix)\" within \(Int(timeout)) s, last: \(pillLine())")
    }

    // MARK: - Settings

    private func openWiFiNetworkDetails() {
        let wifi = settings.cells.staticTexts["Wi-Fi"].firstMatch
        XCTAssertTrue(wifi.waitForExistence(timeout: 10), "no Wi-Fi row in Settings")
        wifi.tap()
        let info = settings.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'info'")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10), "no info button on the Wi-Fi page")
        info.tap()
    }

    private func openBattery() {
        let battery = settings.cells.staticTexts["Battery"].firstMatch
        XCTAssertTrue(battery.waitForExistence(timeout: 10), "no Battery row in Settings")
        battery.tap()
    }

    private func setLowDataMode(_ on: Bool) {
        settings.launch()
        openWiFiNetworkDetails()
        set(switchNamed: "Low Data Mode", to: on)
        settings.terminate()
    }

    private func setLowPowerMode(_ on: Bool) {
        settings.launch()
        openBattery()
        set(switchNamed: "Low Power Mode", to: on)
        settings.terminate()
    }

    private func set(switchNamed name: String, to on: Bool) {
        let toggle = settings.switches.matching(NSPredicate(format: "label ==[c] %@", name)).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no switch named \(name)")
        // A Settings row is a Switch that holds the real switch. The
        // row's center is its label, and a tap there toggles nothing.
        let knob = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        if ((knob.value as? String) == "1") != on { knob.tap() }
        sleep(1)
        let state = ((knob.value as? String) == "1") ? "on" : "off"
        XCTAssertEqual(state, on ? "on" : "off", "\(name) did not flip")
        note("\(name) is now \(state)")
    }

    // MARK: - Evidence

    private func note(_ text: String) {
        let stamp = Self.clock.string(from: Date())
        print("CHECK \(stamp) \(text)")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
