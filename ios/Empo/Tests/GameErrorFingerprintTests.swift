// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import XCTest

@testable import Empo

final class GameErrorFingerprintTests: XCTestCase {

    // Pokemon GS Vitro, with Pokémon Essentials before version 19.

    private let vitroFloatEvent18 =
        "Game version: 1.2.1\r\nExcepción: RuntimeError\r\nMensaje: Script error within event 18, map 41 (Route 32):\r\nException: TypeError\r\nMessage: 012:Game_System:182:in `+': can't convert Float into String\r\n***Full script:\r\nparty = [\ncreatePokemon(clGenPkmn(true)),\ncreatePokemon(clGenPkmn(true))]\ntrainer = createTrainer(37, \"Aldo\", party)\nresult = customTrainerBattle(trainer, \n_I(\"¡Eres fuerte!\"))\npbSet(1, result == BR_WIN ? 0 : 1)\n\r\n044:Interpreter:247:in `pbExecuteScript'\r\n012:Game_System:182:in `bgs_play'\r\n012:Game_System:211:in `bgs_resume'\r\n241:EliteBattle_EntryAnimations:208:in `pbBattleAnimation'\r\n134:PTrainer_BES-T_CustomTrainers:246:in `customTrainerBattle'\r\n(eval):5:in `pbExecuteScript'\r\n044:Interpreter:1611:in `eval'\r\n044:Interpreter:247:in `pbExecuteScript'\r\n044:Interpreter:1611:in `command_355'\r\n044:Interpreter:498:in `execute_command'\r\n\r\n044:Interpreter:280:in `pbExecuteScript'\r\n044:Interpreter:1611:in `command_355'\r\n044:Interpreter:498:in `execute_command'\r\n044:Interpreter:197:in `update'\r\n044:Interpreter:110:in `loop'\r\n044:Interpreter:110:in `update'\r\n064:Scene_Map:103:in `subtitle_system_update_alias'\r\n064:Scene_Map:101:in `loop'\r\n064:Scene_Map:101:in `subtitle_system_update_alias'\r\n228:Creditos:667:in `updateTime'\r\n\r\nEsta excepción ha sido registrada en ./errorlog.txt.\r\nPresiona Ctrl+C para copiar este mensaje al portapapeles."

    private let vitroFloatEvent13 =
        "Game version: 1.2.1\r\nExcepción: RuntimeError\r\nMensaje: Script error within event 13, map 41 (Route 32):\r\nException: TypeError\r\nMessage: 012:Game_System:182:in `+': can't convert Float into String\r\n***Full script:\r\npbTrainerBattle(PBTrainers::PICNICKER,\"Lisi\",_I(\"¡Bah! He perdido justamente cuando estaba empezando a entrar en calor.\"),false,0,false,0)\r\n044:Interpreter:247:in `pbExecuteScript'\r\n012:Game_System:182:in `bgs_play'\r\n012:Game_System:211:in `bgs_resume'\r\n241:EliteBattle_EntryAnimations:208:in `pbBattleAnimation'\r\n122:PField_Battles:240:in `discord_pbTrainerBattle'\r\n372:Discord Rich Presence:374:in `pbTrainerBattle'\r\n(eval):1:in `pbExecuteScript'\r\n044:Interpreter:798:in `eval'\r\n044:Interpreter:247:in `pbExecuteScript'\r\n044:Interpreter:798:in `command_111'\r\n\r\n044:Interpreter:280:in `pbExecuteScript'\r\n044:Interpreter:798:in `command_111'\r\n044:Interpreter:324:in `execute_command'\r\n044:Interpreter:197:in `update'\r\n044:Interpreter:110:in `loop'\r\n044:Interpreter:110:in `update'\r\n064:Scene_Map:103:in `subtitle_system_update_alias'\r\n064:Scene_Map:101:in `loop'\r\n064:Scene_Map:101:in `subtitle_system_update_alias'\r\n228:Creditos:667:in `updateTime'\r\n\r\nEsta excepción ha sido registrada en ./errorlog.txt.\r\nPresiona Ctrl+C para copiar este mensaje al portapapeles."

