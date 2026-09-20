import GameProbe
import XCTest

@testable import Empo

/// The builtin buttons follow the core that runs the game. A PSDK game
/// reads V as its main menu key and answers nothing for Z, so the set
/// for that core drops Z.
@MainActor
final class ControlsLayoutDefaultsTests: XCTestCase {

    private var made: [GameContainer] = []

    override func tearDown() async throws {
        ControlsLayout.shared.switchGame(id: nil, container: nil)
        for container in made {
            try? FileManager.default.removeItem(at: container.url)
        }
        made = []
    }

    func testPsdkGameSwapsZForV() throws {
        let psdk = try container(named: "psdk", psdk: true)
        let rpgMaker = try container(named: "rpg-maker", psdk: false)

        ControlsLayout.shared.switchGame(id: rpgMaker.id, container: rpgMaker)
        XCTAssertEqual(
            scancodes(),
            [
                Int32(GAMECORE_SCANCODE_RETURN), Int32(GAMECORE_SCANCODE_ESCAPE),
                Int32(GAMECORE_SCANCODE_Z), Int32(GAMECORE_SCANCODE_B),
            ])

        ControlsLayout.shared.switchGame(id: psdk.id, container: psdk)
        XCTAssertEqual(
            scancodes(),
            [
                Int32(GAMECORE_SCANCODE_RETURN), Int32(GAMECORE_SCANCODE_ESCAPE),
                Int32(GAMECORE_SCANCODE_V), Int32(GAMECORE_SCANCODE_B),
            ])

        ControlsLayout.shared.switchGame(id: nil, container: nil)
        XCTAssertEqual(
            scancodes(),
            [
                Int32(GAMECORE_SCANCODE_RETURN), Int32(GAMECORE_SCANCODE_ESCAPE),
                Int32(GAMECORE_SCANCODE_Z), Int32(GAMECORE_SCANCODE_B),
            ])
    }

    private func scancodes() -> [Int32] {
        ControlsLayout.defaultButtonsPortrait.map(\.scancode)
    }

    /// A game folder the core detection accepts. `PsdkGame.isGameRoot`
    /// asks for a `Game.rb` next to a `Game.yarb` that starts with
    /// Ruby's bytecode magic.
    ///
    /// GameContainer keeps every game under `Documents/Games`, so the
    /// folder goes there and tearDown removes it.
    private func container(named name: String, psdk: Bool) throws -> GameContainer {
        let container = GameContainer(folderName: "\(name)-\(UUID().uuidString)")
        made.append(container)
        try FileManager.default.createDirectory(
            at: container.gameURL, withIntermediateDirectories: true)
        try Data("# game".utf8).write(to: container.gameURL.appendingPathComponent("Game.rb"))
        if psdk {
            try Data("YARB0000".utf8).write(
                to: container.gameURL.appendingPathComponent("Game.yarb"))
        }
        return container
    }
}
