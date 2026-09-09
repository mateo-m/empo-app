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

    // MARK: - 016 check 4

    /// Server B answers 401 before this runs, so the first manual run
    /// puts 192.168.0.40 in needs-sign-in. The pause then has to win
    /// the row, and the next manual run has to skip the target.
    func testPausedTargetOutranksNeedsSignIn() {
        launchEmpo(arguments: ["-debugLogs", "YES", "-backupPressNow", "YES"], answeringNotNow: true)
        sleep(45)
        note("pill 45 s after the press: \(pillLine())")
        openBackupsScreen()
        note("row before the pause: \(targetRowLabel())")
        note("Sign in button shows: \(empo.buttons["Sign in"].firstMatch.exists)")
        shot("row-needs-sign-in")
        targetRow.tap()
        let pause = empo.switches["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "no Pause switch on the target screen")
        (pause.switches.firstMatch.exists ? pause.switches.firstMatch : pause).tap()
        sleep(1)
        note("Pause switch reads \(pause.value as? String ?? "?")")
        shot("target-paused")
        empo.navigationBars.buttons.firstMatch.tap()
        sleep(1)
        note("row after the pause: \(targetRowLabel())")
        note("Resume button shows: \(empo.buttons["Resume"].firstMatch.exists)")
        note("Sign in button shows: \(empo.buttons["Sign in"].firstMatch.exists)")
        shot("row-paused")
        let backUpNow = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back up now'")).firstMatch
        XCTAssertTrue(backUpNow.waitForExistence(timeout: 120), "no Back up now button")
        note("Back up now reads: \(backUpNow.label), enabled \(backUpNow.isEnabled)")
        backUpNow.tap()
        note("pressed Back up now with the target paused")
        sleep(45)
        note("pill 45 s after the press: \(pillLine())")
        note("row after the run: \(targetRowLabel())")
        shot("after-run-with-pause")
        empo.terminate()
    }

    /// 016 check 3 for WebDAV. Server B is back on its password, and
    /// the row's Sign in reruns the permission check with what the
    /// Keychain holds.
    func testSignInAgainRecoversTarget() {
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        openBackupsScreen()
        note("row before Sign in: \(targetRowLabel())")
        let signIn = empo.buttons["Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "no Sign in button on the row")
        signIn.tap()
        let close = empo.buttons["Close"].firstMatch
        note("permission check sheet shows: \(close.waitForExistence(timeout: 30))")
        sleep(2)
        note("sheet texts: \(empo.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label))")
        shot("permission-check-after-sign-in")
        close.tap()
        sleep(2)
        note("row after Sign in: \(targetRowLabel())")
        note("Sign in button shows: \(signIn.exists)")
        shot("row-after-sign-in")
    }

    /// Puts 192.168.0.40 back to work through the row's Resume button.
    func testResumePausedTarget() {
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        openBackupsScreen()
        note("row before Resume: \(targetRowLabel())")
        let resume = empo.buttons["Resume"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "no Resume button on the row")
        resume.tap()
        sleep(2)
        note("row after Resume: \(targetRowLabel())")
        shot("row-resumed")
    }

    /// The export picker of iOS 27 has Save and a back chevron and no
    /// Cancel. A drag down from its bar is the cancel.
    /// The iOS 27 export picker opens inside a folder. Its back chevron
    /// carries the parent's name and Cancel lives on the browse root.
    /// The picker's bar is not an XCUI navigation bar, so the chevron
    /// is found by label. A drag down from the top long-presses the
    /// folder title instead.
    private func dismissThePicker() {
        let cancel = empo.buttons["Cancel"].firstMatch
        for _ in 0..<4 where !cancel.exists {
            let labels = empo.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
            note("picker buttons: \(labels.suffix(8))")
            guard let parent = ["On My iPhone", "Browse", "Locations"].first(where: { labels.contains($0) }) else {
                break
            }
            empo.buttons[parent].firstMatch.tap()
            sleep(2)
        }
        note("picker Cancel shows: \(cancel.exists)")
        if cancel.exists {
            cancel.tap()
        } else {
            let top = empo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
            let bottom = empo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            top.press(forDuration: 0.05, thenDragTo: bottom)
        }
        sleep(2)
    }

    private var targetRow: XCUIElement {
        empo.buttons.matching(NSPredicate(format: "label BEGINSWITH '192.168.0.40'")).firstMatch
    }

    private func targetRowLabel() -> String {
        targetRow.waitForExistence(timeout: 10) ? targetRow.label : "(no row)"
    }

    /// Library gear, then the Backups row of Settings.
    private func openBackupsScreen() {
        let gear = empo.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "no Settings gear")
        gear.tap()
        let row = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backups'")).firstMatch
        // The list builds its rows on the way down, so a row below
        // the fold is not in the tree until a swipe brings it up.
        for _ in 0..<6 where !row.waitForExistence(timeout: 2) {
            empo.swipeUp()
        }
        XCTAssertTrue(row.exists, "no Backups row in Settings")
        row.tap()
        XCTAssertTrue(empo.navigationBars["Backups"].waitForExistence(timeout: 10), "no Backups screen")
    }

    // MARK: - 018 check 8

    /// Puts the game back on "The whole game", so the next run has
    /// bytes to move.
    func testSetWholeGameMode() {
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        setMode("The whole game")
    }

    /// Puts the game on "Saves and settings only", so an export
    /// builds in seconds.
    func testSetSlimMode() {
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        setMode("Saves and settings only")
    }

    private func setMode(_ label: String) {
        openGameBackupSheet()
        let modeRow = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'What gets backed up'")).firstMatch
        note("mode row before: \(modeRow.label)")
        modeRow.tap()
        sleep(1)
        let option = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        let optionText = empo.staticTexts[label].firstMatch
        (option.exists ? option : optionText).tap()
        sleep(2)
        note("mode row after: \(modeRow.waitForExistence(timeout: 5) ? modeRow.label : "(no row)")")
        shot("mode-set")
        empo.buttons["Done"].firstMatch.tap()
    }

    // MARK: - 019 check 3

    /// Exports the game, cancels the Files picker, and takes both
    /// answers of the Save again / Delete choice, one before a
    /// relaunch and one after it.
    func testExportCancelThenChoice() {
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        openGameBackupSheet()
        empo.buttons["Export backup"].firstMatch.tap()
        let save = empo.buttons["Save"].firstMatch
        note("Files picker shows: \(save.waitForExistence(timeout: 120))")
        shot("export-picker")
        dismissThePicker()
        let saveAgain = empo.buttons["Save again"].firstMatch
        note("Save again shows: \(saveAgain.waitForExistence(timeout: 10)), Delete shows: \(empo.buttons["Delete"].firstMatch.exists)")
        note("choice texts: \(empo.staticTexts.allElementsBoundByIndex.filter { $0.frame.minY > 400 }.map(\.label))")
        shot("export-choice")
        saveAgain.tap()
        note("Files picker shows again: \(save.waitForExistence(timeout: 30))")
        dismissThePicker()
        note("Save again shows again: \(saveAgain.waitForExistence(timeout: 10))")
        empo.terminate()
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        openBackupsScreen()
        let question = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Empo built'")).firstMatch
        for _ in 0..<4 where !question.waitForExistence(timeout: 2) {
            empo.swipeUp()
        }
        note("question row after the relaunch: \(question.exists ? question.label : "(no row)")")
        shot("question-row")
        question.tap()
        let delete = empo.buttons["Delete"].firstMatch
        note("choice shows after the relaunch: \(delete.waitForExistence(timeout: 10))")
        shot("choice-after-relaunch")
        delete.tap()
        sleep(2)
        note("question row after Delete: \(question.exists ? question.label : "(no row)")")
        shot("after-delete")
    }

    /// 019 check 1, the local half. The picker opens on Empo's own
    /// folder, so Save lands the ZIP in Documents. iCloud Drive
    /// needs the user's account.
    func testExportSaveToEmpoFolder() {
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        openGameBackupSheet()
        let export = empo.buttons["Export backup"].firstMatch
        let start = Date()
        while !export.isEnabled, Date().timeIntervalSince(start) < 900 { sleep(5) }
        note("Export backup enabled after \(Int(Date().timeIntervalSince(start))) s")
        export.tap()
        let save = empo.buttons["Save"].firstMatch
        let began = Date()
        var lastLine = ""
        while !save.exists, Date().timeIntervalSince(began) < 900 {
            let texts = empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
            let line = texts.drop(while: { $0 != "Export backup" }).dropFirst().prefix(3).joined(separator: " | ")
            if line != lastLine {
                note("export sheet: \(line)")
                lastLine = line
            }
            if empo.buttons.matching(identifier: "Done").allElementsBoundByIndex.count > 1 || line.contains("free space") || line.contains("could not") {
                shot("export-stopped")
            }
            sleep(5)
        }
        note("Files picker shows: \(save.exists) after \(Int(Date().timeIntervalSince(began))) s")
        guard save.exists else {
            shot("export-no-picker")
            return
        }
        save.tap()
        sleep(3)
        let labels = empo.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        note("buttons after Save: \(labels.suffix(8))")
        shot("after-save")
        // A ZIP of the same name is already there, so the picker asks
        // "Replace Existing Item". Its buttons are outside Empo's
        // accessibility tree, so the tap goes by position.
        let replace = empo.descendants(matching: .any)["Replace"].firstMatch
        note("Replace reachable: \(replace.exists)")
        if replace.exists {
            replace.tap()
        } else {
            empo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.543)).tap()
        }
        sleep(4)
        note("export sheet gone: \(!empo.staticTexts["Export backup"].firstMatch.exists), Backup sheet shows: \(empo.buttons["Export backup"].firstMatch.exists)")
        shot("after-export")
        empo.terminate()
    }

    /// Files opens the ZIP Empo saved into its own folder through
    /// "Open With", and Empo shows the import sheet.
    private func openPackageFromFiles() {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        sleep(3)
        shot("files-launch")
        note("files buttons: \(files.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.prefix(20))")
        let browse = files.tabBars.buttons["Browse"].firstMatch
        if browse.exists { browse.tap(); sleep(1); browse.tap(); sleep(1) }
        let onMyIPhone = files.staticTexts["On My iPhone"].firstMatch
        if !onMyIPhone.exists, files.buttons["Browse"].firstMatch.exists {
            files.buttons["Browse"].firstMatch.tap()
            sleep(1)
        }
        note("On My iPhone shows: \(onMyIPhone.waitForExistence(timeout: 10))")
        onMyIPhone.tap()
        sleep(2)
        let empoFolder = files.staticTexts["Empo"].firstMatch
        note("Empo folder shows: \(empoFolder.waitForExistence(timeout: 10))")
        shot("files-on-my-iphone")
        empoFolder.tap()
        sleep(2)
        let zip = files.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'In Search of Immortality-Empo-backup'")).firstMatch
        note("ZIP shows: \(zip.waitForExistence(timeout: 10)), label \(zip.exists ? zip.label : "")")
        shot("files-empo-folder")
        zip.press(forDuration: 1.2)
        sleep(2)
        shot("files-zip-menu")
        note("menu buttons: \(files.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(20))")
        let openWith = files.buttons["Open With"].firstMatch
        note("Open With shows: \(openWith.waitForExistence(timeout: 5))")
        openWith.tap()
        sleep(3)
        shot("files-open-with")
        let any = files.descendants(matching: .any)
        let empoTarget = any.matching(NSPredicate(format: "label == 'Empo' OR label BEGINSWITH 'Empo,'")).firstMatch
        note("Empo in Open With: \(empoTarget.waitForExistence(timeout: 5)), label \(empoTarget.exists ? empoTarget.label : "")")
        note("open with labels: \(files.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(20)), cells \(files.cells.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.prefix(12))")
        if empoTarget.exists { empoTarget.tap() }
        note("Empo in front: \(empo.wait(for: .runningForeground, timeout: 20))")
        sleep(3)
        if empo.staticTexts["Something went wrong"].firstMatch.exists { empo.buttons["OK"].firstMatch.tap() }
        let importBar = empo.navigationBars["Import backup"].firstMatch
        note("import sheet shows: \(importBar.waitForExistence(timeout: 20))")
        note("import texts: \(empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(8))")
        shot("import-sheet")
    }

    /// The row is a plain button whose label is the name plus the
    /// size. The library card behind the sheet has the bare name.
    private var importRow: XCUIElement {
        empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'In Search of Immortality' AND label ENDSWITH 'B'")).firstMatch
    }

    /// 019 checks 4 and 5. The restore lands over the game this phone
    /// holds.
    func testOpenPackageFromFilesAndImport() {
        openPackageFromFiles()
        let row = importRow
        note("game row in the import sheet: \(row.exists ? row.label : "(none)")")
        row.tap()
        let restore = empo.buttons["Restore"].firstMatch
        note("restore sheet shows: \(restore.waitForExistence(timeout: 10))")
        note("restore texts: \(empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(6))")
        shot("restore-sheet")
        restore.tap()
        sleep(15)
        note("after restore texts: \(empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(6))")
        note("after restore buttons: \(empo.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(6))")
        shot("after-restore")
        for name in ["Done", "Cancel"] where empo.buttons[name].firstMatch.exists {
            empo.buttons[name].firstMatch.tap()
            sleep(1)
        }
        shot("after-import-close")
        openGameBackupSheet()
        for _ in 0..<3 { empo.swipeUp() }
        note("backup sheet texts: \(empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(10))")
        shot("backup-sheet-after-import")
        empo.terminate()
    }

    /// 019 check 6. A whole-game import dies right after Restore. The
    /// next launch asks the resume question, and Stop deletes the
    /// staged package.
    func testInterruptImportThenStop() {
        openPackageFromFiles()
        // A package Files opened in place is copied into staging
        // first, 3 GB here.
        note("row shows: \(importRow.waitForExistence(timeout: 600))")
        importRow.tap()
        let restore = empo.buttons["Restore"].firstMatch
        note("restore sheet shows: \(restore.waitForExistence(timeout: 10))")
        empo.buttons["The whole game"].firstMatch.tap()
        sleep(1)
        restore.tap()
        // The plan compares 340 files by hash first, about 3 s on
        // this phone, and the record lands before the first write.
        sleep(5)
        empo.terminate()
        note("Empo killed 5 s after Restore")
        sleep(3)
        launchEmpo(arguments: ["-debugLogs", "YES"])
        let title = empo.staticTexts["Resume the restore?"].firstMatch
        note("resume question shows: \(title.waitForExistence(timeout: 15))")
        note("question texts: \(empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(6))")
        note("question buttons: \(empo.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(6))")
        shot("resume-question")
        let stop = empo.buttons["Stop restore"].firstMatch
        stop.tap()
        let stopTitle = empo.staticTexts["Stop the restore?"].firstMatch
        note("stop step shows: \(stopTitle.waitForExistence(timeout: 10))")
        note("stop texts: \(empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(4))")
        shot("stop-step")
        stop.tap()
        sleep(3)
        note("question gone: \(!title.exists)")
        shot("after-stop")
        empo.terminate()
        launchEmpo(arguments: ["-debugLogs", "YES"])
        note("question comes back: \(title.waitForExistence(timeout: 8))")
        empo.terminate()
    }

    /// One row stands for every unsaved package. Each Delete removes one.
    func testRestoreWholeGameFromFiles() {
        openPackageFromFiles()
        note("row shows: \(importRow.waitForExistence(timeout: 600))")
        importRow.tap()
        let restore = empo.buttons["Restore"].firstMatch
        note("restore sheet shows: \(restore.waitForExistence(timeout: 10))")
        empo.buttons["The whole game"].firstMatch.tap()
        sleep(1)
        restore.tap()
        // The restore sheet shows no progress. It closes itself when
        // the restore finishes, and a footnote stays when it fails.
        let scope = empo.buttons["The whole game"].firstMatch
        let start = Date()
        var footnote = ""
        while scope.exists, footnote.isEmpty, Date().timeIntervalSince(start) < 900 {
            sleep(5)
            footnote = empo.staticTexts.allElementsBoundByIndex.map(\.label)
                .first { $0.hasPrefix("This device needs") || $0 == "The restore stopped." } ?? ""
        }
        note("restore sheet gone after \(Int(Date().timeIntervalSince(start))) s: \(!scope.exists), footnote: \(footnote)")
        shot("whole-game-restored")
        let done = empo.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        sleep(2)
        empo.terminate()
    }

    func testResumeInterruptedImportFromFiles() {
        // A record from a cut restore waits. Files opens the package
        // at the same time, so both sheets ask for the one slot.
        openPackageFromFiles()
        let title = empo.staticTexts["Resume the restore?"].firstMatch
        note("resume question shows: \(title.waitForExistence(timeout: 10))")
        shot("question-over-files-open")
        empo.buttons["Resume"].firstMatch.tap()
        let importBar = empo.navigationBars["Import backup"].firstMatch
        let start = Date()
        while !importBar.exists, Date().timeIntervalSince(start) < 300 {
            sleep(10)
            note("after Resume texts: \(empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(5))")
        }
        note("import sheet shows after the resume, \(Int(Date().timeIntervalSince(start))) s: \(importBar.exists)")
        shot("after-resume")
        let done = empo.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        sleep(2)
        empo.terminate()
    }

    func testAnswerResumeWithResume() {
        launchEmpo(arguments: ["-debugLogs", "YES"])
        let title = empo.staticTexts["Resume the restore?"].firstMatch
        note("resume question shows: \(title.waitForExistence(timeout: 15))")
        if title.exists { empo.buttons["Resume"].firstMatch.tap() }
        sleep(30)
        note("question gone: \(!title.exists)")
        empo.terminate()
        launchEmpo(arguments: ["-debugLogs", "YES"])
        note("question comes back: \(title.waitForExistence(timeout: 8))")
        empo.terminate()
    }

    func testDeleteUnsavedPackages() {
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        openBackupsScreen()
        let question = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Empo built'")).firstMatch
        for _ in 0..<4 where !question.waitForExistence(timeout: 2) {
            empo.swipeUp()
        }
        var deleted = 0
        while question.exists, deleted < 6 {
            question.tap()
            let delete = empo.buttons["Delete"].firstMatch
            guard delete.waitForExistence(timeout: 10) else { break }
            delete.tap()
            deleted += 1
            sleep(2)
        }
        note("deleted \(deleted) unsaved packages, row still shows: \(question.exists)")
    }

    /// The pill and the card's ring both go while a game is open.
    /// The ring has no accessibility label, so the screenshots carry
    /// that half.
    func testPillAndBadgeHideWhileAGamePlays() {
        launchEmpo(arguments: ["-debugLogs", "YES", "-backupPressNow", "YES"], answeringNotNow: true)
        watchPill(until: "Backing up", timeout: 600)
        sleep(2)
        shot("library-during-run")
        let card = empo.buttons["In Search of Immortality"].firstMatch
        card.tap()
        sleep(10)
        note("pill in the game: \(pillLine())")
        shot("in-game-during-run")
        let menu = empo.buttons["Menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no Menu button in the game")
        menu.tap()
        let pauseRow = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pause '")).firstMatch
        XCTAssertTrue(pauseRow.waitForExistence(timeout: 5), "no Pause row in the menu")
        pauseRow.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no card after the pause")
        sleep(3)
        note("pill with the game paused in the library: \(pillLine())")
        shot("library-game-paused-during-run")
        sleep(20)
        note("pill 20 s later: \(pillLine())")
        empo.terminate()
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
        // A kill with a game session open earns the player's crash
        // notice at the next launch.
        let crashNotice = empo.staticTexts["Something went wrong"].firstMatch
        if crashNotice.waitForExistence(timeout: 2) {
            empo.buttons["OK"].firstMatch.tap()
            note("closed the player's crash notice")
        }
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


    // MARK: - 011, 012, 016: targets added through the form

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// 012 check 1 and 011 check 1. The xcodebuild call names the
    /// server through `TEST_RUNNER_EMPO_*` variables.
    func testAddTargetThroughTheForm() {
        let service = env["EMPO_SERVICE"] ?? "WebDAV server"
        let name = env["EMPO_NAME"] ?? "Server"
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        openBackupsScreen()
        tapAdd()
        let row = empo.buttons[service].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(service) row on the Add sheet")
        note("Add sheet rows: \(empo.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty })")
        row.tap()
        XCTAssertTrue(empo.navigationBars[service].waitForExistence(timeout: 10), "no \(service) form")
        fill(hint: service == "S3 storage" ? "My bucket" : "My server", with: name)
        fill(hint: service == "S3 storage" ? "https://s3.eu-west-1.amazonaws.com" : "https://cloud.example.com/remote.php/dav/files/alice", with: env["EMPO_ADDRESS"] ?? "")
        if service == "S3 storage" {
            fill(hint: "my-saves", with: env["EMPO_BUCKET"] ?? "")
            fill(hint: "eu-west-1", with: env["EMPO_REGION"] ?? "")
            fill(hint: "", with: env["EMPO_USER"] ?? "")
            fill(hint: "", with: env["EMPO_PASSWORD"] ?? "", secret: true)
            if env["EMPO_PATH_STYLE"] == "YES" {
                let toggle = empo.switches["Put the bucket name in the path"].firstMatch
                for _ in 0..<3 where !toggle.exists { empo.swipeUp() }
                toggle.tap()
                note("path style toggle reads \(toggle.value ?? "nil")")
            }
        } else {
            fill(hint: "alice", with: env["EMPO_USER"] ?? "")
            fill(hint: "", with: env["EMPO_PASSWORD"] ?? "", secret: true)
        }
        shot("form-\(name)")
        let add = empo.buttons.matching(identifier: "Add").allElementsBoundByIndex.last
        for _ in 0..<3 where !(add?.isHittable ?? false) { empo.swipeUp() }
        note("form Add enabled: \(add?.isEnabled ?? false)")
        add?.tap()
        dismissSavePasswordAsk()
        let ready = empo.staticTexts["\(name) is ready"].firstMatch
        let refused = empo.staticTexts["\(name) refused a step"].firstMatch
        let start = Date()
        while !ready.exists, !refused.exists, Date().timeIntervalSince(start) < 120 { sleep(1) }
        note("permission sheet after \(Int(Date().timeIntervalSince(start))) s: ready \(ready.exists), refused \(refused.exists)")
        notePermissionSheet()
        shot("permission-\(name)")
        dismissSavePasswordAsk()
        empo.buttons["Close"].firstMatch.tap()
        sleep(1)
        noteTargetDetail(name)
    }

    /// The detail screen of the target named in `EMPO_NAME`.
    func testNoteTargetDetail() {
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        openBackupsScreen()
        noteTargetDetail(env["EMPO_NAME"] ?? "Nextcloud")
    }

    private func noteTargetDetail(_ name: String) {
        let target = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        note("target row: \(target.waitForExistence(timeout: 10) ? target.label : "(no row)")")
        target.tap()
        XCTAssertTrue(empo.navigationBars[name].waitForExistence(timeout: 10), "no \(name) detail screen")
        sleep(2)
        let texts = empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        note("detail texts: \(texts.prefix(8))")
        note("detail usage line: \(texts.first { $0.contains(" used") || $0.contains("backed up here") } ?? "(none)")")
        note("usage bar shows: \(empo.progressIndicators.firstMatch.exists)")
        shot("detail-\(name)")
    }

    /// The password manager asks to save the password of the form.
    private func dismissSavePasswordAsk() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for app in [springboard, empo] {
            let notNow = app.buttons["Not Now"].firstMatch
            if notNow.waitForExistence(timeout: 3) {
                notNow.tap()
                note("closed the Save Password ask")
                return
            }
        }
    }

    private func tapAdd() {
        let names = ["Add", "Add a backup target", "Add a target"]
        for name in names where empo.buttons[name].firstMatch.waitForExistence(timeout: 3) {
            empo.buttons[name].firstMatch.tap()
            XCTAssertTrue(empo.navigationBars["Add a target"].waitForExistence(timeout: 10), "no Add a target sheet")
            return
        }
        XCTFail("no Add button on the Backups screen")
    }

    /// SwiftUI gives the form fields no label, only the hint as the
    /// placeholder. A field with no hint is the last text field of
    /// its form.
    private func fill(hint: String, with text: String, secret: Bool = false) {
        let fields = secret ? empo.secureTextFields : empo.textFields
        let field: XCUIElement
        if secret {
            field = fields.firstMatch
        } else if hint.isEmpty {
            field = fields.allElementsBoundByIndex.last ?? fields.firstMatch
        } else {
            field = fields.matching(NSPredicate(format: "placeholderValue == %@", hint)).firstMatch
        }
        guard field.waitForExistence(timeout: 3) else {
            note("fields: \(fields.allElementsBoundByIndex.map { $0.placeholderValue ?? "" })")
            XCTFail("no field with the hint \(hint)")
            return
        }
        for _ in 0..<3 where !field.isHittable { empo.swipeUp() }
        field.tap()
        field.typeText(text)
    }

    private func notePermissionSheet() {
        let texts = empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        note("sheet texts: \(texts.suffix(10))")
        let marks = empo.images.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        note("sheet marks: \(marks.suffix(6))")
    }

    /// 016 check 6. The namespace named in `EMPO_DEVICE` was planted
    /// on the server before the run.
    func testDeleteForeignNamespace() {
        let targetName = env["EMPO_NAME"] ?? "localhost"
        let device = env["EMPO_DEVICE"] ?? "Planted iPhone"
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        openBackupsScreen()
        let target = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", targetName)).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "no \(targetName) row")
        target.tap()
        let devices = empo.buttons["Devices"].firstMatch
        for _ in 0..<4 where !devices.waitForExistence(timeout: 2) { empo.swipeUp() }
        devices.tap()
        let planted = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", device)).firstMatch
        let start = Date()
        note("planted row shows: \(planted.waitForExistence(timeout: 180)) after \(Int(Date().timeIntervalSince(start))) s")
        let rows = empo.buttons.matching(NSPredicate(format: "label CONTAINS 'snapshots'")).allElementsBoundByIndex.map(\.label)
        note("device rows: \(rows)")
        shot("devices-before")
        guard planted.exists else { return }
        let deletes = empo.buttons.matching(identifier: "Delete").allElementsBoundByIndex
        guard let delete = deletes.first(where: { $0.frame.minY > planted.frame.minY }) else {
            XCTFail("no Delete under the planted row")
            return
        }
        delete.tap()
        let confirm = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete '")).firstMatch
        note("confirmation shows: \(confirm.waitForExistence(timeout: 10))")
        let texts = empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        note("sheet texts: \(texts.suffix(8))")
        note("destructive button: \(confirm.label)")
        shot("delete-sheet")
        confirm.tap()
        let began = Date()
        while planted.exists, Date().timeIntervalSince(began) < 180 { sleep(2) }
        note("planted row gone: \(!planted.exists) after \(Int(Date().timeIntervalSince(began))) s")
        let after = empo.buttons.matching(NSPredicate(format: "label CONTAINS 'snapshots'")).allElementsBoundByIndex.map(\.label)
        note("device rows after: \(after)")
        shot("devices-after")
    }

    /// 019 check 2. `EMPO_KEEP=YES` leaves the ZIP in place through
    /// "Save again", so a second run meets the space check.
    func testExportLibrary() {
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        openBackupsScreen()
        let export = empo.buttons["Export library"].firstMatch
        for _ in 0..<6 where !export.waitForExistence(timeout: 2) { empo.swipeUp() }
        XCTAssertTrue(export.exists, "no Export library row")
        note("Export library enabled: \(export.isEnabled)")
        export.tap()
        let save = empo.buttons["Save"].firstMatch
        let began = Date()
        var lastLine = ""
        var stopped = false
        sleep(1)
        note("sheet texts at start: \(empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.suffix(6))")
        shot("library-export-start")
        while !save.exists, !stopped, Date().timeIntervalSince(began) < 1800 {
            let texts = empo.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
            let line = texts.drop(while: { !$0.hasPrefix("Export") }).dropFirst().prefix(3).joined(separator: " | ")
            if line != lastLine {
                note("export sheet: \(line)")
                lastLine = line
            }
            if line.contains("free space") || line.contains("could not") || line.contains("stopped") {
                shot("library-export-stopped")
                stopped = true
            }
            sleep(5)
        }
        note("Files picker shows: \(save.exists) after \(Int(Date().timeIntervalSince(began))) s")
        shot("library-export-end")
        guard save.exists else {
            if let done = empo.buttons.matching(identifier: "Done").allElementsBoundByIndex.last, done.exists {
                done.tap()
            }
            return
        }
        dismissThePicker()
        let saveAgain = empo.buttons["Save again"].firstMatch
        let delete = empo.buttons["Delete"].firstMatch
        note("choice shows: \(saveAgain.waitForExistence(timeout: 10)), texts: \(empo.staticTexts.allElementsBoundByIndex.filter { $0.frame.minY > 400 }.map(\.label))")
        shot("library-export-choice")
        if env["EMPO_KEEP"] == "YES" {
            saveAgain.tap()
            note("Files picker shows again: \(save.waitForExistence(timeout: 30))")
            dismissThePicker()
            note("Save again shows again: \(saveAgain.waitForExistence(timeout: 10))")
        } else {
            delete.tap()
            sleep(3)
        }
    }

    /// Taps the question row of an unsaved package on the Backups
    /// screen and answers Delete.
    func testDeleteTheUnsavedLibraryPackage() {
        launchEmpo(arguments: ["-debugLogs", "YES"], answeringNotNow: true)
        openBackupsScreen()
        let question = empo.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Empo built'")).firstMatch
        for _ in 0..<4 where !question.waitForExistence(timeout: 2) { empo.swipeUp() }
        note("question row: \(question.exists ? question.label : "(no row)")")
        guard question.exists else { return }
        question.tap()
        let delete = empo.buttons["Delete"].firstMatch
        note("choice shows: \(delete.waitForExistence(timeout: 10))")
        delete.tap()
        sleep(3)
        note("question row after Delete: \(question.exists ? question.label : "(no row)")")
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