    private func vitroMart(version: String) -> String {
        "Game version: \(version)\r\nExcepción: NoMethodError\r\nMensaje: undefined method `money' for nil:NilClass\r\n176:PScreen_Mart:6:in `getMoney'\r\n340:PScreen_Mart_EXPANDED:102:in `pbRefresh'\r\n176:PScreen_Mart:241:in `pbStartBuyOrSellScene'\r\n176:PScreen_Mart:246:in `pbStartBuyScene'\r\n340:PScreen_Mart_EXPANDED:123:in `pbBuyScreen'\r\ncheat_pe19:113:in `update_cheat'\r\ncheat_pe19:84:in `update'\r\ncheat_pe19:76:in `main'\r\ncheat_pe19:72:in `loop'\r\ncheat_pe19:72:in `main'\r\n\r\nEsta excepción ha sido registrada en ./errorlog.txt.\r\nPresiona Ctrl+C para copiar este mensaje al portapapeles."
    }

    // Pokémon Essentials 19.1.

    private func unbreakableTies(message: String) -> String {
        "[Pokémon Essentials version 19.1]\r\n[Generation 8 Project v1.1.2]\r\n\r\nException: Errno::ENOENT\r\nMessage: \(message)\r\n\r\nBacktrace:\r\nwindows_fs:1348:in `mtime'\r\nwindows_fs:1348:in `mtime'\r\n007:005_PluginManager.rb:645:in `block in needCompiling?'\r\n007:005_PluginManager.rb:638:in `each'\r\n007:005_PluginManager.rb:638:in `needCompiling?'\r\n007:005_PluginManager.rb:685:in `runPlugins'\r\n307:999_Main.rb:29:in `mainFunctionDebug'\r\n307:999_Main.rb:19:in `block in mainFunction'\r\n011:003_Errors.rb:70:in `pbCriticalCode'\r\n307:999_Main.rb:19:in `mainFunction'\r\n\r\nThis exception was logged in \r\n\\var\\mobile\\Containers\\Data\\Application\\30FD35D1-CCA3-49EA-9C33-686BE15C7EF0\\Documents\\Data\\Pokémon Unbreakable Ties\\errorlog.txt.\r\nHold Ctrl when closing this message to copy it to the clipboard."
    }

    private let solarEclipse =
        "[Pokémon Essentials version 19.1]\r\n[Generation 8 Project v1.1.2]\r\n[EBDX v1.2.6]\r\n\r\nException: RuntimeError\r\nMessage: Unknown ID DOUBLE TEAM.\r\n\r\nBacktrace:\r\n102:GameData:32:in `get'\r\n252:Pokemon_Move:50:in `function_code'\r\n162:PokeBattle_Move:52:in `from_pokemon_move'\r\n151:Battler_Initialize:102:in `block in pbInitPokemon'\r\n151:Battler_Initialize:92:in `each'\r\n151:Battler_Initialize:92:in `each_with_index'\r\n151:Battler_Initialize:92:in `pbInitPokemon'\r\n258:ShadowPokemon_Other:193:in `pbInitPokemon'\r\n151:Battler_Initialize:62:in `pbInitialize'\r\n177:Battle_Action_Switching:283:in `pbReplace'\r\n\r\nThis exception was logged in \r\n\\var\\mobile\\Containers\\Data\\Application\\81CA5064-B75E-4FD5-9248-075AAA4E0328\\Documents\\Data\\Pokemon Solar Eclipse\\errorlog.txt.\r\nHold Ctrl when closing this message to copy it to the clipboard."

    // Errors in a map event script, which the engine shows as the
    // RuntimeError of the event interpreter.

    private let pokemonZTypeErrorScript10 =
        "Script 'Interpreter' line 276: RuntimeError occurred.\n\nScript error within event 15, map 55 (5번도로):\r\nException: TypeError\r\nMessage: 010:Game_System:71:in `+': can't convert Array into String\r\n***Full script:\r\npbTrainerBattle(PBTrainers::BURGUESA,\"Diana\",_I(\"¡Impertinente! ¡Pienso vetarte de la alta sociedad!\"),false,0,false,0)\r\n039:Interpreter:243:in `pbExecuteScript'\r\n010:Game_System:71:in `bgm_play_internal'\r\n010:Game_System:105:in `bgm_resume'\r\n191:Transiciones:1504:in `pbBattleAnimation'\r\n249:Combate Inverso:266:in `pbTrainerBattle'\r\n(eval):1:in `pbExecuteScript'\r\n039:Interpreter:794:in `eval'\r\n039:Interpreter:243:in `pbExecuteScript'\r\n039:Interpreter:794:in `command_111'\r\n039:Interpreter:320:in `execute_command'"

