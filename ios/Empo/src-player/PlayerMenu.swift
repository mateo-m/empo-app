// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit

/// The menu bar of Empo Player. The app menu carries the game's name,
/// because each game runs in a process of its own.
@MainActor
enum PlayerMenu {
    static let windowMenuTag = 1
    private static let fastForwardTag = 2

    static func make(gameTitle: String, fastForward: Int?, cheats: Bool) -> NSMenu {
        let bar = NSMenu()

        bar.addItem(
            submenu(
                gameTitle,
                [
                    item(String(localized: "About Empo"), #selector(PlayerAppDelegate.showAboutEmpo(_:))),
                    .separator(),
                    item(
                        String(
                            localized: "Hide \(gameTitle)",
                            comment: "Menu item. The placeholder is the game's name."),
                        #selector(NSApplication.hide(_:)), "h"),
                    item(
                        String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)),
                        "h",
                        [.command, .option]),
                    item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
                    .separator(),
                    item(
                        String(
                            localized: "Quit \(gameTitle)",
                            comment: "Menu item. The placeholder is the game's name."),
                        #selector(NSApplication.terminate(_:)), "q"),
                ]))

        let fastForwardItem = item("", #selector(PlayerAppDelegate.toggleFastForward(_:)))
        fastForwardItem.tag = fastForwardTag
        var gameItems = [
            item(String(localized: "Pause"), #selector(PlayerAppDelegate.togglePause(_:)), "p"),
            fastForwardItem,
        ]
        if cheats {
            gameItems.append(
                item(
                    String(localized: "Show Cheats", comment: "Menu item that opens the game's cheat menu."),
                    #selector(PlayerAppDelegate.showCheats(_:))))
        }
        bar.addItem(
            submenu(
                String(localized: "File"),
                [item(String(localized: "Close"), #selector(PlayerAppDelegate.closeGame(_:)), "w")]))

        bar.addItem(submenu(String(localized: "Game"), gameItems))

        bar.addItem(
            submenu(
                String(localized: "View"),
                [
                    item(
                        String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f",
                        [.command, .control])
                ]
            ))

        let window = submenu(
            String(localized: "Window"),
            [
                item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
                item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
            ])
        window.tag = windowMenuTag
        bar.addItem(window)
        update(bar, fastForward: fastForward)
        return bar
    }

    /// Nil hides the Fast Forward item.
    static func update(_ bar: NSMenu, fastForward: Int?) {
        guard let item = bar.items.lazy.compactMap({ $0.submenu?.item(withTag: fastForwardTag) }).first
        else { return }
        item.isHidden = fastForward == nil
        item.keyEquivalent = fastForward == nil ? "" : "f"
        item.title = String(
            localized: "Fast Forward (\(fastForward ?? 0)×)",
            comment: "Menu item that turns fast forward on and off. The placeholder is the speed, such as 4.")
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
