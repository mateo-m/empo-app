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

    // MARK: - Empo

    private func launchEmpo(arguments: [String]) {
        empo.launchArguments = arguments
        empo.launch()
        note("Empo launched with \(arguments.joined(separator: " "))")
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
