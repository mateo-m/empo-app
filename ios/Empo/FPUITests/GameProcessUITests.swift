import XCTest

/// Plays each game of EMPO_GP_GAMES (titles joined by "|") in turn. It
/// taps and types in each game, pauses it, then starts the next with
/// "Close and Play", or quits it when the same game comes next. It
/// quits the last one from the More sheet, then
/// plays the first one again and quits it.
final class GameProcessUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testEveryCoreInItsOwnProcess() throws {
        let games = try XCTUnwrap(env["EMPO_GP_GAMES"]).split(separator: "|").map(String.init)
        let wait = UInt32(env["EMPO_GP_WAIT"] ?? "") ?? 20
        // With EMPO_GP_PLAY, autoplay.rb plays the game for that many
        // seconds, and the test only watches.
        let play = UInt32(env["EMPO_GP_PLAY"] ?? "") ?? 0
        let app = XCUIApplication()
        app.launchArguments += ["-whatsNewSeenVersion", "999", "-debugLogs", "YES"]
        app.launchArguments += ["-rubyGameRunner", env["EMPO_GP_RUNNER"] ?? "gameProcess"]
        if let probe = env["EMPO_TEMP_PROBE"] { app.launchEnvironment["EMPO_TEMP_PROBE"] = probe }
        if let ruby = env["EMPO_TEMP_RUBY"] { app.launchEnvironment["EMPO_TEMP_RUBY"] = ruby }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let understand = app.buttons["I understand"]
        if understand.waitForExistence(timeout: 8) { understand.tap() }
        sleep(3)

        for (index, game) in games.enumerated() {
            let step = String(format: "%02d", index)
            if index > 0 { scrollToTop(app) }
            if !start(app, game: game) { continue }
            if play > 0 {
                switch watch(app, game: game, step: step, seconds: play) {
                case .stopped, .closed: continue
                case .played: break
                }
            } else {
                sleep(wait)
                if stopped(app, game: game) { continue }
                shot("\(step)-a-\(game)-running")
                let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                center.tap()
                sleep(1)
                app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
                sleep(1)
                app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
                sleep(3)
                shot("\(step)-b-\(game)-after-input")
                XCUIDevice.shared.orientation = .landscapeLeft
                sleep(4)
                shot("\(step)-b2-\(game)-landscape")
                XCUIDevice.shared.orientation = .portrait
                sleep(4)
                shot("\(step)-b3-\(game)-portrait")
            }
            if index == games.count - 1 || games[index + 1] == game {
                quit(app, game: game)
                shot("\(step)-c-\(game)-quit")
            } else {
                openMore(app)
                let pause = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH 'Pause '")).firstMatch
                XCTAssertTrue(pause.waitForExistence(timeout: 5), "\(game): no Pause row")
                pause.tap()
                sleep(4)
                shot("\(step)-c-\(game)-paused")
            }
        }