    private let pokemonZTypeErrorScript7 =
        "Script 'Interpreter' line 276: RuntimeError occurred.\n\nScript error within event 13, map 55 (Route 5):\r\nException: TypeError\r\nMessage: 007:Game_System:71:in `+': can't convert Array into String\r\n***Full script:\r\npbTrainerBattle(PBTrainers::CAMPESINO,\"Daniel\",_I(\"Ahora tengo un nuevo miedo en mi corazón.\"),false,0,false,0)\r\n033:Interpreter:243:in `pbExecuteScript'\r\n007:Game_System:71:in `bgm_play_internal'\r\n007:Game_System:105:in `bgm_resume'\r\n170:Transiciones:1504:in `pbBattleAnimation'\r\n228:Combate Inverso:266:in `pbTrainerBattle'\r\n(eval):1:in `pbExecuteScript'\r\n033:Interpreter:794:in `eval'\r\n033:Interpreter:243:in `pbExecuteScript'\r\n033:Interpreter:794:in `command_111'\r\n033:Interpreter:320:in `execute_command'"

    private let pokemonZMissingMusic =
        "Script 'Interpreter' line 276: RuntimeError occurred.\n\nScript error within event 13, map 55 (5번도로):\r\nException: Errno::ENOENT\r\nMessage: Archivo 010:Game_System:59:in `bgm_play': No such file or directory - Audio/BGM// no encontrado.\r\n***Full script:\r\npbTrainerBattle(PBTrainers::CAMPESINO,\"Daniel\",_I(\"Ahora tengo un nuevo miedo en mi corazón.\"),false,0,false,0)\r\n039:Interpreter:243:in `pbExecuteScript'\r\n010:Game_System:59:in `bgm_play_internal2'\r\n010:Game_System:72:in `bgm_play_internal'\r\n010:Game_System:105:in `bgm_resume'\r\n191:Transiciones:1504:in `pbBattleAnimation'\r\n249:Combate Inverso:266:in `pbTrainerBattle'\r\n(eval):1:in `pbExecuteScript'\r\n039:Interpreter:794:in `eval'\r\n039:Interpreter:243:in `pbExecuteScript'\r\n039:Interpreter:794:in `command_111'"

    private let uncensoredMissingPicture =
        "Script 'Interpreter' line 276: RuntimeError occurred.\n\nScript error within event 2, map 7 (Fucksia City Poké Center):\r\nException: Errno::ENOENT\r\nMessage: File windows_fs:1305:in `_mkxp_orig_delete': Graphics/Characters/Healing balls left.png not found.\r\n***Full script:\r\nMakeHealingBallGraphics.new\n\r\n038:Interpreter:243:in `pbExecuteScript'\r\nwindows_fs:1305:in `delete'\r\n187:Improved PokeCénters by mej:49:in `initialize'\r\n(eval):1:in `new'\r\n(eval):1:in `pbExecuteScript'\r\n038:Interpreter:1606:in `eval'\r\n038:Interpreter:243:in `pbExecuteScript'\r\n038:Interpreter:1606:in `command_355'\r\n038:Interpreter:494:in `execute_command'\r\n038:Interpreter:193:in `update'"

    private func ecchiShowcase(bitmap: String) -> String {
        "Script 'Interpreter' line 281: RuntimeError occurred.\n\nScript error within map 1 (Intro):\r\nException: NoMethodError\r\nMessage: undefined method `save_to_file' for #<Bitmap:\(bitmap)>\r\n***Full script:\r\npbClothingCheck\n$forfeit = false\n$trainerbattle = false\n\r\n039:Interpreter:243:in `pbExecuteScript'\r\n232:PScreen_Wardrobe:599:in `pbClothingCheck'\r\n(eval):1:in `pbExecuteScript'\r\n039:Interpreter:1606:in `eval'\r\n039:Interpreter:243:in `pbExecuteScript'\r\n039:Interpreter:1606:in `command_355'\r\n039:Interpreter:494:in `execute_command'\r\n039:Interpreter:193:in `update'\r\n039:Interpreter:106:in `loop'\r\n039:Interpreter:106:in `update'"
    }

