# Translating Empo

Empo keeps all its screen text in `Resources/Localizable.xcstrings`. The system prompts (camera, Bluetooth, local network) are in `Resources/InfoPlist.xcstrings`. English is the source language. Empo ships English, French, Spanish, German, Italian, Brazilian Portuguese, Japanese, Korean, Simplified Chinese, and Russian.

Read this file before you add or change a translation.

## Who writes Empo

One person builds Empo in their spare time. It is a small open-source app, not a company product. The English text speaks like a friend who knows the app well:

- Short, plain sentences. One idea in each sentence.
- Warm, never cold or corporate. "Enjoy!", "Here be dragons", and "I build Empo alone in my spare time." are the voice.
- Direct about risk. "You can't undo this." stays as plain in each language.
- No marketing words, no exclamation marks that the English does not have.

Keep this voice. A translation that is correct but stiff is wrong for Empo. Write what a native speaker who plays games would write in a small indie app, not what a bank app would write.

## Form of address

| Language | Use | Example |
|---|---|---|
| French | "tu" | "Tu ne peux pas annuler." |
| Spanish | "tú", neutral Spanish for Spain and Latin America | "No puedes deshacer esto." |
| German | "du", lower case | "Du kannst das nicht rückgängig machen." |
| Italian | "tu" | "Non puoi annullare." |
| Brazilian Portuguese | "você" | "Você não pode desfazer isso." |
| Japanese | Light です/ます. No 尊敬語 or 謙譲語. | 「元に戻せません。」 |
| Korean | 해요체 | "되돌릴 수 없어요." |
| Simplified Chinese | 你, never 您 | "此操作无法撤销。" |
| Russian | "вы", lower case | "Это действие нельзя отменить." |

## Words that stay in English

- Empo.
- Engine and core names: RPG Maker XP, VX, VX Ace, MV, MZ, Pokemon Essentials, PSDK, mkxp-z, Ruby, JoiPlay.
- File types and extensions: `.zip`, `.7z`, `.rar`, `.jgp`, `Game.exe`.
- "Rescued Saves". It is the name of a real folder in the Files app. Put it in the quotation marks of the language, for example « Rescued Saves » in French and 「Rescued Saves」 in Japanese.
- GitHub, Twitter.
- Key names on a keyboard or a controller when they name the key itself: A, B, X, Y, L, R, Esc, Shift, Enter, F1 to F12.

## Words with one translation

Use the same word each time. Use Apple's own word for an Apple app or feature, as iOS shows it in that language.

| English | Meaning in Empo |
|---|---|
| Library | The screen with all imported games. |
| game | One imported game. |
| game core | The engine that runs a type of game. Translate "game" and keep "core" as a short technical word if the language uses it, for example "cœur de jeu" (French), "núcleo" (Spanish), "Spielkern" (German), "core di gioco" (Italian), "núcleo" (Portuguese), ゲームコア, 게임 코어, 游戏核心, игровое ядро. |
| layout profile, profile | A saved set of on-screen controls. Not a user account. |
| controls | The on-screen buttons, D-pad, and joystick. |
| saves | The save files of a game. |
| import | Add a game to the library. |
| Files | Apple's Files app. Use the name iOS shows: Fichiers, Archivos, Dateien, File, Arquivos, ファイル, 파일, 文件, Файлы. |
| app switcher | Apple's term for the screen of open apps, in each language. |
| Settings | Empo's Settings screen. |

## Format

- Keep every placeholder (`%@`, `%lld`, `%%`) and its order. Do not translate what is inside Markdown links, only the link text.
- Give each string with a number its plural forms. Russian needs one, few, many, and other. French, Spanish, Italian, and Portuguese need one, many, and other. Japanese, Korean, and Chinese need only other.
- Keep a translation about as long as the English. Buttons and labels have little space. If a natural translation is much longer, pick a shorter word.
- Use the quotation marks of the language: « » for French and Russian, „ “ for German, « » for Italian, “ ” for Portuguese, 「」 for Japanese, “ ” for Chinese and Korean, “ ” for Spanish.
- Use the normal punctuation of the language. Japanese and Chinese use full-width punctuation. French puts a non-breaking space before `?`, `!`, `:`, and `;`.

## Review

An AI agent makes the first translation. A native speaker checks it in a TestFlight build. Mark a string "needs review" in the catalog when you are not sure of it.