        // After a quit, a game starts at once, with no alert.
        let again = games[0]
        scrollToTop(app)
        card(named: again, in: app).tap()
        sleep(2)
        let playAnyway = app.alerts.buttons["Play anyway"]
        if playAnyway.exists {
            playAnyway.tap()
            sleep(1)
        }
        XCTAssertFalse(app.alerts.firstMatch.exists, "an alert after a quit")
        print("GP start \(again)")
        sleep(wait)
        if stopped(app, game: again) { return }
        shot("\(String(format: "%02d", games.count))-a-\(again)-again")
        quit(app, game: again)
        shot("\(String(format: "%02d", games.count))-b-\(again)-quit")
    }

    func testFilesExplore() throws {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        for (index, route) in (env["EMPO_FP_PATH"] ?? "").split(separator: ";").enumerated() {
            files.terminate()
            files.launch()
            sleep(3)
            for name in route.split(separator: "|").map(String.init) {
                let item = files.descendants(matching: .any).matching(
                    NSPredicate(format: "label == %@", name)
                ).firstMatch
                if !item.waitForExistence(timeout: 8) {
                    print("FP missing \(name)")
                    break
                }
                item.tap()
                sleep(3)
            }
            shot("files-\(index)")
            print("FP cells \(route): \(files.cells.allElementsBoundByIndex.map(\.label))")
        }
    }

    private func item(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func menu(_ app: XCUIApplication, on label: String, pick action: String) {
        item(app, label).press(forDuration: 1.2)
        let button = app.buttons[action].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(action) for \(label)")
        button.tap()
        sleep(1)
    }

    private func rename(_ app: XCUIApplication, _ from: String, to: String) {
        menu(app, on: from, pick: "Rename")
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: from.count + 4) + to + "\n")
        sleep(3)
        XCTAssertTrue(item(app, to).waitForExistence(timeout: 10), "\(to) missing after rename")
        XCTAssertFalse(item(app, from).exists, "\(from) still shown after rename")
        print("FP renamed \(from) -> \(to)")
    }

    /// Files has Recover only in the bar of its select mode, not in the
    /// long-press menu of a deleted item.
    private func recover(_ files: XCUIApplication, _ name: String) {
        files.buttons["More"].firstMatch.tap()
        sleep(1)
        files.buttons["Select"].firstMatch.tap()
        sleep(1)
        let cell = files.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 8), "no \(name) in Recently Deleted")
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        sleep(1)
        let button = files.buttons["Recover"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no Recover for \(name)")
        XCTAssertTrue(button.isEnabled, "Recover is greyed out for \(name)")
        button.tap()
        sleep(3)
    }

    private func openGames(_ files: XCUIApplication) {
        files.launch()
        sleep(3)
        for name in ["Browse", "Empo", "Games"] {
            let element = item(files, name)
            XCTAssertTrue(element.waitForExistence(timeout: 8), "no \(name)")
            let cell = files.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", name + ","))
                .firstMatch
            // In icon view, a tap on the name starts a rename.
            if cell.exists {
                cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            } else {
                element.tap()
            }
            sleep(2)
        }
    }

    /// Opens `path` folder by folder and previews the file at its end.
    private func openFile(_ files: XCUIApplication, path: [String]) {
        for name in path {
            let file = name as NSString
            let label =
                file.pathExtension.isEmpty ? name : file.deletingPathExtension + ", " + file.pathExtension
            let cell = files.cells.matching(
                NSPredicate(
                    format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", label, label + ",",
                    name + ",")
            ).firstMatch
            for _ in 0..<6 where !cell.waitForExistence(timeout: 3) || !cell.isHittable { files.swipeUp() }
            if !cell.exists {
                print("FP no \(name) in \(files.cells.allElementsBoundByIndex.map(\.label))")
                XCTFail("no \(name)")
                return
            }
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            sleep(3)
        }
        shot("open-\(path.joined(separator: "-"))")
        print("FP opened \(path) \(files.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label))")
    }

    private func backToGames(_ files: XCUIApplication) {
        for _ in 0..<8 where !item(files, "Games, Actions Menu").exists {
            let done = files.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Close"]))
                .firstMatch
            if done.exists { done.tap() } else { files.navigationBars.buttons.firstMatch.tap() }
            sleep(1)
        }
    }

    func testFilesTrash() throws {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        sleep(3)
        for name in ["Browse", "Empo"] {
            item(files, name).tap()
            sleep(2)
        }
        print("FP before \(files.cells.allElementsBoundByIndex.map(\.label))")
        menu(files, on: "FP Trash Test", pick: "Delete")
        sleep(3)
        shot("after-delete")
        print(
            "FP after delete \(files.cells.allElementsBoundByIndex.map(\.label)) alerts \(files.alerts.allElementsBoundByIndex.map(\.label))"
        )
        files.terminate()
        files.launch()
        sleep(3)
        for name in ["Browse", "Recently Deleted"] {
            item(files, name).tap()
            sleep(3)
        }
        shot("recently-deleted")
        print("FP recently deleted \(files.cells.allElementsBoundByIndex.map(\.label))")
    }

    func testFilesRecover() throws {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        sleep(3)
        let target = env["EMPO_FP_TRASH"] ?? "FP Move"
        if env["EMPO_FP_TRASH"] != nil {
            for name in ["Browse", env["EMPO_FP_PLACE"] ?? "Empo"] {
                item(files, name).tap()
                sleep(2)
            }
            menu(files, on: target, pick: "Delete")
            sleep(3)
            files.navigationBars.buttons.firstMatch.tap()
            sleep(2)
        } else {
            item(files, "Browse").tap()
            sleep(2)
        }
        item(files, "Recently Deleted").tap()
        sleep(3)
        print("FP deleted \(files.cells.allElementsBoundByIndex.map(\.label))")
        recover(files, target)
        print("FP after recover \(files.cells.allElementsBoundByIndex.map(\.label))")
    }

    private var fpGame: String { env["EMPO_FP_GAME"] ?? "Pokemon Z" }

    func testFilesRename() throws {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        openGames(files)
        rename(files, env["EMPO_FP_FROM"] ?? fpGame, to: fpGame + " FP")
        shot("renamed")
        openFile(files, path: [fpGame + " FP", "Game", "Game.ini"])
        backToGames(files)
        rename(files, fpGame + " FP", to: fpGame)
        shot("renamed-back")

        playZ()
    }

    func testFilesMoveDeleteRecover() throws {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        openGames(files)
        menu(files, on: fpGame, pick: "New Folder with Item")
        sleep(2)
        files.typeText("FP Move\n")
        sleep(3)
        shot("moved")
        print("FP after move \(files.cells.allElementsBoundByIndex.map(\.label))")
        backToGames(files)
        XCTAssertFalse(item(files, fpGame).exists, "\(fpGame) still in Games")
        openFile(files, path: ["FP Move", fpGame, "Game", "Game.ini"])
        backToGames(files)

        menu(files, on: "FP Move", pick: "Delete")
        sleep(3)
        XCTAssertFalse(item(files, "FP Move").exists, "FP Move still shown after delete")
        for _ in 0..<4 where !item(files, "Recently Deleted").exists {
            files.navigationBars.buttons.firstMatch.tap()
            sleep(1)
        }
        item(files, "Recently Deleted").tap()
        sleep(3)
        shot("recently-deleted")
        print("FP deleted \(files.cells.allElementsBoundByIndex.map(\.label))")
        recover(files, "FP Move")
        sleep(3)
        print("FP after recover \(files.cells.allElementsBoundByIndex.map(\.label))")

        openGames(files)
        shot("recovered")
        openFile(files, path: ["FP Move", fpGame, "Game", "Game.ini"])
        backToGames(files)

        files.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'FP Move,'")).firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        sleep(2)
        menu(files, on: fpGame, pick: "Move")
        sleep(2)
        shot("move-sheet")
        print("FP move sheet \(files.debugDescription)")
        let games = files.cells.matching(NSPredicate(format: "label BEGINSWITH 'Games'")).firstMatch
        if !games.exists {
            // The sheet can open in another place, such as On My iPhone.
            for _ in 0..<4
            where !files.cells.matching(NSPredicate(format: "label BEGINSWITH 'Empo'")).firstMatch.exists {
                files.navigationBars.buttons["BackButton"].firstMatch.tap()
                sleep(2)
            }
            files.cells.matching(NSPredicate(format: "label BEGINSWITH 'Empo'")).firstMatch.tap()
            sleep(2)
        }
        if games.waitForExistence(timeout: 5) {
            games.tap()
            sleep(2)
        }
        files.buttons["Move"].firstMatch.tap()
        sleep(3)
        backToGames(files)
        shot("moved-back")
        XCTAssertTrue(item(files, fpGame).waitForExistence(timeout: 8), "\(fpGame) not back in Games")
        menu(files, on: "FP Move", pick: "Delete")
        playZ()
    }

    private func playZ() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-whatsNewSeenVersion", "999", "-rubyGameRunner", env["EMPO_GP_RUNNER"] ?? "gameProcess",
        ]
        app.launch()
        let understand = app.buttons["I understand"]
        if understand.waitForExistence(timeout: 8) { understand.tap() }
        sleep(3)
        start(app, game: env["EMPO_FP_TITLE"] ?? fpGame)
        sleep(20)
        XCTAssertFalse(stopped(app, game: env["EMPO_FP_TITLE"] ?? fpGame))
        shot("z-after-rename")
        quit(app, game: env["EMPO_FP_TITLE"] ?? fpGame)
    }

    /// Returns false when the game stopped before it started.
    @discardableResult
    private func start(_ app: XCUIApplication, game: String) -> Bool {
        card(named: game, in: app).tap()
        while app.alerts.firstMatch.waitForExistence(timeout: 5) {
            let alert = app.alerts.firstMatch
            print("GP alert: \(alert.label)")
            if stopped(app, game: game) { return false }
            // The test runner ended the app during an earlier run.
            if alert.label == "Last session ended early" {
                alert.buttons["Got it"].tap()
                sleep(1)
                card(named: game, in: app).tap()
                continue
            }
            let play = alert.buttons.matching(
                NSPredicate(format: "label IN %@", ["Close and Play", "Play anyway"])
            ).firstMatch
            XCTAssertTrue(play.exists, "\(game): unknown alert \(alert.label)")
            play.tap()
            sleep(1)
        }
        print("GP start \(game)")
        return true
    }

    private enum Outcome { case played, closed, stopped }

    /// Takes a screenshot every 30 seconds while the game plays. A game
    /// can close itself and ask for a restart (Infinite Fusion does on
    /// its first start), so the first close starts the game again.
    private func watch(_ app: XCUIApplication, game: String, step: String, seconds: UInt32) -> Outcome {
        var elapsed: UInt32 = 0
        var restarted = false
        while elapsed < seconds {
            sleep(30)
            elapsed += 30
            if stopped(app, game: game) { return .stopped }
            shot("\(step)-\(String(format: "%03d", elapsed))s-\(game)")
            let closed = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' closed'")).firstMatch
            if closed.exists {
                print("GP closed \(game) at \(elapsed)s")
                app.buttons["Back to Library"].tap()
                sleep(2)
                if restarted { return .closed }
                restarted = true
                scrollToTop(app)
                if !start(app, game: game) { return .stopped }
                continue
            }
            print("GP playing \(game) \(elapsed)s")
        }
        return .played
    }

    private func quit(_ app: XCUIApplication, game: String) {
        openMore(app)
        let quit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Quit '")).firstMatch
        if !quit.waitForExistence(timeout: 3) { app.buttons["Sheet Grabber"].firstMatch.swipeUp() }
        XCTAssertTrue(quit.waitForExistence(timeout: 5), "\(game): no Quit row")
        quit.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "\(game): no quit alert")
        alert.buttons["Quit"].tap()
        print("GP quit \(game)")
        sleep(4)
    }

    /// The game process died, or the game raised an error: the player
    /// shows "<game> stopped", or an alert "The game stopped". It records
    /// the error and goes back to the library for the next game.
    private func stopped(_ app: XCUIApplication, game: String) -> Bool {
        let title = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' stopped'")).firstMatch
        let alert = app.alerts["The game stopped"]
        guard title.exists || alert.exists else { return false }
        shot("stopped-\(game)")
        let text =
            alert.exists
            ? alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / ") : title.label
        print("GP stopped \(game): \(text)")
        XCTFail("\(game) stopped: \(text)")
        if alert.exists {
            alert.buttons.firstMatch.tap()
            sleep(2)
        }
        let back = app.buttons["Back to Library"]
        if back.waitForExistence(timeout: 5) {
            back.tap()
            sleep(2)
        }
        return true
    }

    private func openMore(_ app: XCUIApplication) {
        var menu = app.buttons["More options"].firstMatch
        if !menu.waitForExistence(timeout: 10) {
            let reveal = app.buttons["eye.slash.fill"].firstMatch
            if reveal.waitForExistence(timeout: 5) { reveal.tap() }
            menu = app.buttons["More options"].firstMatch
        }
        if !menu.waitForExistence(timeout: 10) { print("GP tree \(app.debugDescription)") }
        XCTAssertTrue(menu.exists, "no More options button")
        // A notification banner can take the tap. Try again after it goes.
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Pause ' OR label BEGINSWITH 'Quit '")
        ).firstMatch
        for _ in 0..<3 {
            menu.tap()
            if row.waitForExistence(timeout: 5) { break }
            print("GP no sheet after More, trying again")
            sleep(6)
        }
        usleep(1_500_000)
    }

    private func scrollToTop(_ app: XCUIApplication) {
        app.swipeDown()
        app.swipeDown()
    }

    private func card(named title: String, in app: XCUIApplication) -> XCUIElement {
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", title))
            .firstMatch
        if !card.waitForExistence(timeout: 10) {
            for _ in 0..<6 where !card.isHittable {
                app.swipeUp()
            }
        }
        if !card.waitForExistence(timeout: 20) { print("GP tree \(app.debugDescription)") }
        XCTAssertTrue(card.exists, "no card named \(title)")
        return card
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