    func testHeaderLinesDoNotNameTheError() {
        XCTAssertNotEqual(
            ErrorReports.gameErrorFingerprint(vitroFloatEvent18),
            ErrorReports.gameErrorFingerprint(vitroMart(version: "1.2.1")))
        XCTAssertNotEqual(
            ErrorReports.gameErrorFingerprint(solarEclipse),
            ErrorReports.gameErrorFingerprint(
                unbreakableTies(
                    message:
                        "File No such file or directory @ rb_file_s_mtime - Plugins/Redistribuidor EVS/meta.txt not found."
                )))
    }

    func testTheSameErrorInAnotherEventIsOneIssue() {
        XCTAssertEqual(
            ErrorReports.gameErrorFingerprint(vitroFloatEvent18),
            ErrorReports.gameErrorFingerprint(vitroFloatEvent13))
        XCTAssertEqual(
            ErrorReports.gameErrorFingerprint(vitroMart(version: "1.2.0")),
            ErrorReports.gameErrorFingerprint(vitroMart(version: "1.2.1")))
    }

    func testTheErrorsInAnEventScriptAreSeparateIssues() {
        let fingerprints = [pokemonZTypeErrorScript10, pokemonZMissingMusic, uncensoredMissingPicture].map(
            ErrorReports.gameErrorFingerprint)
        XCTAssertEqual(Set(fingerprints).count, 3)
    }

    func testTheSameErrorInAnotherGameVersionIsOneIssue() {
        XCTAssertEqual(
            ErrorReports.gameErrorFingerprint(pokemonZTypeErrorScript10),
            ErrorReports.gameErrorFingerprint(pokemonZTypeErrorScript7))
    }

    func testAnObjectAddressIsNotPartOfTheIssue() {
        XCTAssertEqual(
            ErrorReports.gameErrorFingerprint(ecchiShowcase(bitmap: "0x133da4ec0")),
            ErrorReports.gameErrorFingerprint(ecchiShowcase(bitmap: "0x136dbd990")))
    }

    func testAMissingFileOnAnotherMapIsOneIssue() {
        XCTAssertEqual(
            ErrorReports.gameErrorFingerprint(unbreakableTies(message: "File Data/Map150.rxdata not found.")),
            ErrorReports.gameErrorFingerprint(unbreakableTies(message: "File Data/Map151.rxdata not found.")))
    }

    func testTheErrorAndThePlaceInTheScriptNameTheIssue() {
        XCTAssertEqual(
            ErrorReports.gameErrorFingerprint(unbreakableTies(message: "Errno::ENOENT")),
            ["error", "Exception: Errno::ENOENT\nMessage: Errno::ENOENT\nwindows_fs:0:in `mtime'"])
    }

    func testTheEngineErrorLineNamesTheError() {
        let cursor =
            "Script 'rpg_vxace' line 960: Errno::ENOENT occurred.\n\nNo such file or directory - Audio/SE/Cursor1"
        let ice =
            "Script 'rpg_vxace' line 960: Errno::ENOENT occurred.\n\nNo such file or directory - Audio/SE/Ice1"
        XCTAssertEqual(ErrorReports.gameErrorFingerprint(cursor), ErrorReports.gameErrorFingerprint(ice))
        XCTAssertEqual(
            ErrorReports.gameErrorFingerprint(cursor),
            ["error", "Script 'rpg_vxace' line 960: Errno::ENOENT occurred."])
    }

    func testTheErrorAndItsMessageNameTheTitle() {
        XCTAssertEqual(
            [vitroMart(version: "1.2.1"), vitroFloatEvent18, solarEclipse, pokemonZTypeErrorScript10].map(
                ErrorReports.gameErrorTitle),
            [
                "NoMethodError: undefined method `money' for nil:NilClass",
                "TypeError: 012:Game_System:182:in `+': can't convert Float into String",
                "RuntimeError: Unknown ID DOUBLE TEAM.",
                "TypeError: 010:Game_System:71:in `+': can't convert Array into String",
            ])
    }

    func testAnErrorWithNoMessageNamesOnlyTheError() {
        XCTAssertEqual(
            ErrorReports.gameErrorTitle("Exception: RangeError\r\nMessage: \r\n\r\nBacktrace:"), "RangeError")
    }

    func testTheEngineErrorLineKeepsTheTitle() {
        XCTAssertNil(
            ErrorReports.gameErrorTitle(
                "Script 'rpg_vxace' line 960: Errno::ENOENT occurred.\n\nNo such file or directory - Audio/SE/Cursor1"
            ))
    }
}
