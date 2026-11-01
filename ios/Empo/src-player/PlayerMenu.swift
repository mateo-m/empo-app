// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit

/// The menu bar of Empo Player. The app menu carries the game's name,
/// because each game runs in a process of its own.
@MainActor
enum PlayerMenu {
    static let windowMenuTag = 1

    static func make(gameTitle: String, fastForward: Int?) -> NSMenu {
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

        var gameItems = [item(String(localized: "Pause"), #selector(PlayerAppDelegate.togglePause(_:)), "p")]
        if let fastForward {
            gameItems.append(
                item(
                    String(
                        localized: "Fast Forward (\(fastForward)×)",
                        comment:
                            "Menu item that turns fast forward on and off. The placeholder is the speed, such as 4."
                    ),
                    #selector(PlayerAppDelegate.toggleFastForward(_:)), "f"))
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
        return bar
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
