// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case fr
    case es
    case de
    case it
    case ptBR = "pt-BR"
    case ja
    case ko
    case zhHans = "zh-Hans"
    case ru

    var id: Self { self }

    // iOS keeps the per-app language as "AppleLanguages" in the app's
    // own defaults domain. The Language page that the Settings app
    // shows for Empo reads and writes the same key. The bundle reads
    // it once at launch, so a change applies after Empo reopens.
    private static let defaultsKey = "AppleLanguages"

    static var current: AppLanguage {
        guard
            let domain = Bundle.main.bundleIdentifier.flatMap(
                UserDefaults.standard.persistentDomain(forName:)),
            let code = (domain[defaultsKey] as? [String])?.first
        else { return .system }
        let saved = Locale.Language(identifier: code).fullForm
        return allCases.first { language in
            guard language != .system else { return false }
            let candidate = Locale.Language(identifier: language.rawValue).fullForm
            return candidate.languageCode == saved.languageCode && candidate.script == saved.script
        } ?? .system
    }

    static let atLaunch = current

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.defaultsKey)
        }
    }

    // Each language shows its name in that language, so a person who
    // can't read the current one still finds their own.
    var label: Text {
        guard self != .system else {
            return Text(
                "System", comment: "Option that follows the device setting, for the theme or the language.")
        }
        let locale = Locale(identifier: rawValue)
        let name = locale.localizedString(forIdentifier: rawValue) ?? rawValue
        return Text(verbatim: name.capitalized(with: locale))
    }
}

struct LanguagePicker: View {
    @State private var selection = AppLanguage.current

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Picker(selection: $selection) {
                ForEach(AppLanguage.allCases) { language in
                    language.label.tag(language)
                }
            } label: {
                Text("Language")
            }
            Group {
                if selection == AppLanguage.atLaunch {
                    Text("System uses your device's language when Empo has it, and English when it doesn't.")
                } else {
                    Text("Close Empo from the app switcher, then reopen it to use the new language.")
                        .foregroundStyle(Color.brand)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.xxs)
        .onChange(of: selection) {
            selection.apply()
        }
    }
}

extension Locale.Language {
    // "zh-Hans" and "zh-Hant" share the language code, so a match
    // must compare the script too. "fr" has no script until it is
    // expanded to "fr-Latn-FR".
    fileprivate var fullForm: Locale.Language { Locale.Language(identifier: maximalIdentifier) }
}
