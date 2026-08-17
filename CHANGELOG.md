# Changelog

## 0.6.2 - 2026-08-17

### Bug Fixes

- Pick up the Essentials mouse release fix (#122) (#127) ([`1b92ecd`](https://github.com/mateo-m/empo-app/commit/1b92ecd2a2f750a3981ef3b97d64e34183d095f0))
- Pick up the whole-file CRLF read fix (#130) ([`c576390`](https://github.com/mateo-m/empo-app/commit/c5763902496990bf0016683946f5c11e3c7a06e7))

### CI

- Gate pull request titles on the commit convention (#124) ([`44740fc`](https://github.com/mateo-m/empo-app/commit/44740fcb60d44daee57994220044c8ebf20de2e4))
- Skip code jobs on docs-only pull requests and gate merges on the whole workflow (#126) ([`010db63`](https://github.com/mateo-m/empo-app/commit/010db639dbd8b734bc5bead2d830c0ecb55068e1))

### Documentation

- Publish the documentation site on GitHub Pages (#125) ([`5993a47`](https://github.com/mateo-m/empo-app/commit/5993a475fa42d6ceeb48efe22b8ebc83ce0f3081))
- Pick up the socket stub comment correction (#129) ([`2cf00dd`](https://github.com/mateo-m/empo-app/commit/2cf00dda6eef37648ee5b107d2702218713095df))

### Features

- Pick up the ws2_32 socket bridge (#128) ([`8e4501c`](https://github.com/mateo-m/empo-app/commit/8e4501c6253ddb302f89475c5e5ea7fceb397327))

## 0.6.1 - 2026-08-13

### Bug Fixes

- Recover renamed saves and guard the engine recovery (#123) ([`658e9e9`](https://github.com/mateo-m/empo-app/commit/658e9e9b0828d72ce2245a75c18c4f27fbc25fc8))

## 0.6.0 - 2026-08-11

### Bug Fixes

- Decode CP1252 INI titles and migrate mojibake folders ([`705c421`](https://github.com/mateo-m/empo-app/commit/705c421d3c36432356c8962660ea9814fd003952))
- Pick up the recovery for stranded portable saves (#115) ([`d60545c`](https://github.com/mateo-m/empo-app/commit/d60545cacc977a03a4790bdeef66adcf6d550afe))
- Pick up unlimited tileset sizes (#116) ([`30e552e`](https://github.com/mateo-m/empo-app/commit/30e552e6204bd2c8c85be648ba2ea45f6f385221))
- Stop the legacy method stubs from faking respond_to? (#118) ([`fcd77be`](https://github.com/mateo-m/empo-app/commit/fcd77be3fba4a399c1ff9b37b1f3a1e2ef95fb4a))

### Chores

- Pin native-2026-08-07 native prebuilts ([`7abe0b0`](https://github.com/mateo-m/empo-app/commit/7abe0b076c63829cad397d6a6beead3924d700df))
- Return the native pin to native-2026-08-04-r2 (#112) ([`6cfddc7`](https://github.com/mateo-m/empo-app/commit/6cfddc76467c036ab02f71ae36abe55ceba53ed2))
- Pin engine-2026-08-06 and the native-2026-08-07 prebuilts (#113) ([`562ba12`](https://github.com/mateo-m/empo-app/commit/562ba12eac9f3f9921a1bc596547fc926dcbaa52))
- Pin the preload fix for Essentials constant probes ([`2757abd`](https://github.com/mateo-m/empo-app/commit/2757abd89d0593d1b6dd44f9620f1ca7b0021608))
- Pin the engine file handle leak fixes ([`5f27573`](https://github.com/mateo-m/empo-app/commit/5f27573f96dadafebe5be1666fa9482e0a53b97b))
- Pin the tilemap patch skip for games that wrap tilesets ([`34624c6`](https://github.com/mateo-m/empo-app/commit/34624c684a34d8a7a41995503cefa6bab414f55d))
- Pin native-2026-08-09 native prebuilts ([`e5f24c1`](https://github.com/mateo-m/empo-app/commit/e5f24c15aefb2014a59b27661665e7e17229ce5b))
- Pin native-2026-08-09-r2 native prebuilts ([`8d5d20d`](https://github.com/mateo-m/empo-app/commit/8d5d20dc209ddf51206c94dd1f5306f9c566bd26))

### Features

- Add touch action buttons and one action registry (#107) ([`7e0f217`](https://github.com/mateo-m/empo-app/commit/7e0f2170ca555ff527eb8bbc782b449f4542744a))
- Add a joystick style for the movement control (#108) ([`6aaca4d`](https://github.com/mateo-m/empo-app/commit/6aaca4d75500567cfb0b961d6c731848d4bd940f))
- Add layout profiles (#109) ([`7da566c`](https://github.com/mateo-m/empo-app/commit/7da566c1ead739a477a4363f636b9bfee48a2079))
- Add screen placement in profiles (#110) ([`fe02433`](https://github.com/mateo-m/empo-app/commit/fe02433659d7e1b1d1277cf9eb5dff5df11b0062))
- Bind controllers that reach iOS as a keyboard (#119) ([`6788371`](https://github.com/mateo-m/empo-app/commit/6788371f9e70db785506f110b40cd6bc7fc9bdf5))
- Handle multi-touch on the on-screen controls (#121) ([`074f2cf`](https://github.com/mateo-m/empo-app/commit/074f2cfd44594018b578c8ce5497e92f3ea29fd0))

## 0.5.0 - 2026-08-04

### Bug Fixes

- Name the swap backup so crash leftovers get swept ([`e474ca7`](https://github.com/mateo-m/empo-app/commit/e474ca783ec74b8e28d1803d8b6ab89946a087f0))
- Update-confirmation copy acknowledges the rest of the batch ([`a48e6a2`](https://github.com/mateo-m/empo-app/commit/a48e6a2d475a85e85f684985b6792623b458662d))
- Harden update swap and close adversarial test findings ([`a540dd7`](https://github.com/mateo-m/empo-app/commit/a540dd7a222a53e87792c33ef706c98fd8672536))
- Close adversarial review findings on update safety ([`a95fbb5`](https://github.com/mateo-m/empo-app/commit/a95fbb5efcfd3e0a20cb33b170ddddfc6f07eefa))
- Harden delete and update flows around shared saves ([`04305f5`](https://github.com/mateo-m/empo-app/commit/04305f510f9f91714254f57da531e51c4fdd233a))
- Harden the container migration and quarantine naming ([`3384094`](https://github.com/mateo-m/empo-app/commit/3384094b9a1e71ff7989cff88ef141db799f7b42))
- Deliver control presses on touch-down via UIKit capture ([`2ab9fd0`](https://github.com/mateo-m/empo-app/commit/2ab9fd0d1da6edaff3d850d162b5a6cd5340f032))
- Disable the touch capture layer in place on edit entry ([`9b0917e`](https://github.com/mateo-m/empo-app/commit/9b0917eb0e6943360a48a93579fe944627cc81b8))
- Show both engine fingerprints in the debug log header ([`8d0323c`](https://github.com/mateo-m/empo-app/commit/8d0323c515df1c6c816caf6b88fef74506f3bf1a))
- Keep archive timestamps on extracted files ([`6399a6b`](https://github.com/mateo-m/empo-app/commit/6399a6bfc61aac74d918f0af53573193e530628d))
- Pick up the postload mixin privacy fix for old Ruby games ([`8e435a8`](https://github.com/mateo-m/empo-app/commit/8e435a875010c74882394e3d719983a0bcb093e3))
- Stop Thread.new from aborting the app in Ruby 1.8 games (#102) ([`3af8b05`](https://github.com/mateo-m/empo-app/commit/3af8b051e8e83f41c9c3671f6116398b3a66ba9a))
- Pick up the Pokemon Essentials sprite, menu, and input fixes (#103) ([`ec7f8a1`](https://github.com/mateo-m/empo-app/commit/ec7f8a1744884558b1ea1cfc42413e9e9e7c1146))

### CI

- Fail fast when the engine pin does not match the submodule ([`29b5352`](https://github.com/mateo-m/empo-app/commit/29b53523ed8960c769c8a84d2c25bac2818eacf9))

### Chores

- Bump submodule with literal portable Save Data and savefs matrix ([`c8de4fe`](https://github.com/mateo-m/empo-app/commit/c8de4fe8479d308d65f5936bbbec712719d7512d))
- Bump submodule with eager static extension load ([`311eba0`](https://github.com/mateo-m/empo-app/commit/311eba090a5bca47dc9b70db6634d490e9e1661b))
- Bump submodule with write-mode case resolution ([`b680929`](https://github.com/mateo-m/empo-app/commit/b6809293ab4555b5440e5a8327b881e16e0ef6aa))
- Bump submodule with reviewed case resolution ([`8dfe78b`](https://github.com/mateo-m/empo-app/commit/8dfe78b190e447bc9b73ea3bfbab0e8c1af0e46a))
- Bump submodule with fully literal game folder ([`847b803`](https://github.com/mateo-m/empo-app/commit/847b803f0c55f6f6869c148303f9f79bba148068))
- Bump submodule with Daybreak compatibility fixes ([`6dec691`](https://github.com/mateo-m/empo-app/commit/6dec691bba774c4400f4b6215801a126a632f67e))
- Pin the core prebuilt to engine-2026-08-02 ([`cdc34aa`](https://github.com/mateo-m/empo-app/commit/cdc34aa414f1e1350f6a5b62e1e0b87ce2d8daea))
- Bump submodule with the disposed-safe wrapper fix ([`d18be59`](https://github.com/mateo-m/empo-app/commit/d18be594a57c139d7d48a5675086ecbf5b911b74))
- Pin the core prebuilt to engine-2026-08-03 ([`30fb782`](https://github.com/mateo-m/empo-app/commit/30fb78281f3e899a54a51e06633eb0828fb6dc21))
- Pin native-2026-08-03 native prebuilts ([`9a01bdb`](https://github.com/mateo-m/empo-app/commit/9a01bdb9c4bf781485ea5f382a78703264d82709))
- Pin native-2026-08-04 native prebuilts ([`9bd66fc`](https://github.com/mateo-m/empo-app/commit/9bd66fce36113dada08bb130cece0010d15e42f5))
- Pin native-2026-08-04-r2 native prebuilts ([`4039c73`](https://github.com/mateo-m/empo-app/commit/4039c73b238d9838e1c7c5c96d72422722e9167f))

### Documentation

- Describe game-managed writes in the layout comment ([`d5738ad`](https://github.com/mateo-m/empo-app/commit/d5738ad33624530be39d9ca0f98d522d736b9ecb))
- Pick up the RAISETRACE table wording fix ([`f6c677d`](https://github.com/mateo-m/empo-app/commit/f6c677d2ddce2813fd4565072099956323bc73b5))

### Features

- Name game containers after their INI title ([`c5ca5f4`](https://github.com/mateo-m/empo-app/commit/c5ca5f4d65d9537d4b58c71563859a36f28d5782))
- Honor mkxp.json dataPathOrg/dataPathApp ([`fa90f3e`](https://github.com/mateo-m/empo-app/commit/fa90f3ebedd4209b700bf9520d291deff683947f))
- Update installed games in place instead of deleting ([`d86bfe7`](https://github.com/mateo-m/empo-app/commit/d86bfe797640ef707ac1aa3a0a87ada0f4f3df4e))
- Make in-place game updates transactional ([`dc54ef4`](https://github.com/mateo-m/empo-app/commit/dc54ef4ae5a5811520c75d0ada2f6b8e5e0083de))
- Per-game update picker and no silent duplicate imports ([`f48e16b`](https://github.com/mateo-m/empo-app/commit/f48e16b3a73375cee361d617d176b7a8d8c17944))
- Stepped import picker separates adding from updating ([`92a2b29`](https://github.com/mateo-m/empo-app/commit/92a2b2953fe72527b9e27d558d936904c890a2e2))
- Enforce one container per title ([`cc6889f`](https://github.com/mateo-m/empo-app/commit/cc6889f2222d5c963eb44da37b6387d910444481))
- Tell the user when duplicate games are moved ([`c5d547f`](https://github.com/mateo-m/empo-app/commit/c5d547f6a262d5a74c7a4d300502207f4ea90e9e))
- Shared-data resolution, save rescue primitives, and hardened naming ([`e177d1a`](https://github.com/mateo-m/empo-app/commit/e177d1a1b9db29247a0ed45864be4338b5818646))
- Store every game's saves in a shared Data directory ([`f4b99d2`](https://github.com/mateo-m/empo-app/commit/f4b99d2a5aa6bb3a4675148b8c89f82fe3ec4563))
- Resolve d-pad input to cardinals near the center ([`5f8a38d`](https://github.com/mateo-m/empo-app/commit/5f8a38da3c3dfedc9d31db9b99edb752138458a1))
- Protect portable saves and drop identical duplicates in merges ([`e8667f2`](https://github.com/mateo-m/empo-app/commit/e8667f2819e5e3b2861c449e07c85cac0b5e4cc5))
- Rescue portable saves into a Rescued Saves tree ([`2164206`](https://github.com/mateo-m/empo-app/commit/216420635049dacc2db2e836e826067220840919))
- Keep game cards visible while a delete runs ([`820378e`](https://github.com/mateo-m/empo-app/commit/820378e9bd79ff7a3acc931f2cd030310cefde48))
- Restore rescued saves on import and rework the delete alerts ([`0eedf25`](https://github.com/mateo-m/empo-app/commit/0eedf254be8c0ad50f3b9eab7a7adefe494ab52c))
- Pick up RAISETRACE dumps for silently-swallowed script errors ([`9dfa9ec`](https://github.com/mateo-m/empo-app/commit/9dfa9ececa61e81b04af80bbcb261ce2bb8e9e07))
- Scale the FPS graph to the game's frame cap and drop the VSync toggle (#104) ([`6d84afa`](https://github.com/mateo-m/empo-app/commit/6d84afa74df9de2b7ec10cfe8a07b4859e5434c9))
- Support basic and micro profile controllers (#105) ([`11dbd06`](https://github.com/mateo-m/empo-app/commit/11dbd063a7173e9fb2f05b791b257a4699635364))

### Other

- Extract pure import/migration logic and cover it ([`a5020f9`](https://github.com/mateo-m/empo-app/commit/a5020f9cec8822c5c9c6eeb3577fac7a2471846f))
- Extract d-pad touch logic to GameProbe and cover it ([`5e5947e`](https://github.com/mateo-m/empo-app/commit/5e5947e7a4bd8b4096de98ba8d9346247a0f202f))
- Close mutation gaps ([`eb7b9d1`](https://github.com/mateo-m/empo-app/commit/eb7b9d1fc423282f444a37695ff4714e39610beb))
- Derive from a hand-authored landscape source ([`c8135ce`](https://github.com/mateo-m/empo-app/commit/c8135ce6a25f527be223a743301c71fbe7bef303))
- Keep the landscape fixture inside the touch zone ([`9baf7f3`](https://github.com/mateo-m/empo-app/commit/9baf7f3ac1b477f210b9ee099b8957cbedd2c347))

### Performance

- Granular card invalidation and off-main artwork decodes (#106) ([`f323d02`](https://github.com/mateo-m/empo-app/commit/f323d0236744bd2466383c91c05564ec4ca8b821))

### Refactor

- Rename shared data directory SaveData to GameData ([`fb4527f`](https://github.com/mateo-m/empo-app/commit/fb4527f68025789f23674880640a400956051835))

## 0.4.2 - 2026-07-23

### Bug Fixes

- Restore https support via single-source buildconfig header ([`2645e14`](https://github.com/mateo-m/empo-app/commit/2645e14d3b8834608c1541ba8eafd1500129fa7e))

### Chores

- Pin native-2026-07-23 native prebuilts ([`043bb12`](https://github.com/mateo-m/empo-app/commit/043bb122c1e24b6bc04ed96a3de09cebe20c4ef9))

### Documentation

- Reorganize documentation ([`9f49ce0`](https://github.com/mateo-m/empo-app/commit/9f49ce01e07516ee27ba14939e7e5d0e747c72b1))

### Features

- Parse config files with the engine's json5pp parser ([`42806c4`](https://github.com/mateo-m/empo-app/commit/42806c47d09884091b8133f8fb7f5a7aefdb7a02))

### Other

- Assert manifest round trip at the wire level ([`b5a2607`](https://github.com/mateo-m/empo-app/commit/b5a26078b6d3ece7a25a3db95b8cbcb956bb3602))
- Compare json5pp-parsed coordinates with a tolerance ([`efd896b`](https://github.com/mateo-m/empo-app/commit/efd896bc0dbdd279686e9bc9a695b01bfcab2640))

### Refactor

- Remove the curated patch distribution ([`d0dd896`](https://github.com/mateo-m/empo-app/commit/d0dd896be8f7b257be016c73b3561a38b884a296))

### UI

- Cleanup comments & docs ([`b9960a7`](https://github.com/mateo-m/empo-app/commit/b9960a7e23f300314aa57e8427d4a59f5dfcb02c))

## 0.4.1 - 2026-07-22

### Bug Fixes

- Grant release workflow pull-requests write for the sync PR ([`62c2d10`](https://github.com/mateo-m/empo-app/commit/62c2d106a4c19d42af553baf6592503754ba0649))
- Format generated altstore-source.json before the sync commit ([`f99e31f`](https://github.com/mateo-m/empo-app/commit/f99e31fe55e4f4ef1ecbf0c5bb18dd39d977ad2d))
- Newline-terminate the announce notes heredoc ([`3d88bc5`](https://github.com/mateo-m/empo-app/commit/3d88bc528e95dda1af332b067e889b7d0fe328f6))

### CI

- Consolidate nine workflows into ci, release, and deps-publish ([`0a36f70`](https://github.com/mateo-m/empo-app/commit/0a36f70a4ff0d4e8a5acba7dad55b336b8471d65))
- Announce mode to re-post a release to Discord ([`a11629d`](https://github.com/mateo-m/empo-app/commit/a11629d823e9e2d98b596be07a67d9b693ff60e8))

### Chores

- Bump submodule with bool-coercion postload for strict setters ([`4b8f1a4`](https://github.com/mateo-m/empo-app/commit/4b8f1a45e6f88c8503137d136fd77abc7d261e6d))
- Pin native-2026-07-22-r4 with bool-coercion binding objects ([`5428219`](https://github.com/mateo-m/empo-app/commit/5428219c0a1ee48afabcdbc0300b5a3ba15ffb2c))

### Release

- Finish releases from release.sh without a sync PR ([`a133ae6`](https://github.com/mateo-m/empo-app/commit/a133ae6c628f14466e8968e1027c477d8bb6984c))

## 0.4.0 - 2026-07-22

### Bug Fixes

- Skip engine-core check during native hydration ([`e574c88`](https://github.com/mateo-m/empo-app/commit/e574c88dd7ad5afe306db0cfd6cd6e95d4147187))
- Shim versioned automake names and disable matrix fail-fast ([`bb1eddc`](https://github.com/mateo-m/empo-app/commit/bb1eddcecb1ad64d3ba5e527bfdfe154393df57f))
- Scope submodule url rewrite per-command for self-hosted safety ([`08a08c1`](https://github.com/mateo-m/empo-app/commit/08a08c11897039fef61324fb43eac4cae3870864))
- Normalize autotools mtimes instead of shimming automake versions ([`136cf87`](https://github.com/mateo-m/empo-app/commit/136cf8724923f03e382e006379d67ef9b35cdd9b))
- Never run automake refresh rules in the sdl2_ttf build ([`35cea66`](https://github.com/mateo-m/empo-app/commit/35cea66765f9e6e12b43de3b4cc4018def9a73b2))
- Preserve hand-added overlay keys on settings writes ([`c7356a2`](https://github.com/mateo-m/empo-app/commit/c7356a2f38f2853ef17a736d6467fec33b9988e5))
- Normalize removed TRUE constant in old-ruby mkconfig for modern host rubies ([`3b4105c`](https://github.com/mateo-m/empo-app/commit/3b4105cdb9cda330a1673bde9fecc7a1de39ed75))
- API-signed PR flow for bot commits and pin CI-built native-2026-07-20-r3 ([`c42d2c5`](https://github.com/mateo-m/empo-app/commit/c42d2c5548d3dc81a2bcc446e90d27296c037f12))
- Gate defScreen null patches on the base defining them ([`5aacd06`](https://github.com/mateo-m/empo-app/commit/5aacd0663464a02d5f40248e0aff3b10a5d4bb8c))
- Pin system ruby as host ruby for ruby18/19 trees ([`a740447`](https://github.com/mateo-m/empo-app/commit/a740447e5c7f1717a3d14ecab15e9f0462c5a4e9))
- Point-space translation geometry with no-overlap guarantee ([`436125f`](https://github.com/mateo-m/empo-app/commit/436125f5f626e4673aa518be9fd866646e12c15f))
- Re-translate on game rect change, d-pad obstacle, portrait band ([`4336a4b`](https://github.com/mateo-m/empo-app/commit/4336a4bdaea9b443d966a2959fb8f8db32e07d4d))

### CI

- Add simulator build gate for PRs and main ([`a80a6b2`](https://github.com/mateo-m/empo-app/commit/a80a6b2237b90c40e172c527d2c8ef27aa06919d))
- Build, audit, publish, and re-pin releases from CI ([`d0b7e28`](https://github.com/mateo-m/empo-app/commit/d0b7e283708daf217f8b81ae3c881c71b0f84350))
- Add on-demand native deps publish workflow ([`dd44e66`](https://github.com/mateo-m/empo-app/commit/dd44e667c8e89027ebd41a267fe7e51866de6485))
- Clone submodules over https on runners ([`46a6387`](https://github.com/mateo-m/empo-app/commit/46a6387d1410c52fbc699b78b3341ec70d29b724))
- Create empty Signing.xcconfig before xcodegen ([`9ca5be8`](https://github.com/mateo-m/empo-app/commit/9ca5be835c881a8cecec6480e99fa0908155e952))
- Allow manual dispatch of lint and format workflows ([`5310d9c`](https://github.com/mateo-m/empo-app/commit/5310d9c34b0aadfe51c4a26cd20c506d35906544))
- Create pin and release-sync PRs with EMPO_APP_BOT_TOKEN when present ([`b824af1`](https://github.com/mateo-m/empo-app/commit/b824af1ded7d7ac421179d0438eade5ea3b2c221))
- Dispatch required checks on bot-created PR branches via actions PAT ([`0d92a4f`](https://github.com/mateo-m/empo-app/commit/0d92a4f9c864b12c8b7807a177ed93a2a93091ea))
- Dispatch required checks on bot-created PR branches ([`9d999af`](https://github.com/mateo-m/empo-app/commit/9d999af63d126a58aa5132f28a665d2facdf7b1a))
- Add Lint/Format summary jobs matching required check contexts ([`518454c`](https://github.com/mateo-m/empo-app/commit/518454c7e13df229f472f7c0ab98183efe48adb2))

### Chores

- Pin published engine-2026-07-20 core prebuilt ([`ee382ed`](https://github.com/mateo-m/empo-app/commit/ee382ed8d8ad1ea51ff7ba4f15fea0e52cdab6a1))
- Exclude engine prebuilt fetch stamp ([`a407205`](https://github.com/mateo-m/empo-app/commit/a4072054a35943c8865f3740899948f2d6215767))
- Bump submodule for ccache-aware core recipe ([`39f7d6f`](https://github.com/mateo-m/empo-app/commit/39f7d6fccca74e556129f6fa49bd0b0af0bbd3df))
- Pin native-2026-07-20-r2 with rebuilt merged objects ([`9c8314d`](https://github.com/mateo-m/empo-app/commit/9c8314d425d800c717934be99cea52fa7142c59e))
- Pin engine-2026-07-21 with config overlay bridge ([`02546a1`](https://github.com/mateo-m/empo-app/commit/02546a118db3536cc1b903f87a1a45c20e095eb1))
- Pin native-2026-07-20-r4 native prebuilts (#86) ([`44c7b59`](https://github.com/mateo-m/empo-app/commit/44c7b598b22910e84b103c24907371b8a8f61a0c))
- Pin native-2026-07-21 native prebuilts (#88) ([`0e969c4`](https://github.com/mateo-m/empo-app/commit/0e969c439efa4eb7cf17142e94a5a633432d5620))
- Commit schema generator cap change (16 to 21) ([`9908c96`](https://github.com/mateo-m/empo-app/commit/9908c96fb6d0612a8dd49b31f27f26b790c149fe))
- Pin engine-2026-07-22 with casefold file checks and audio logging ([`74c6952`](https://github.com/mateo-m/empo-app/commit/74c695246af0cda92af65a3bb286b12e4c6ae8d4))
- Pin native-2026-07-22 with rebuilt casefold binding objects ([`72179bf`](https://github.com/mateo-m/empo-app/commit/72179bf8d073e1007c1860e1919e191957a19084))
- Pin native-2026-07-22-r2 with UTF-8 script-string binding objects ([`85fda50`](https://github.com/mateo-m/empo-app/commit/85fda507764e607b1c70b7e4e3e0559e106bf273))
- Bump submodule with Graphics.delta seconds shim for Essentials v21 ([`434eda1`](https://github.com/mateo-m/empo-app/commit/434eda1a94112b5aa2c677c2acca53b883951c19))
- Pin native-2026-07-22-r3 with Graphics.delta compat postload binding objects ([`7c43e05`](https://github.com/mateo-m/empo-app/commit/7c43e0580336de16f6c24e1a066f45e836b9e10d))

### Features

- Route dispatch workflows to the self-hosted Mac runner on request ([`c437511`](https://github.com/mateo-m/empo-app/commit/c4375112d624557e360f31bd0a4c540c935a8bdd))
- Persist player controls as shareable EmpoState/controls.json manifest ([`f2e24f0`](https://github.com/mateo-m/empo-app/commit/f2e24f092b358b32d9a627abc21dbbb3c6d4ab64))
- Make game settings an accessor over EmpoState/mkxp.json ([`b94773b`](https://github.com/mateo-m/empo-app/commit/b94773b993ecfd41db4780d665872525871579e2))
- Sparse mkxp overlay with composed engine config ([`b67986f`](https://github.com/mateo-m/empo-app/commit/b67986f55edd17e847bff36cd958fdce90be8836))
- In-memory mkxp config overlay bridge ([`104155c`](https://github.com/mateo-m/empo-app/commit/104155c7f8e6d803bee762ccd20e0b3d49b39229))
- Translate Kirin kirin-touch-controls.json touch layouts ([`5006847`](https://github.com/mateo-m/empo-app/commit/5006847951051801ed158b4fcc51b03fa502be9f))
- Translate JoiPlay gamepad.json layouts at load time ([`e150b99`](https://github.com/mateo-m/empo-app/commit/e150b99034fb029fdc86c00700a44c72ae739c0e))
- Touch screen mouse emulation with per-game toggle ([`6995cc4`](https://github.com/mateo-m/empo-app/commit/6995cc43ffc77a60ed5fc64547d0ad71f507a69b))
- Kirin dpad in left grid with orientation-invariant arrangement ([`91a726c`](https://github.com/mateo-m/empo-app/commit/91a726c1843a3f7511f622d50197a21c50180cb0))
- Derive missing orientation from single-orientation layouts ([`10ca9ad`](https://github.com/mateo-m/empo-app/commit/10ca9ad1bb750a8d3b203fe59a8049dcc60f7783))
- Derive missing orientation from single-orientation layouts ([`106efc0`](https://github.com/mateo-m/empo-app/commit/106efc02fe85f38a1e24b68da3bd83bfc2e4bfd3))

### Performance

- Build deps trees on parallel runners and hydrate ANGLE first ([`05b3ab0`](https://github.com/mateo-m/empo-app/commit/05b3ab0f02340ffb5ead1308054e035106c2941e))

### Refactor

- Link engine core as prebuilt libmkxpz-core.a from the submodule recipe ([`3b5d246`](https://github.com/mateo-m/empo-app/commit/3b5d246c79b6f0a0ef5e5c08e478dc0956532986))

### Release

- Tag pinned engine commit empo-v<version> per release ([`49f8afc`](https://github.com/mateo-m/empo-app/commit/49f8afc088b4407e36c2a5c6c38a416b090136d3))

## 0.3.0 - 2026-07-20

### Bug Fixes

- Reject JSON booleans in controls manifest numeric fields ([`aee5159`](https://github.com/mateo-m/empo-app/commit/aee515913dc864a896c14687064719d75bc40922))
- Animate reset to resolved touch layout ([`e13bb8d`](https://github.com/mateo-m/empo-app/commit/e13bb8d40c62544066d278f32643905091c7fada))
- Refcount held scancodes so shared-key elements release correctly ([`360585b`](https://github.com/mateo-m/empo-app/commit/360585b34a6ec3806553d7de3ba9c6519b59882c))
- Remap picker group fixes and release held keys on listen-mode suppression ([`52ad07b`](https://github.com/mateo-m/empo-app/commit/52ad07be16ac8662165101faaafee15363e6c752))
- Invalidate pending stagger-add tasks when undo replaces the layout ([`34ce11b`](https://github.com/mateo-m/empo-app/commit/34ce11b13a1e0696f0183a96c2288c739124ea07))
- Make JSON boolean detection portable to Linux ([`9253120`](https://github.com/mateo-m/empo-app/commit/9253120504cc63e369eac065de854392dee910c6))
- Detect JSON booleans via objCType for cross-platform correctness ([`0ae909b`](https://github.com/mateo-m/empo-app/commit/0ae909b991e1576033d82d0eea98a9aeb82c61b3))
- Match engine JSON5 tolerance when projecting mkxp.json ([`79dd0bb`](https://github.com/mateo-m/empo-app/commit/79dd0bbece67fba9d6b674d8e2a1782ffb75a22c))

### Chores

- Bump mkxp-z-apple-mobile for upstream patches key rollback ([`35f0396`](https://github.com/mateo-m/empo-app/commit/35f0396792191ca35be48d085a81793fc8e6c673))
- Pin native-2026-07-20 ([`77e1eac`](https://github.com/mateo-m/empo-app/commit/77e1eac8bf07a09b5e6029c5b9a1b14ab85b6710))

### Documentation

- Publish JSON Schema and example manifest ([`bfbbbd3`](https://github.com/mateo-m/empo-app/commit/bfbbbd38073c6fb0854dd87e2460aaaa7fa96fc3))
- Developer guide for the controls manifest format ([`6026e5d`](https://github.com/mateo-m/empo-app/commit/6026e5d26fda02f4f166a13c394165e1c683b02e))
- Action-first restructure of the controls guide ([`5b3df9c`](https://github.com/mateo-m/empo-app/commit/5b3df9c858af782d0ca8e9f0385ea343f681599f))
- State the 128 KiB cap as validator rule V001 ([`1998144`](https://github.com/mateo-m/empo-app/commit/199814412d454adb43251afe2332f09cb44dbeb7))
- Drop unexplained error-code jargon from the file-format section ([`6149d31`](https://github.com/mateo-m/empo-app/commit/6149d31181f147528858891a6297e512cb6272b3))
- Root controls.json as the standard manifest location ([`cc83eb5`](https://github.com/mateo-m/empo-app/commit/cc83eb5472a7bb324bff20e09fda3354b84f0c39))

### Features

- Add controls manifest parser and key table ([`2e4e50a`](https://github.com/mateo-m/empo-app/commit/2e4e50af43532aa59d5e51089600f9c95fc8a41b))
- Wire dev touch layouts from controls.json ([`17b58fa`](https://github.com/mateo-m/empo-app/commit/17b58fa8c2942776187bd68c58026b52c80be6b3))
- Host-side controller input layer with builtin keyboard map ([`9da8296`](https://github.com/mateo-m/empo-app/commit/9da8296eb86a48c9aef1fb0df77100fd7e26a88b))
- Four-layer controller map resolution and user overrides ([`a54302d`](https://github.com/mateo-m/empo-app/commit/a54302d6927319171e3aeb1d9ebed3f4dcf22e7b))
- Controller remap UI with per-game and global scopes ([`ac775cb`](https://github.com/mateo-m/empo-app/commit/ac775cb0ba74c7d43cdddad9e1f88fb8945b582e))
- Undo layout edits in controls edit mode ([`d1d3973`](https://github.com/mateo-m/empo-app/commit/d1d39733c59580597a910223c3d8f141a29a0dbf))
- Accept root-level controls.json as second manifest location ([`01f9bfe`](https://github.com/mateo-m/empo-app/commit/01f9bfe4c046e3b98a637e5c1c2579b12384fbab))

### Refactor

- Drop the purposeless name field from the manifest format ([`2ec5fe0`](https://github.com/mateo-m/empo-app/commit/2ec5fe01b2420c75d7b1f95c88db81523f2f4852))

## 0.2.13 - 2026-07-19

### Bug Fixes

- Keyboard no longer resizes the embedded game view ([`8fe929f`](https://github.com/mateo-m/empo-app/commit/8fe929f33e2996c897d018b9a60426b3d1decf3f))
- Inset and center keyboard accessory rows within the horizontal safe area ([`075367c`](https://github.com/mateo-m/empo-app/commit/075367c83d52de72378da963df3e87b88105ab47))

### Chores

- Pin native-2026-07-18 ([`b6c9e1e`](https://github.com/mateo-m/empo-app/commit/b6c9e1e8becb2c270005e8eb38505b205b26926e))
- Pin native-2026-07-18-r2 ([`975ec13`](https://github.com/mateo-m/empo-app/commit/975ec130ce7a8748e91b73f344f41a99257d871e))
- Bump mkxp-z-apple-mobile (rubocop cache ignore) ([`def3661`](https://github.com/mateo-m/empo-app/commit/def3661c900ff46cfc6a8be86cb875ec2e9a3eff))
- Bump mkxp-z-apple-mobile (stale path-cache fallback for runtime-written files) ([`55f8484`](https://github.com/mateo-m/empo-app/commit/55f84847becb0f9aa697fa5a495d038196e0b902))
- Bump mkxp-z-apple-mobile (apply_overrides UTF-8 encoding fix) ([`7d8029c`](https://github.com/mateo-m/empo-app/commit/7d8029c6207426779d9290243f5bebaf48de5802))
- Pin native-2026-07-19 ([`fbae312`](https://github.com/mateo-m/empo-app/commit/fbae31262a1b175c8051563cf7dc52a9574c5893))

### Features

- Socket exts for all three Rubies + bundled pure-Ruby stdlib trees ([`a341e8f`](https://github.com/mateo-m/empo-app/commit/a341e8f054547f7ac03bb1921ad8f138faff02cf))
- Per-game network access toggle, CA bundle wiring, Ruby stdlib bundling ([`c633997`](https://github.com/mateo-m/empo-app/commit/c633997352b54d5d52cc5700d8fa4c731ca8309e))
- Upgrade OpenSSL 1.1.1w -> 3.5.7 LTS ([`8325d49`](https://github.com/mateo-m/empo-app/commit/8325d4977e354ff362797dc8a4193dfe1758695f))
- Silent weekly CA bundle auto-refresh + airplane-mode toggle copy ([`f5f18d3`](https://github.com/mateo-m/empo-app/commit/f5f18d32deedaf02e45ccef15e20ecf7097ca6f7))
- Quick first-pass scan so the splash lifts on a settled library ([`34acf7b`](https://github.com/mateo-m/empo-app/commit/34acf7b773a03d5e703077670e1be6921fad298b))

### Release

- Link AltStore and Sideloadly in notes ([`abb097f`](https://github.com/mateo-m/empo-app/commit/abb097f8ed7dc3ea341f4ecd5a67df02d1ed61fc))

## 0.2.12 - 2026-07-17

### Bug Fixes

- Migrate misjoined UserData saves and pin slash fix ([`4604767`](https://github.com/mateo-m/empo-app/commit/4604767f507275eb3c4aefe584bb331461152374))

### Chores

- Pin native-2026-07-17 with data_directory slash fix ([`c8af7a8`](https://github.com/mateo-m/empo-app/commit/c8af7a88d42842ea92c5b0358aa1706738706372))

## 0.2.11 - 2026-07-16

### Chores

- Pin native-2026-07-16-r3 with JoiPlay-compat toggle engine ([`afa2a67`](https://github.com/mateo-m/empo-app/commit/afa2a67e461d1792ced8d59c09201837130dc061))

### Features

- Per-game JoiPlay compatibility toggle in Game Settings, default off ([`7691ebf`](https://github.com/mateo-m/empo-app/commit/7691ebf9bcf3faca0de2898f58394df1dc2374de))

## 0.2.10 - 2026-07-16

### Bug Fixes

- Cover Dir.each_child in save-path remap ([`c45ad1a`](https://github.com/mateo-m/empo-app/commit/c45ad1a54cc7df52ebe6c75a6ca38f62f40ecd80))
- Survive game-requested exit instead of aborting on shutdown ([`a637bc4`](https://github.com/mateo-m/empo-app/commit/a637bc446cc919dd8afb29e195d42b65a3cbc194))

### Chores

- Pin native-2026-07-16 and require binding fingerprint stamp ([`c146710`](https://github.com/mateo-m/empo-app/commit/c1467103f0033902f1ab5270cf2b70912c612316))
- Pin native-2026-07-16-r2 with clean-exit engine fixes ([`99f6c38`](https://github.com/mateo-m/empo-app/commit/99f6c38dff85b4134931b981306641745630bc4a))

### Features

- Identify as "empo" to game scripts via launcher identity ([`534d83e`](https://github.com/mateo-m/empo-app/commit/534d83e5102c31ba109d90a1e6d6b0d80853eb6c))
- Stamp engine binding fingerprint in debug log header ([`e7bb580`](https://github.com/mateo-m/empo-app/commit/e7bb580d06c994b2c3995d3130ac3877a2f12f63))
- Import self-extracting .exe installers via vendored libmspack ([`ba6d766`](https://github.com/mateo-m/empo-app/commit/ba6d766ab98f2c8e1dbcff2da59f0aa721918b74))

## 0.2.9 - 2026-07-08

### Bug Fixes

- Allow continuing past RTP launch warning ([`5c941a4`](https://github.com/mateo-m/empo-app/commit/5c941a45dd2a1f15f2bfa5f46b1be0633236517e))

## 0.2.8 - 2026-07-08

### Bug Fixes

- Embed SDL view and restore play controls ([`7303900`](https://github.com/mateo-m/empo-app/commit/7303900642903f01b5793575e599c9a47ab5df89))

## 0.2.7 - 2026-07-08

### Bug Fixes

- Avoid SIGPIPE in audit-ipa GitInfo grep ([`c92c9c5`](https://github.com/mateo-m/empo-app/commit/c92c9c55fe80bd0b5d3ac967b1acfba5d7535c90))
- Adopt UIScene lifecycle for iOS 27 SDK ([`41d93fd`](https://github.com/mateo-m/empo-app/commit/41d93fdf577049877e22a0dd5bcc0734489011e6))
- Restore game rendering and Insurgence cheats after UIScene migration ([`964a9d3`](https://github.com/mateo-m/empo-app/commit/964a9d3ad06d5c1bee7b2be205b31df71ed02229))
- Apply SDL iOS fixes via build-time patches ([`d50670b`](https://github.com/mateo-m/empo-app/commit/d50670bfdd7171892fcc93ecb266dfc1b79997b9))
- Info-alert UX for game msgbox and guard stale mkxp merges ([`5aeacc9`](https://github.com/mateo-m/empo-app/commit/5aeacc96c6cb91e1c7085bbe60ad86c0cef73649))
- Block RTP-dependent games and fix spaced Game.ini keys ([`da4b493`](https://github.com/mateo-m/empo-app/commit/da4b493a698d7f618efe5dd289b800bc9f3e86f5))
- Block RTP-dependent games and fix spaced Game.ini keys ([`d877c75`](https://github.com/mateo-m/empo-app/commit/d877c7517cc3eb369d3493a0b0c560c594694e16))

### Chores

- Run mkxp-z rubocop in pre-push (#75) ([`8c224fa`](https://github.com/mateo-m/empo-app/commit/8c224fa3755f37fcc66dbf90746b9e8b7c5cf529))
- Gitignore Empo derived data directory ([`c57a9ae`](https://github.com/mateo-m/empo-app/commit/c57a9ae269b481cf2fea90ae8190d784d6224f7c))
- Bump mkxp-z submodule ([`aca579e`](https://github.com/mateo-m/empo-app/commit/aca579e2ff1048a0a3ba81f60c9da6e35a5381b2))
- Bump mkxp-z submodule ([`8dcae40`](https://github.com/mateo-m/empo-app/commit/8dcae406a2369df130007ff9d85dae522d45c0bc))
- Bump mkxp-z submodule ([`d82f2f5`](https://github.com/mateo-m/empo-app/commit/d82f2f530c1bf2f762a004f5d943e5f0f809ec4e))
- Bump mkxp-z submodule ([`99379f8`](https://github.com/mateo-m/empo-app/commit/99379f8809d5d4ba851611c7c77f0c1c50064c80))
- Publish shared git hooks and align submodule setup ([`8555a0f`](https://github.com/mateo-m/empo-app/commit/8555a0f8e4de5f7c7e3fe87e5d8b7ad749d2a037))
- Keep commit-message and co-author policy local-only ([`b408925`](https://github.com/mateo-m/empo-app/commit/b408925b1e4ef2a89ca18c08207bbcb1c99712ba))
- Drop local override mention from gitignore ([`4b62bd3`](https://github.com/mateo-m/empo-app/commit/4b62bd3a54442a49abd8b71993d9ef9b67891f01))

### Performance

- Overhaul game import pipeline for speed and correctness ([`2672bd6`](https://github.com/mateo-m/empo-app/commit/2672bd6fcc2f178d167962f9aaefd334cfc75495))

### Refactor

- Wire GameProbe package into Host (#76) ([`02fc08e`](https://github.com/mateo-m/empo-app/commit/02fc08e211950a3994ee45f3f10495084a49fcad))
- Extract EngineSessionCoordinator from AppState (#83) ([`86f3cda`](https://github.com/mateo-m/empo-app/commit/86f3cda0b9dd5959485367b1c9dd3c3f1fae7f44))
- Merge import orchestration into ImportPipeline (#78) ([`21b88ba`](https://github.com/mateo-m/empo-app/commit/21b88ba4935cc343c600658c70658367ebbd8c6f))
- Finish library, config projector, and input routing stack (#85) ([`eb538bc`](https://github.com/mateo-m/empo-app/commit/eb538bc952c0b8b7dd1cc73d5c3fede9ad04650f))

## 0.2.6 - 2026-06-22

### Bug Fixes

- Point 0.2.2–0.2.4 downloads at reissued release tags ([`b84e79c`](https://github.com/mateo-m/empo-app/commit/b84e79c367d2e577ee73072dd6065a6035b18c48))
- Fix `totalPlayTime` and `lastPlayed` values not being modified ([`1598bd5`](https://github.com/mateo-m/empo-app/commit/1598bd5af0a26f19a9f90455994c3284f95bb140))
- Fix Bun types ([`dd9c264`](https://github.com/mateo-m/empo-app/commit/dd9c264476daaf026d35521c735055334b6b565f))
- Fix type errors ([`de61b34`](https://github.com/mateo-m/empo-app/commit/de61b34694efd7c0ce46950e590db4a450663c25))
- Repair has_platform under pipefail ([`dde2777`](https://github.com/mateo-m/empo-app/commit/dde2777846dbbcd189d2eaa5eb69dbc67d78159c))
- Collapse relative paths in normalize on ios ([`1b9f918`](https://github.com/mateo-m/empo-app/commit/1b9f918ec95af2cae2a30fbb809d81d0f27773f9))
- Ignore desktop.ini in RPG Maker import preflight ([`f2e6cde`](https://github.com/mateo-m/empo-app/commit/f2e6cde87d7c8346c6d004463059b919aa853493))
- Unblock engine error dialog and guard Foundation paths ([`52982ff`](https://github.com/mateo-m/empo-app/commit/52982ff669e74563690a13fdf96207f85b1ec2d3))
- Restore Ruby 1.8 prelude in native dep builds ([`7486578`](https://github.com/mateo-m/empo-app/commit/74865780b752e00dff851df87c3181480c16a7b9))

### Chores

- Update Discord invite link ([`ac1115d`](https://github.com/mateo-m/empo-app/commit/ac1115df22676eb43bfcb36da5d6e07f11aaec76))
- Cleanup releases ([`975f92a`](https://github.com/mateo-m/empo-app/commit/975f92a0762e2bdde659368cf02e30f8cdfe3ebd))
- Cleanup unused lockfile ([`eac0190`](https://github.com/mateo-m/empo-app/commit/eac0190605d4e553af3e4bef9ac5d894274b9526))
- Pin native deps to native-2026-06-22 ([`d9fede8`](https://github.com/mateo-m/empo-app/commit/d9fede881c4057e5407f6918fd502dbbedda36cf))

### Refactor

- Architecture overhaul (#74) ([`7812669`](https://github.com/mateo-m/empo-app/commit/7812669467e133e116e1f529aaedf9eef2854f5e))

## 0.2.5 - 2026-06-09

### Bug Fixes

- Register GitInfo in xcodegen and update mkxp for Ruby 1.8 boot ([`cac317b`](https://github.com/mateo-m/empo-app/commit/cac317b609083774b527988ead1c83a6f1dec52e))

## 0.2.4 - 2026-06-09

### Bug Fixes

- Harden device deps pipeline and error alert handling ([`40d1a4c`](https://github.com/mateo-m/empo-app/commit/40d1a4c1299f51d807481520364e0e34dc728229))
- Patch Ruby 1.8 cross-compile fake template ([`ab208a3`](https://github.com/mateo-m/empo-app/commit/ab208a38f24cdfb33917696e75675282a3ba8814))
- Fix Ruby 1.8 cross-compile on modern macOS hosts ([`c6f7bbc`](https://github.com/mateo-m/empo-app/commit/c6f7bbc8e24a1d04e741c7ebda3f70820e6cb3ab))
- Point Ruby 3.1 openssl ext at device OpenSSL ([`54b0fca`](https://github.com/mateo-m/empo-app/commit/54b0fcae3dab078e9b420abf11f1d1d6d8374c9b))

## 0.2.3 - 2026-06-08

### Bug Fixes

- Cache compatibility auto-detect and re-sniff on reset ([`0bcb3f5`](https://github.com/mateo-m/empo-app/commit/0bcb3f56bc8075611c37796cf91e5d95e3b02e27))
- Clean up failed imports and improve import UX ([`90e8622`](https://github.com/mateo-m/empo-app/commit/90e8622d2d90885e64b8007ee35312b7d191b12e))
- Improve update banner dismiss and interactions ([`c2fa359`](https://github.com/mateo-m/empo-app/commit/c2fa359d5c3df7017bbab2934bf298cde8ac7244))

## 0.2.2 - 2026-06-08

### Bug Fixes

- Update mkxp for exact-path bitmap resolution ([`f987a76`](https://github.com/mateo-m/empo-app/commit/f987a7678802c189d6e90caa70a3a1c922329043))

### Features

- Check at launch and add manual refresh control ([`37f70ee`](https://github.com/mateo-m/empo-app/commit/37f70eed3537bafa8aca4caeaaadeb8c44dfba18))

### Release

- Sync altstore source in release script ([`0ebe322`](https://github.com/mateo-m/empo-app/commit/0ebe3222261b02e84a09b1a5d5d44b49e2665ab2))

## 0.2.1 - 2026-06-06

### Bug Fixes

- Update mkxp for Flux battle start ([`bc83a42`](https://github.com/mateo-m/empo-app/commit/bc83a425563b1f5005e7349e1c1cbb9670bfd1dc))
- Migrate user data and refresh ruby auto-detect ([`abcc86e`](https://github.com/mateo-m/empo-app/commit/abcc86e7301a2e7d3085acafc1a71d9c9ab6dbda))

### Release

- Stop staging generated xcodeproj ([`8f692da`](https://github.com/mateo-m/empo-app/commit/8f692dae1f0ccb76cacdf0993320efbebb19e13e))
- Source release notes from changelog ([`721f222`](https://github.com/mateo-m/empo-app/commit/721f222ec47d00588b80ee75f4a9f6068b9db28f))
- Build ipa from clean release commit ([`57c17bb`](https://github.com/mateo-m/empo-app/commit/57c17bb816dadc6edd7e9152b0d1e3235a3805ff))

## 0.2.0 - 2026-06-05

### Bug Fixes

- Handle pokemon unicode assets and optional web probes ([`16e1679`](https://github.com/mateo-m/empo-app/commit/16e1679a079c2c89a9575efab9f18035c232776e))
- Preserve utf-8 script encodings for pokemon ([`34d3669`](https://github.com/mateo-m/empo-app/commit/34d36698e6f75e10f29af13b9fb262d1594b149a))
- Avoid Ruby 3 false-positives on legacy RGSS scripts ([`30acf38`](https://github.com/mateo-m/empo-app/commit/30acf383a52d91a4d645769d841a6f36693de676))
- Update mkxp for case-insensitive asset existence checks ([`2ff9cde`](https://github.com/mateo-m/empo-app/commit/2ff9cdee72c94bde5f519304056b6a8ef7b3eb00))
- Make Ruby file access case-insensitive on iOS ([`c0384f5`](https://github.com/mateo-m/empo-app/commit/c0384f500c275230ce335a74ceaa47a87c1640eb))
- Move casefold filesystem fallback into native bindings ([`a496d00`](https://github.com/mateo-m/empo-app/commit/a496d00c86049b8ecf929012515aef6d2ce0cfcd))
- Force archive choice paths to use monospaced text ([`2203675`](https://github.com/mateo-m/empo-app/commit/22036759e8cfab33a303df216072b326866bc02e))
- Update mkxp for pokemon runtime compatibility ([`8f17270`](https://github.com/mateo-m/empo-app/commit/8f17270dee7b80d0a37658195be1cc167aec16e5))
- Update mkxp after default-branch integration ([`4152d36`](https://github.com/mateo-m/empo-app/commit/4152d368567844e07fc70f97863a76e8da38f952))
- Repoint mkxp after branch split ([`9a8df9b`](https://github.com/mateo-m/empo-app/commit/9a8df9bd78d25e3fbb9932c8f24eb4d43494ff30))

### CI

- Opt into node 24 for js actions to silence node 20 deprecation ([`afcfba1`](https://github.com/mateo-m/empo-app/commit/afcfba167f9381067b1058abe887c38f76b7d2b9))
- Sync AltStore source from GitHub releases ([`45e9dca`](https://github.com/mateo-m/empo-app/commit/45e9dcacb480948ecc056f9396e47f69e73a7d12))
- Notify Discord on published releases ([`ff68206`](https://github.com/mateo-m/empo-app/commit/ff68206adf53204cfbe9234688e0e6304d0d308b))

### Chores

- Add discord invite link ([`5243fb2`](https://github.com/mateo-m/empo-app/commit/5243fb224a9d1790ee16d489b693292418951dc9))
- Update git ignore ([`dc3b2d2`](https://github.com/mateo-m/empo-app/commit/dc3b2d2d8ca71d3140b19438a70b6c123a586e54))
- Ignore root object files ([`fd9d312`](https://github.com/mateo-m/empo-app/commit/fd9d312a60a6f7e351c613df4d92de27af82123e))
- Adopt lefthook guardrails ([`3e3bd11`](https://github.com/mateo-m/empo-app/commit/3e3bd11b80167d41c5341c174fd90b4a3f0f5920))

### Documentation

- Document Graphics.delta timing for Vanguard ([`a310a2f`](https://github.com/mateo-m/empo-app/commit/a310a2fb637bbc0074ae149d69fdf63ac0337773))
- Add branch protection guidance ([`d156ca7`](https://github.com/mateo-m/empo-app/commit/d156ca7a44cb21840e925ffc54cda7ad96453351))
- Drop branch protection guidance ([`122c477`](https://github.com/mateo-m/empo-app/commit/122c47739d973746e855b68c08c864d441166174))

### Features

- Add pre-commit lint + format gated by file type ([`9c7efa5`](https://github.com/mateo-m/empo-app/commit/9c7efa5d3b91357b7f657114f7b3dcc6f759a5fd))
- Move archive workflow into controller ([`11a7349`](https://github.com/mateo-m/empo-app/commit/11a7349f4c68721156c153905f80c745baaa140c))
- Share update status banner across settings and library ([`f3775b3`](https://github.com/mateo-m/empo-app/commit/f3775b36e0365d76d331b4ceb5f7a7f8f50edf1a))

### Release

- Auto-update altstore-source.json with new ipa size + version ([`c95955c`](https://github.com/mateo-m/empo-app/commit/c95955c4726d14ea8bfa98f2a3b80f4173dbaa10))
- Accept major/minor/patch bump arg, derive version from latest tag ([`6046214`](https://github.com/mateo-m/empo-app/commit/604621446cfb092be806e3ecc91d1cf3e2e26543))
- Track changelog and generate release notes ([`85f3347`](https://github.com/mateo-m/empo-app/commit/85f334739966a69a3595b1609fe367bd375e59d4))

### UI

- Fix swift-format + markdownlint violations to unblock ci ([`5ab1b3d`](https://github.com/mateo-m/empo-app/commit/5ab1b3d9cc0e541231d30c8800af35df46c78c36))
- Fix yamllint warnings via inline rule disables + folded warning_cflags ([`11f542b`](https://github.com/mateo-m/empo-app/commit/11f542b522b12d31290407fa59374d4936b5b97d))

## 0.1.0 - 2026-05-07

### Bug Fixes

- Improve ruby18 cross-compilation and guard bridge queries ([`3df8bf5`](https://github.com/mateo-m/empo-app/commit/3df8bf5a474b91e361a908ca406bcf9ff6f0b817))
- Add input fix/patch for Pokemon Essentials games, patch Dir.chdir, handle post-load scripts ([`cd52c27`](https://github.com/mateo-m/empo-app/commit/cd52c27d27a7a505eb6d0cb734c31d936c67e048))
- Multi-session game compatibility for persistent ruby vm on ios ([`f580f56`](https://github.com/mateo-m/empo-app/commit/f580f56f5bc63164ac9158747f93882765fa5cd7))
- Use float cast for backingScaleFactor to avoid integer truncation ([`f17bb05`](https://github.com/mateo-m/empo-app/commit/f17bb05be92d8351d338c7dfb54728d32860c9a0))
- Correct gitignore entry for generated git info file ([`0731a86`](https://github.com/mateo-m/empo-app/commit/0731a86d33c9109cc767d83724c9a02f7b04e874))
- Prune old debug log files on launch, keep last 20 ([`8e20f5e`](https://github.com/mateo-m/empo-app/commit/8e20f5efe876b160671324a876daefbfc6433ef6))
- Hero zoom animation in list view mode ([`48fc78d`](https://github.com/mateo-m/empo-app/commit/48fc78d5e51b0fd07f8b1cc966a7dc6d04a4389e))
- IOS graphics init, resize guards, and error routing through bridge ([`48da960`](https://github.com/mateo-m/empo-app/commit/48da9601abbd5cb1ab5efd2584e84f6c50c8003e))
- Rotation crash caused by concurrent GL context access during renderbuffer resize ([`3d4f1f4`](https://github.com/mateo-m/empo-app/commit/3d4f1f4653dee6475da23f8d7edb64683bdad722))
- Grayscale animation in list view and show original title on game cards ([`1f04a47`](https://github.com/mateo-m/empo-app/commit/1f04a47c4e759e1c711a3c221eaf1fe5e262c284))
- Library header gap bug, code audit fixes, and swiftui-pro skill ([`2b09bee`](https://github.com/mateo-m/empo-app/commit/2b09beedef994aeaaa4aa5d72a4b9d47d6aecedf))
- Thread safety and code quality issues in C++ bridge layer ([`500d4fb`](https://github.com/mateo-m/empo-app/commit/500d4fbd90c92393f9ac25813ca5780afd04b7d2))
- Synchronous present to prevent SIGSEGV during rapid device rotation ([`b27cecc`](https://github.com/mateo-m/empo-app/commit/b27cecc3b636ae0736277d85141de6d154ad6fa3))
- Neutralize tint bleed on alerts and make Delete the preferred action ([`1033a1c`](https://github.com/mateo-m/empo-app/commit/1033a1cb041a1873016f47b3a490727b15ac4601))
- Allow cancel/delete button on importing games in list view ([`ea1543c`](https://github.com/mateo-m/empo-app/commit/ea1543c0d9c45b1d03a1281dc015af575768fbfa))
- Neutralize tint bleed on quit alert and make Quit the preferred action ([`446392b`](https://github.com/mateo-m/empo-app/commit/446392bc550d24138eae87efbf24ed9a5c932c0b))
- Remove synthetic loading delay, scale exit animation by elapsed time ([`008031d`](https://github.com/mateo-m/empo-app/commit/008031dcc7caa47826eb3d1d93c6a8e035e60c2c))
- Replace deprecated APIs, remove dead code, deduplicate shared logic ([`6f058a0`](https://github.com/mateo-m/empo-app/commit/6f058a09e39d8d03f6926f73c1676ab5b3c37e18))
- Use window safe area for controls, smart reset animations ([`b15b3f7`](https://github.com/mateo-m/empo-app/commit/b15b3f79abcbe8228da3d8ba76b52b8825694f36))
- Darken edit zone background for better control visibility ([`902f351`](https://github.com/mateo-m/empo-app/commit/902f35156daf2923932d529e628c90b4c6447e8b))
- Make reset button prominent in reset controls alert ([`2b69c71`](https://github.com/mateo-m/empo-app/commit/2b69c7113002e00b386c42ff116208e21c249023))
- Record play time before clearing selectedGame, add hero card to list view ([`2a84f3d`](https://github.com/mateo-m/empo-app/commit/2a84f3df1eb4ddcae2ec530ab8b7f1b1c5c3a662))
- Clamp debug overlay to safe area on drag and rotation ([`fabed03`](https://github.com/mateo-m/empo-app/commit/fabed032470c05994c9db39fa115e62abd7e1e7a))
- Stub win32 dll loaders and ruby 1.8 encoding gaps for rgss compat ([`512e275`](https://github.com/mateo-m/empo-app/commit/512e27585fb7942634fe6dcbaee473562cea9f38))
- Harden rmxp compat and hang recovery across games ([`5ae0bf3`](https://github.com/mateo-m/empo-app/commit/5ae0bf3f2688652306ebfd7b4c70e24343ddbeca))
- Audit cleanup - crash fixes, hot path log skip, stub corrections ([`1fa7442`](https://github.com/mateo-m/empo-app/commit/1fa7442345ec006707c6459e52b92ce4d490a32c))
- Audit batch 2 - movie uaf, structured task sleeps, quit-and-play race ([`624dcdc`](https://github.com/mateo-m/empo-app/commit/624dcdc997cc8d5be8a3605671f87ff31a2584f6))
- Gate selectGame on engine teardown via continuation ([`3c51f43`](https://github.com/mateo-m/empo-app/commit/3c51f432d89c3ec3a6197d12542de78914fc2bcc))
- Keep relative paths relative in ios normalizepath ([`0a40f28`](https://github.com/mateo-m/empo-app/commit/0a40f2898c802fedb50d10f98f43546175ef981e))
- Drop zip escape-prefix check that false-positived on device ([`a2dfd18`](https://github.com/mateo-m/empo-app/commit/a2dfd183c3419285bb1658112abed836224049db))
- Snapshot capture uses copy-based bridge api ([`372a215`](https://github.com/mateo-m/empo-app/commit/372a21538da5fe5192d92284ecbaf5eea68e189d))
- 7z import progress no longer flashes full on first entry ([`3068651`](https://github.com/mateo-m/empo-app/commit/3068651a6c0b493ac3e2e765dbb9633b062532e1))
- Normalize '../' segments for relative paths on ios ([`aafa793`](https://github.com/mateo-m/empo-app/commit/aafa7935213860d82d66ff3b6a0f79303e856a17))
- Mkxp.json parser crashes on crlf line endings ([`4107bdb`](https://github.com/mateo-m/empo-app/commit/4107bdb66c01110545161c6c6c4b37978a906ad2))
- Check supported rgss version dynamically via engine bridge ([`c4e56db`](https://github.com/mateo-m/empo-app/commit/c4e56dbe295b672eb887323f9b07f97efa132ffd))
- Hero transition targets the tapped source, not always the continue card ([`fb7f0e4`](https://github.com/mateo-m/empo-app/commit/fb7f0e4f40f0eb608069e87eb53cfe51fdec89a2))
- Hero card placeholder ignoring color scheme ([`a8f2a55`](https://github.com/mateo-m/empo-app/commit/a8f2a557b9b8e1c2016a7a7798c0a539858e3ab6))
- Pin player glass controls to dark color scheme (#9) ([`52f0c1c`](https://github.com/mateo-m/empo-app/commit/52f0c1cf6c5995b4a9178d9f35ec3185ee47708e))
- Gate empty state on validation, handle disk space, show progress and artwork mid-import (#19) ([`a5a21ed`](https://github.com/mateo-m/empo-app/commit/a5a21edc16ca6029ed7a6d9e99c561929b2dc4bf))
- Pokemon uranium name-entry shows virtual keyboard on ios (#24) ([`0546a9e`](https://github.com/mateo-m/empo-app/commit/0546a9e0f41746f6c5faac7eb42e9b05c0f0910d))
- Don't map jgp enablePostloadScripts so reborn's compat shims stay active (#29) ([`d0cd256`](https://github.com/mateo-m/empo-app/commit/d0cd25655497f0521c726f12a65e726c48271e79))
- Retain pokemon windowskin across setSkin + memory overlay (#30) ([`76cd17d`](https://github.com/mateo-m/empo-app/commit/76cd17db88099522374462e97ce802939b4b0768))
- Snapshot developer mkxp.json from game folder, not our generated output ([`56eac43`](https://github.com/mateo-m/empo-app/commit/56eac43fa8fb37519dcfb3ee8cab38310810b698))
- Move multi-select entry to search row to clear ImportButton ([`e19ad1e`](https://github.com/mateo-m/empo-app/commit/e19ad1e1b726f846865be3392767098f488dae59))
- Keep search/sort visible in selection mode, hide delete button until something is selected ([`e4fcdb2`](https://github.com/mateo-m/empo-app/commit/e4fcdb2936d41582c6cf20019d5566e02a1957d9))
- Derive getRegion from system locale ([`b6570ba`](https://github.com/mateo-m/empo-app/commit/b6570bac72b0938001f366fdb233888616c680b8))
- Import races, ini encoding, progress contrast, mid-extract artwork stability (#32) ([`9d214da`](https://github.com/mateo-m/empo-app/commit/9d214da3ca727124d215de31b660cabfe8eb5dc2))
- Route Kernel#print to debug log instead of message box (#34) ([`1eee3d9`](https://github.com/mateo-m/empo-app/commit/1eee3d9f1d09249f55a9f02615fc7edcccdea675))
- Support Hash-form @prioautotiles in modern PE forks (#35) ([`24fad14`](https://github.com/mateo-m/empo-app/commit/24fad141fec4daa5f7e57bcc99694c5b8dc60734))
- Unify banner-less placeholder across loading view and info sheet ([`a956bba`](https://github.com/mateo-m/empo-app/commit/a956bba32bf6fd869a77046c75ab8c3114bcba1d))
- Replace exit(0) with manual-close instructions per app store guideline 2.5.1 ([`10f8f7c`](https://github.com/mateo-m/empo-app/commit/10f8f7c0d0dbbf68eceae89f18691689e2e89ad7))
- Clear swift 6 isolation and async-iterator warnings ([`c610a81`](https://github.com/mateo-m/empo-app/commit/c610a8119ed76d0770d2763f3004788e8ac293fb))
- Sync fast-forward toggle from engine bridge state on resume ([`64f751f`](https://github.com/mateo-m/empo-app/commit/64f751f6e524df041f8910b68d7bc515dee3dd47))
- Install git BEFORE actions/checkout in swift container (#54) ([`10282f0`](https://github.com/mateo-m/empo-app/commit/10282f0250d406e8b4d5422f627d40f8d36218af))
- Point SwiftLint at swiftly's sourcekitd on Linux (#56) ([`037333b`](https://github.com/mateo-m/empo-app/commit/037333bcbefba0e8b6510825cbcb997727e59f44))
- Resolve swiftly wrapper to real toolchain (#57) ([`95de7c2`](https://github.com/mateo-m/empo-app/commit/95de7c2d84f2e593ac7bc024c5beff964e4b31c3))
- Find sourcekitd by walking swiftly toolchains dir (#58) ([`e9add9b`](https://github.com/mateo-m/empo-app/commit/e9add9b1bb840ada6d41ea07b94cece3f3a29b58))
- Gitignore node_modules, remove from tracking ([`412732e`](https://github.com/mateo-m/empo-app/commit/412732ec67f99dcf66886e5d39993448789ae4a3))
- Build break in InterleavedRows multi-trailing-closure call (#64) ([`a97976b`](https://github.com/mateo-m/empo-app/commit/a97976b37096eccaef3f21f7d9aff21926ab4f8f))
- Disable SDL2_image samples to unblock iphoneos build ([`7e21d3f`](https://github.com/mateo-m/empo-app/commit/7e21d3f3555b0ef610cf1bbdb8b797495eceb4f0))
- Embed entitlements blob so naive resigners (esign) keep document picker working ([`70a6f3e`](https://github.com/mateo-m/empo-app/commit/70a6f3eab14fb29465ced896d49749bbe7aedb38))
- Pick documents via asCopy so naive resigners (esign, feather) work ([`4e71d79`](https://github.com/mateo-m/empo-app/commit/4e71d794acb2a26848c77a659bb12d475597c14b))
- Keep c++ rtti visible in merged.o so engine exceptions reach the binding catch ([`288e6e3`](https://github.com/mateo-m/empo-app/commit/288e6e3994abc163ba533bda401a662efacf030e))
- Add shared scheme so xcodegen output works in xcode out of the box ([`3e1044a`](https://github.com/mateo-m/empo-app/commit/3e1044ad5c41a861f879356b3759d3a25c1d6f1a))
- Adopt modern codesign flags for better resigner compatibility ([`297f368`](https://github.com/mateo-m/empo-app/commit/297f3685404588160f92253a6645b2e8f7b2396b))
- Drop hardened runtime flag, dyld refuses to load it on ios ([`c26b596`](https://github.com/mateo-m/empo-app/commit/c26b596585911bce6f123a2f3e85c3cdd8425800))
- Pac-free setjmp/longjmp for ruby 1.9 fiber switching ([`e068ebc`](https://github.com/mateo-m/empo-app/commit/e068ebcfdf8bf3f814c57d31b08d47473b3c9320))
- Default to ruby 3.1 + syntax-transform for legacy-grammar games ([`c4d4dbd`](https://github.com/mateo-m/empo-app/commit/c4d4dbd55b8ef96c7c177527d06753390d9b87d7))
- Keep shipped-version sniff, remap 1.x to 3.1 at dispatch time ([`024eb0c`](https://github.com/mateo-m/empo-app/commit/024eb0ccd25748868d659c1dd900e10eb8552fac))

### Chores

- Update README ([`1fb5b86`](https://github.com/mateo-m/empo-app/commit/1fb5b86d47a0aa412bb2e6f7bd701385d29939eb))
- Add git submodules for forked deps with build-time patch application ([`2276aef`](https://github.com/mateo-m/empo-app/commit/2276aeffd8b84a678278c2365a24a753a8b68149))
- Ignore submodule build artifacts in git and vscode ([`568280d`](https://github.com/mateo-m/empo-app/commit/568280d8177d1a19262e10c087830fc762be13b3))
- Gitignore generated git info file to avoid stale commit hash ([`f7d9785`](https://github.com/mateo-m/empo-app/commit/f7d97854e8381494ec732cd0055416d53373c8d4))
- Add post-commit hook to regenerate git info ([`11b34f5`](https://github.com/mateo-m/empo-app/commit/11b34f575ffbf31abafb835f667f87a1b340d88b))
- Add setup script and document post-clone steps in readme ([`055cb57`](https://github.com/mateo-m/empo-app/commit/055cb57f0469dfd5ff94a10ad869700a4cd83279))
- Untrack generated git info file ([`09b26b6`](https://github.com/mateo-m/empo-app/commit/09b26b6805580f3d902a6739a3f381b1e7384289))
- Move development_team into gitignored signing.xcconfig ([`a63b30d`](https://github.com/mateo-m/empo-app/commit/a63b30defc826e94af29ee8d35c1e825bae614f9))
- Replace vendored mkxp-z with submodule on own fork ([`ddf2c3d`](https://github.com/mateo-m/empo-app/commit/ddf2c3dafc27e5ea927c1b26bc5e1d94f39afe2a))
- Add privacy manifest and bluetooth usage description ([`e1ecf8f`](https://github.com/mateo-m/empo-app/commit/e1ecf8ff2e81ff2d9c5c36a2cc81a17e5afeb98c))
- Bump engine submodule ([`33fd2fb`](https://github.com/mateo-m/empo-app/commit/33fd2fbcd05dc6aad7c57929b70a3d83cdf20316))
- Bump engine submodule ([`33fd2fb`](https://github.com/mateo-m/empo-app/commit/33fd2fbcd05dc6aad7c57929b70a3d83cdf20316))
- Gitignore FUTURE.md scratchpad ([`de37347`](https://github.com/mateo-m/empo-app/commit/de373477fc3a19cd3437529a4241e1ec687202fa))
- Widen .md gitignore rule to allow docs/, ios/, and root README.md ([`d695a2f`](https://github.com/mateo-m/empo-app/commit/d695a2f21ff1c955a1e793830a92d8a425f40c65))
- Bump engine for fast-forward redraw-gate + graphics-init log ([`e7d0371`](https://github.com/mateo-m/empo-app/commit/e7d0371083c12d73d8b0cbc672ecfd0af554cdd3))
- Bump engine for resetSessionState + diagnostic logs ([`ca23d32`](https://github.com/mateo-m/empo-app/commit/ca23d321695a2ee5da7fbaf40dae7501a1de7eb8))
- Bump engine for vinemon mci shim, fmodex audio routing, const_missing hardening ([`f9a7822`](https://github.com/mateo-m/empo-app/commit/f9a78228a369ba88b69c08f089432fcdd3205006))
- Bump engine for session-reset audit ([`195e3e2`](https://github.com/mateo-m/empo-app/commit/195e3e27a4408fcc47202917d6c2c5a5d99461ad))
- Codebase cleanup pass (#38) ([`bba3691`](https://github.com/mateo-m/empo-app/commit/bba36918396551e670677d6f4520b882dc4f79f6))
- Bump engine submodule (hmode7 multi-ruby docs) (#42) ([`3f01540`](https://github.com/mateo-m/empo-app/commit/3f015401a8cd2e34947c5d1e7bdea946497d8459))
- Bump engine submodule (AUTHORS fork addition) (#46) ([`1e4c2d9`](https://github.com/mateo-m/empo-app/commit/1e4c2d93071dcdb734d19a8cd806e53d40644a51))
- Silence submodule-dirty noise on the three missing entries (#47) ([`7b14bb2`](https://github.com/mateo-m/empo-app/commit/7b14bb2d80a9a587fb329035c1bf520f7b41e228))
- Bump engine submodule (doc cleanup) (#49) ([`e397928`](https://github.com/mateo-m/empo-app/commit/e39792803ea1c864b05234ab840c46797d3957e5))
- Sync engine ([`13f76d3`](https://github.com/mateo-m/empo-app/commit/13f76d3beaf136a4053f1546da18956b8f04597d))
- Hydrate ANGLE prebuilts at build time, stop tracking (#50) ([`472a410`](https://github.com/mateo-m/empo-app/commit/472a410de2922eb78e615b1e7273f09dfef82f15))
- Tighten preBuildScripts (#51) ([`a54b76f`](https://github.com/mateo-m/empo-app/commit/a54b76fe0b287bef5b5e0d4637773d33ba6e5b23))
- Add lint + format tooling and CI workflows (#52) ([`f15df42`](https://github.com/mateo-m/empo-app/commit/f15df4270b4227c18304472f722afdd46f909100))
- Tighten lint+format configs, fix code ([`765c0c3`](https://github.com/mateo-m/empo-app/commit/765c0c38843595ae6794434ea29de78c5513f7ad))
- Audit pinned versions, switch swift+objc-cpp to Linux (#53) ([`f51bfe7`](https://github.com/mateo-m/empo-app/commit/f51bfe7a04a022f8ec17eaf6a85d18096293dcc6))
- Switch to canonical lint actions (#55) ([`e173dc4`](https://github.com/mateo-m/empo-app/commit/e173dc4c064b5d34d06c311a7a332056f2647086))
- Cache Swift toolchain across runs (#59) ([`c793865`](https://github.com/mateo-m/empo-app/commit/c793865a94a17d019ef8f5eaadcbfbc2db898b88))
- Cache npm + apt tools across runs (#61) ([`d8c9e6a`](https://github.com/mateo-m/empo-app/commit/d8c9e6a062c2e201300d23fc5f615899299142a5))
- Switch JS tools to bun, fix YAML colon parse error (#62) ([`b135a8b`](https://github.com/mateo-m/empo-app/commit/b135a8ba1df4ef028623f0d65b996afe440c178c))
- Sync engine ([`13f76d3`](https://github.com/mateo-m/empo-app/commit/13f76d3beaf136a4053f1546da18956b8f04597d))
- Polish disclaimer copy and settings credit line (#65) ([`4bf9361`](https://github.com/mateo-m/empo-app/commit/4bf936190c397bdcb951330f868d0fc1570009d8))
- Sync engine ([`13f76d3`](https://github.com/mateo-m/empo-app/commit/13f76d3beaf136a4053f1546da18956b8f04597d))
- Sync engine ([`13f76d3`](https://github.com/mateo-m/empo-app/commit/13f76d3beaf136a4053f1546da18956b8f04597d))
- Upload videos properly ([`55e4c69`](https://github.com/mateo-m/empo-app/commit/55e4c699afbae8d7d262e085db24a6b78f658a3b))
- Delete demo video ([`2a541f1`](https://github.com/mateo-m/empo-app/commit/2a541f1dc9ae7122d607a99727784dce4777ef78))
- Delete library demo video ([`23b2cea`](https://github.com/mateo-m/empo-app/commit/23b2cea635b54b9e09d69037289d8fa9ac184e9f))
- Update README ([`1fb5b86`](https://github.com/mateo-m/empo-app/commit/1fb5b86d47a0aa412bb2e6f7bd701385d29939eb))
- Bump mkxp-z-apple-mobile (nilclass id stub for pokemon flux) ([`138edfe`](https://github.com/mateo-m/empo-app/commit/138edfea103a51f04757a4784a0cfe707786a531))
- Sync ipa size after rebuild ([`93d42e3`](https://github.com/mateo-m/empo-app/commit/93d42e39a4a6daaafe25c1b29a36ad0722cbae8d))

### Documentation

- Add PATCHES.md for each modified dependency ([`76e5e38`](https://github.com/mateo-m/empo-app/commit/76e5e388770fd7d6e16301a25cb91603b0c75c66))
- Add sdl and ruby 1.8 lifecycle workarounds ([`426e1b1`](https://github.com/mateo-m/empo-app/commit/426e1b154c02bfb137f3235ef0c604d6aef5fe0e))
- Update readme and architecture docs to reflect swiftui library and ui polish ([`1513536`](https://github.com/mateo-m/empo-app/commit/151353654e041983e23a5e5d3e666771c58a17c2))
- Tighten settings descriptions to match actual behavior ([`c394e4f`](https://github.com/mateo-m/empo-app/commit/c394e4f9c4d201469f729aadc16ab6393d45ab19))
- Rewrite readme and rename ios-prefixed docs ([`79137d5`](https://github.com/mateo-m/empo-app/commit/79137d5c61c78e6169de7a503a9dc7c6451830d1))
- README rewrite + cleanup + PSDK removal (#41) ([`cd0b2d5`](https://github.com/mateo-m/empo-app/commit/cd0b2d5e1601a32daf05fdca9cbd0aa5492f33f0))
- Full cleanup + ux: delay stuck-loading message (#43) ([`9623c94`](https://github.com/mateo-m/empo-app/commit/9623c94c934ae5164bf0a42a06a5df4da37479b7))
- Add empo etymology, fix syntax-transform cross-ref, bump engine (#44) ([`559474a`](https://github.com/mateo-m/empo-app/commit/559474adbf5a68ac9162465d63219f2eabb0c9b1))
- Tighten empo etymology line (#45) ([`c11a5f9`](https://github.com/mateo-m/empo-app/commit/c11a5f9d975c3c859fae4d0f832b0393ef6457ad))
- Doc cleanup (#48) ([`103baee`](https://github.com/mateo-m/empo-app/commit/103baeebeb6a1c11338eb80927e8d7a9100e5d3f))
- Point users to releases page for prebuilt ipa ([`490c7c1`](https://github.com/mateo-m/empo-app/commit/490c7c10a9b496f185012847b8cd6e3e3fef87ec))
- Add demo videos + screenshots, refresh multi-ruby doc ([`3ccc0e5`](https://github.com/mateo-m/empo-app/commit/3ccc0e5f2052efcbe6e37c01ce53b08b2315573c))
- Shorten demo section captions ([`4d8921b`](https://github.com/mateo-m/empo-app/commit/4d8921ba3efc0ca75c32c767f674e8d35406e096))
- Add empo icon at the top ([`1da1c27`](https://github.com/mateo-m/empo-app/commit/1da1c278b74de665282b5f63feafa16e763979fe))
- Center status badges under hero ([`5cfe114`](https://github.com/mateo-m/empo-app/commit/5cfe114ee69c4cf266be954a3ed2fac64f0729f6))

### Features

- Initial ios port of mkxp-z with touch controls ([`533358c`](https://github.com/mateo-m/empo-app/commit/533358c9ea09dab523ddd50b59e6d37a66f4fa05))
- Add README ([`8e021a7`](https://github.com/mateo-m/empo-app/commit/8e021a71e7c4bbbd575b2be8412033e83343e63f))
- Add game library, return-to-library, and portrait gameplay ([`c11898d`](https://github.com/mateo-m/empo-app/commit/c11898d6117545997b61b2aaf1413ee24fe97fee))
- Abstract sdl out of touch controls, persist gl context across sessions ([`c5f806b`](https://github.com/mateo-m/empo-app/commit/c5f806b21508a89950161c57b785dc906dfbe9dc))
- Add hero zoom animation between library and game ([`93ac895`](https://github.com/mateo-m/empo-app/commit/93ac89517a2ee5c17b420e9edb30ff1211fc7ea6))
- Add game card, import validation, zip extraction, and cancellable imports ([`134fc58`](https://github.com/mateo-m/empo-app/commit/134fc584f21613bd0b20f7d695d76fbfa6394711))
- Add settings view with title position and debug mode toggles ([`d56af0c`](https://github.com/mateo-m/empo-app/commit/d56af0cd115052c717895f65285d13e522e0900d))
- Configurable log retention limit in settings ([`b043449`](https://github.com/mateo-m/empo-app/commit/b04344932c064e515dd9a79ff04a5d243695fac3))
- Ui polish with liquid glass, morphing import button, and theme system ([`30bb06e`](https://github.com/mateo-m/empo-app/commit/30bb06e0dd120a7f91071c39e5afaf22dfcb123b))
- Add game status enum to surface invalid imports in library ([`850a7f6`](https://github.com/mateo-m/empo-app/commit/850a7f683497920c5361501a104a955c6ee265f5))
- Add vwrap tileset fix for pokemon essentials games ([`0faf908`](https://github.com/mateo-m/empo-app/commit/0faf9084d93d8791fc57a273fa1d48d1efc7be06))
- Add experimental features system with game quit toggle ([`56df5cb`](https://github.com/mateo-m/empo-app/commit/56df5cb4a1e27f6a3929734e2e0b5d932dc9cf55))
- Add search bar, grid/list toggle, and list mode with morphing status indicator ([`024031b`](https://github.com/mateo-m/empo-app/commit/024031b159c3bd0c1eba1776bd333e3e019fc384))
- Add per-game settings with speed multiplier and fix rotation viewport ([`a097cb0`](https://github.com/mateo-m/empo-app/commit/a097cb0f22fa31d2824691df2a16f827b107bf4a))
- Expand per-game settings and add viewport bounds debug tool ([`7f76282`](https://github.com/mateo-m/empo-app/commit/7f76282812a500fc73c905282736009d13590e7b))
- Add game info view with metadata, play time tracking, and inline editing ([`1a107c8`](https://github.com/mateo-m/empo-app/commit/1a107c89bb3856fe69996688378228c8906a217e))
- Add pause/resume with manual and background pause modes ([`474d78f`](https://github.com/mateo-m/empo-app/commit/474d78f5251c8cc4b146f073fab0b47ba13e232c))
- Add haptic feedback settings and wire up game controls ([`2718ba4`](https://github.com/mateo-m/empo-app/commit/2718ba4f7afcd22e7552792f1570dbc5b1d9c67f))
- Add pixel art dither pattern to splash screen ([`8e91645`](https://github.com/mateo-m/empo-app/commit/8e916452f6542254dbe959c511b3366313f348df))
- Add primary, secondary, and outline button style variants with size options ([`2e5127f`](https://github.com/mateo-m/empo-app/commit/2e5127f3a8b84fbbfbff916b14f5df84ca92a571))
- Staggered empty state animations, import button morph, splash always-white text ([`d738d76`](https://github.com/mateo-m/empo-app/commit/d738d76a0752664362ea5c4af364d61994f1209b))
- Crash recovery and warning fixes for simulator GL context failures ([`87631b0`](https://github.com/mateo-m/empo-app/commit/87631b03be5ba1c26083698a9cd4faa0c800cbb3))
- Redesign game controls with glass visuals, edit zone, and staggered transitions ([`6658f37`](https://github.com/mateo-m/empo-app/commit/6658f37d6031ddd7d8c58be9ea1dfe221dd8f5c0))
- Add button sheet with categorized keys, animate new controls on insert ([`81110d5`](https://github.com/mateo-m/empo-app/commit/81110d5498cf07cb8304b6f05737a82783219e04))
- Add setting to toggle continue playing card ([`f7bc434`](https://github.com/mateo-m/empo-app/commit/f7bc434d5de1b9e170edabdc875618cecee396dd))
- Add library sorting by title, play time, size, and recency ([`185c0d1`](https://github.com/mateo-m/empo-app/commit/185c0d1842166c7651933bf28249fc823abcbd66))
- Add play/resume/quit actions to game context menu ([`ba34080`](https://github.com/mateo-m/empo-app/commit/ba34080f52cb3848de6c1ca48638822217b4ea4f))
- Integrate upstream ANGLE with retina fix and renderer enum ([`d785e37`](https://github.com/mateo-m/empo-app/commit/d785e37f904b0786a2edff350cf2a22bacddcefc))
- Add renderer setting with hot-swap and restart pill ([`e6e34fd`](https://github.com/mateo-m/empo-app/commit/e6e34fda34ab90a249a0cc61078caddd58406cf5))
- Add 7z and rar import support via libarchive ([`9853f6b`](https://github.com/mateo-m/empo-app/commit/9853f6b79cf91fac73df747e1badf7d0c177a166))
- Recover from rgss thread hangs by force-quitting the app ([`49f003a`](https://github.com/mateo-m/empo-app/commit/49f003ad265218c3d12790347e48d9afb2dbf9dc))
- Add first-launch disclaimer over splash ([`3f5fe27`](https://github.com/mateo-m/empo-app/commit/3f5fe27f05589a39d6d5148fba86efd95e3f5af5))
- Add quit-to-library escape on loading view ([`565928f`](https://github.com/mateo-m/empo-app/commit/565928f47df2006dee59f018c7eac84bae0d9407))
- Hard-deadline force-quit from loading-view escape hatch ([`c9d7c5c`](https://github.com/mateo-m/empo-app/commit/c9d7c5c9f22eeb77d9277819fba1b49c8b6610d6))
- Add tips system and replace edit chips in game info ([`53eac92`](https://github.com/mateo-m/empo-app/commit/53eac92ec8777cfe14dffaf5648be995664839e4))
- Add about section with licenses, privacy, and issue links ([`1ca4dab`](https://github.com/mateo-m/empo-app/commit/1ca4dab3ca950f38373feb0d579fbe9c3bb49a9f))
- Portrait overlay layout fallback for tall game rects ([`730a255`](https://github.com/mateo-m/empo-app/commit/730a2555343c1b3c1b2634cd14b6453f71f7b2c9))
- Enable debug logs by default ([`409419f`](https://github.com/mateo-m/empo-app/commit/409419fea914a92fe2e8c51ace7723a425b58dea))
- Show ruby version in debug overlay ([`8276c7d`](https://github.com/mateo-m/empo-app/commit/8276c7d805f314a602ab18c819eb33867da3e71d))
- Show build info sheet when tapping version in settings ([`adc9c03`](https://github.com/mateo-m/empo-app/commit/adc9c03497a55d8c8d0984038c9cea700652e113))
- Opt in to ios game mode ([`c68683f`](https://github.com/mateo-m/empo-app/commit/c68683f3911e1210393651219d87e038034dd8b9))
- Per-game controls layout (#8) ([`4eb1e28`](https://github.com/mateo-m/empo-app/commit/4eb1e28a576aebe1f9cf5245b60a87f9d20e6f2d))
- Extract game icon from .exe as primary artwork source (#20) ([`0a16eac`](https://github.com/mateo-m/empo-app/commit/0a16eac8930e9586c96b7b09cb6cc58f1538521a))
- Replace image-source action sheet with content-sized bottom sheet (#21) ([`5b6cf99`](https://github.com/mateo-m/empo-app/commit/5b6cf9983909aa18e302b8b61f3743b03116d2a6))
- Add cheats toolbar button with joiplay-compat menu (#25) ([`3d8f5ab`](https://github.com/mateo-m/empo-app/commit/3d8f5ab185b462483053927f72a5b87d4d106b86))
- Bump mkxp-z with joiplay nil safe-stubs + pokemon graphics compat (#26) ([`1f50e31`](https://github.com/mateo-m/empo-app/commit/1f50e3110b151db3536be936f08cf72c9c684bfd))
- Register mkxp-z patcher.cpp in xcodegen project spec (#27) ([`d65e672`](https://github.com/mateo-m/empo-app/commit/d65e67262a2b8c35e15044ffa7e0a14b4a04d57d))
- Import joiplay jgp archives with manifest-seeded settings and ruby 3 detection (#28) ([`d2c0fc5`](https://github.com/mateo-m/empo-app/commit/d2c0fc51d9a87a3d076b8dfa6c87c97925c3f134))
- Expose ruby compatibility picker per game; auto-redetect on launch ([`b3f313d`](https://github.com/mateo-m/empo-app/commit/b3f313d43a107530a3185083108e99da535db15d))
- Ios keyboard bridge for in-game text entry; route uitextfield typing to sdl_textinput ([`4761a5b`](https://github.com/mateo-m/empo-app/commit/4761a5bd7c59125924416471819cdde0edf22ccd))
- Bundled patcher distribution + EmpoState managed config dir ([`794a4bd`](https://github.com/mateo-m/empo-app/commit/794a4bdaa8866454915cba6331b15bcd00f3c822))
- Route syntaxTransform via bridge, typed enum, with auto-detect picker label ([`596a94e`](https://github.com/mateo-m/empo-app/commit/596a94e49a8adfc6f4e1aaedd4f8d6e8801dc523))
- Polish pass — sheet titles, unified artwork, overlay text shadow, multi-select ([`1496b11`](https://github.com/mateo-m/empo-app/commit/1496b112a7c0babf207e057b23415d68c4bce11c))
- Per-game on-screen-keyboard toggle, language-code locale, hero card glass gradient, hero card sizing tweaks ([`6225aaf`](https://github.com/mateo-m/empo-app/commit/6225aaf26adf48a22e267a1243e152a83f328853))
- Default In-game keyboard ON for Pokemon Essentials games ([`81ac7d0`](https://github.com/mateo-m/empo-app/commit/81ac7d02eb96866000634f15eda16b6dfbf9b43f))
- Replace hand-coded shapes with smallbits pixelated icons ([`eb4109c`](https://github.com/mateo-m/empo-app/commit/eb4109c1f20aac8b6df64d9579ddb8655915ecf1))
- Swap apple openal for openal-soft (#33) ([`2a1b48f`](https://github.com/mateo-m/empo-app/commit/2a1b48fd73b0c1038ced0b2bdf3177ffdc925f44))
- JoiPlay parity sprint - 5 preload/postload patches (#36) ([`78a3791`](https://github.com/mateo-m/empo-app/commit/78a3791f45d5c249e63b43a3d1812b0321e8482a))
- Exclude Documents/Games from iCloud backups ([`b206f5c`](https://github.com/mateo-m/empo-app/commit/b206f5c34c785e283e2b0582fcc1f6d49913d349))
- Default buttons to z/enter/b/escape (was a/b/shift/esc with redundant esc) ([`d34a5a6`](https://github.com/mateo-m/empo-app/commit/d34a5a66b556f91b30f344311f52f58f2ab970f9))
- Per-orientation layouts (portrait + landscape stored independently) ([`aceac67`](https://github.com/mateo-m/empo-app/commit/aceac67c75ae3ebcfd336407a7dc5432e6acb864))
- More-menu sheet + fast forward toggle; trim toolbar; new edit/debug icons ([`a5926b5`](https://github.com/mateo-m/empo-app/commit/a5926b556b49815290946f41805dbc408be3f2d5))
- Fast-forward via toggle+multiplier in game settings; menu sheet sized to content; rename to Menu ([`2f103b1`](https://github.com/mateo-m/empo-app/commit/2f103b1404775e795cf410f9883dda066d5b1063))
- Restart-required hint; render-scale picker; persist via applyToconfig in save() ([`b67b5a4`](https://github.com/mateo-m/empo-app/commit/b67b5a4a2822a7749a62c407de95b17ceaaa36b9))
- Translucent menu sheet; group pause+quit with game name; fast-forward resume sync ([`fad2e67`](https://github.com/mateo-m/empo-app/commit/fad2e67812710bebc8796785a3b60fa43ca7b7d3))
- Per-hint icon override ([`505c8a2`](https://github.com/mateo-m/empo-app/commit/505c8a2c0ca89439f51798bf0dfd19128e6093f3))
- Named-field restart hint; translucent pinned banner with slide-in transition ([`d2f2b97`](https://github.com/mateo-m/empo-app/commit/d2f2b97e96f7c6d5799366f865ae7d604ffbe50b))
- Detect bundled ruby 3 by binary content scan + fpk presence ([`14e36f7`](https://github.com/mateo-m/empo-app/commit/14e36f7eaefe4e2587fcacb17f250b91f76e3271))
- Show rgss and ruby versions in game info runtime section ([`33f700d`](https://github.com/mateo-m/empo-app/commit/33f700da3b6091ce9f15be7709004fe90edf6a25))
- Multi-Ruby native dispatch (1.8 / 1.9 / 3.0 / 3.1) ([`7a8de48`](https://github.com/mateo-m/empo-app/commit/7a8de48b99e7bd26bf000a38d6faa36fd886a78b))
- Add maker credit at the bottom of the sheet (#63) ([`a945ab0`](https://github.com/mateo-m/empo-app/commit/a945ab02a4071f2a16309fa1be973278d563ef5b))
- Add app icon ([`142560d`](https://github.com/mateo-m/empo-app/commit/142560de4d7440b2916e24f25cc1ca01e2e33e14))
- Swap controller glyph for empo mark ([`aa1eca6`](https://github.com/mateo-m/empo-app/commit/aa1eca64e8f5cb11178c16feb16b7560822505ce))
- Add empo mark to header ([`ce0834b`](https://github.com/mateo-m/empo-app/commit/ce0834b3d01336fc93f34587bc6b01b6f1d68f81))
- Show empo mark above wordmark, drop title shadow ([`1f6efd1`](https://github.com/mateo-m/empo-app/commit/1f6efd1e3a5f15f3346a5a4ce58706c26b4f0d92))
- Add github and twitter links to about section ([`984872a`](https://github.com/mateo-m/empo-app/commit/984872a0b419f0e851493d081f0fa21847618bd7))
- Show error message with github link after dismissal ([`f3fe61c`](https://github.com/mateo-m/empo-app/commit/f3fe61c9a20b7948ab286e237d7ccc670fb2c2c1))
- Real ruby 1.9 fibers + drop ruby 3.0 + syntax-transform ui ([`c93a32d`](https://github.com/mateo-m/empo-app/commit/c93a32d153f48a5cb21e84e84f1c66673dffe2bb))
- In-app update checker for sideload + altstore source manifest ([`41df4a5`](https://github.com/mateo-m/empo-app/commit/41df4a5f17609b6212ddc8aebb6d92dc8bca305b))

### Other

- Improve empty state transition with spring animation and full fade ([`98f07ff`](https://github.com/mateo-m/empo-app/commit/98f07ff223678e783095744ae234dfb13fb1ec16))
- Add brand color palette, list view swipe actions, and regroup game settings ([`dc8e7a5`](https://github.com/mateo-m/empo-app/commit/dc8e7a597f2be98bfc9c04c21700bad8b311f8e5))
- Smooth loading/resume transitions with snapshot overlay and dissolve ([`868713e`](https://github.com/mateo-m/empo-app/commit/868713e829c233ede2bbf9be1f6b325ea4d8091a))
- Fade in controls and toolbar when resuming from pause ([`ef1dcc3`](https://github.com/mateo-m/empo-app/commit/ef1dcc3a050a64e0818799f5668c7af96aff2f74))
- Add design system tokens, fix light-mode readability, and complete ui audit ([`9c2911c`](https://github.com/mateo-m/empo-app/commit/9c2911c4583c497bb4350b1b40177930cdf6f641))
- Playful animations for splash, empty state, import button, and loading view ([`59b12fe`](https://github.com/mateo-m/empo-app/commit/59b12fe60aa059cb33449d7fb81f567f1f3cd74f))
- Add progressive frosted glass blur to library header ([`5188856`](https://github.com/mateo-m/empo-app/commit/518885635f9004ecde902fd8d6381175210f8bd9))
- Wire version vars and add release script ([`d94dfff`](https://github.com/mateo-m/empo-app/commit/d94dfff54011e509508a0423dbc7f031d79b9944))
- Bump submodule for angle rotation layer fix ([`f51b3ef`](https://github.com/mateo-m/empo-app/commit/f51b3ef0ca14c5fc5984ce1eaea21c94cc65ca62))
- Bump submodule to drop mkxpz_legacy_ruby ([`fabcd04`](https://github.com/mateo-m/empo-app/commit/fabcd049fd328f4b254f8528a45b9f0d39198ccd))
- Add branch and default-branch fields to gitinfo.generated ([`995a2fa`](https://github.com/mateo-m/empo-app/commit/995a2fac5670800fa0100f81f64d7cd93d60b2e2))
- Bump for cross-session alias cleanup ([`777f6b9`](https://github.com/mateo-m/empo-app/commit/777f6b94c9479e7cbe8f210499d378dd43d0ab56))
- Anchor toolbar top-right, dismiss keyboard on outside tap ([`0619ebb`](https://github.com/mateo-m/empo-app/commit/0619ebb243411fd8c526e9286096c89fd0965fc2))
- Bump to refactor/engine-host (#5) ([`b36a7ae`](https://github.com/mateo-m/empo-app/commit/b36a7ae24b6d500338a6fa973028ee5346bb8ff2))
- Neutral outline toolbar, start dimmed, add IconButtonSize.sm ([`54df3e3`](https://github.com/mateo-m/empo-app/commit/54df3e3e13e659d047f292d7c34f0b41219d4470))
- Wire hmode7 port into xcode project and bump mkxp-z submodule ([`e857ec7`](https://github.com/mateo-m/empo-app/commit/e857ec7c03f00426c6ed457a573a45d06888cab7))
- Bump mkxp-z submodule for hm7 sscreenbitmap fix ([`b2233b0`](https://github.com/mateo-m/empo-app/commit/b2233b050540500bcf54bac3a4abc1b7d204f13e))
- Bump mkxp-z submodule for hm7 surface v1.2.1 adapter ([`1eb1881`](https://github.com/mateo-m/empo-app/commit/1eb18813b670d8dc810d22b2d818a7c28a7c96ab))
- Bump mkxp-z for hm7 fixnum-tagged params fix ([`477aefb`](https://github.com/mateo-m/empo-app/commit/477aefb939a7536f511f0c3f6b2b254da3425a13))
- Bump mkxp-z for hm7 render pipeline fixes ([`9c346d0`](https://github.com/mateo-m/empo-app/commit/9c346d0fea48d36fa96072465df8ba8a050e0afe))
- Add prebuild verifier for hmode7 submodule staleness ([`e09f3c4`](https://github.com/mateo-m/empo-app/commit/e09f3c458ba5d49f0f66322b3b37b3ef366bb3e4))
- Bump mkxp-z for hm7 bush-region fix and diag cleanup ([`5f85e3a`](https://github.com/mateo-m/empo-app/commit/5f85e3a5c4a11e4e1376315a4043f00337895ca3))
- Bump mkxp-z for hm7 diag cleanup ([`60f176e`](https://github.com/mateo-m/empo-app/commit/60f176e56f82d7ae817f4ac46a0ae64c635ec212))
- Bump mkxp-z for hm7 sprite guards ([`6205969`](https://github.com/mateo-m/empo-app/commit/6205969a5b9a83dba7d428a5fb7a38da5d0d5a6d))
- Bump mkxp-z for shim private-initialize fix ([`a2bda8a`](https://github.com/mateo-m/empo-app/commit/a2bda8a12d4814dfd21a3208b3fdd694673ee6c4))
- Bump mkxp-z for final shim cleanup ([`b3dc310`](https://github.com/mateo-m/empo-app/commit/b3dc310c0dbfd0e2c7de678454284b296aec3bab))
- Bump mkxp-z for final handoff ([`12d313e`](https://github.com/mateo-m/empo-app/commit/12d313ec58bc20bb761db86906aa802c378ce5d0))
- Bump mkxp-z for handoff known-limitation doc ([`05d3fe3`](https://github.com/mateo-m/empo-app/commit/05d3fe32e61c48697371c98750f36f46ca50e26b))
- Bump mkxp-z for spec-faithful revert ([`1dd7526`](https://github.com/mateo-m/empo-app/commit/1dd7526697e6df697da1f0dea41b1ab7c6529a4d))
- Bump mkxp-z for hm7 wall layer selection fix ([`a9e402f`](https://github.com/mateo-m/empo-app/commit/a9e402f34efc72e42c02e69ef2d55a011f802054))
- Bump mkxp-z for V1.4 detection boundary ([`fa0a2bd`](https://github.com/mateo-m/empo-app/commit/fa0a2bd685c2c34ae1b4349fd8d92f0ff464db4d))
- Bump mkxp-z for hmode7 readme cleanup ([`6da1328`](https://github.com/mateo-m/empo-app/commit/6da13289ccaba845e36c7fe6a88cbcc50f381e10))
- Bump mkxp-z for hmode7 per-frame upload optimization ([`21331dc`](https://github.com/mateo-m/empo-app/commit/21331dc12be972a9ee80f9a86866b8579d0cbea3))
- Bump mkxp-z for case-insensitive archive + insurgence region fix ([`88f7631`](https://github.com/mateo-m/empo-app/commit/88f76311938b6966bd3b277a6942a8ebe15296ca))
- Bump mkxp-z for hmode7 shim cross-session reinstall ([`793ef0c`](https://github.com/mateo-m/empo-app/commit/793ef0cff474532f3918fa236bf2c5303f8e5483))
- Bump mkxp-z for cheat-menu guard fix (reborn new-game crash) ([`16b3d37`](https://github.com/mateo-m/empo-app/commit/16b3d3722a61e8d24ab95f7db3de15019a3e326b))
- Bump mkxp-z for string aset legacy-idiom regression fix ([`764cd69`](https://github.com/mateo-m/empo-app/commit/764cd697504d67ad3e25166b4bebc0cb67b41aef))
- Bump mkxp-z for if session-2 viewport regression fix ([`1760739`](https://github.com/mateo-m/empo-app/commit/1760739dbbefd1327e553545c3419272837451d9))
- Bump mkxp-z for alstream underrun-replay improvements ([`2bdfd30`](https://github.com/mateo-m/empo-app/commit/2bdfd307d9033fa575ce914a38ce4aeecaf5c65a))
- Screen-blend hero halo, clean textShadow, header Select icon, floating destructive bulk-delete ([`bda5de2`](https://github.com/mateo-m/empo-app/commit/bda5de2ab390592d58ec6ce1ddf5ed7438b8c7d9))
- Sort grouping, contextual select, artwork shadows, indicator blend-mode (#40) ([`5f701af`](https://github.com/mateo-m/empo-app/commit/5f701af09f4da1d57b0054ef1219b96a116666ce))
- Dispatch follows detection verbatim; debug 1.9 corruption upstream ([`83c68de`](https://github.com/mateo-m/empo-app/commit/83c68de438d0b29f944f6225f9955201299fd60d))

### Performance

- Add NSCache-backed image cache for game artwork ([`f3b7fb4`](https://github.com/mateo-m/empo-app/commit/f3b7fb450792c47625c77319d258872b77417c43))
- Replace FPS samples array with ring buffer, load metadata once ([`8aad7d6`](https://github.com/mateo-m/empo-app/commit/8aad7d6cc630b2a04b26aa67afabac8d6400e60a))
- Cache gamesDirectory and ISO8601DateFormatter ([`5b0721f`](https://github.com/mateo-m/empo-app/commit/5b0721f1fdbf5edb4c3bc4729b036e93b0e636a2))
- Cache parsed game title during import to avoid redundant INI reads ([`20fb259`](https://github.com/mateo-m/empo-app/commit/20fb2592be54fdc1c929f4ea37ee3b3010512faa))
- Narrow GameCard observation to titlePosition only ([`7e59cad`](https://github.com/mateo-m/empo-app/commit/7e59cadea687800d37def7841d19fcddd582f762))
- Cache filteredGames and columns, fix gradient seam on rotation ([`097f03a`](https://github.com/mateo-m/empo-app/commit/097f03aa549d7434f88c5a2bf7d84d3e228cd42b))

### Refactor

- Migrate player view from uikit to swiftui ([`f4b5e02`](https://github.com/mateo-m/empo-app/commit/f4b5e02b6bc32948202e9f1d3f2b7d2a6ba6d806))
- Add keyboard accessory bar safe area stub ([`4154f55`](https://github.com/mateo-m/empo-app/commit/4154f55a2acff8c03b6f143d1c4ad5a871c32352))
- Organize source into feature-based directories ([`5cd1917`](https://github.com/mateo-m/empo-app/commit/5cd19178eeb091409765c5f4dce094a071cacf30))
- Split game-specific patches from engine compatibility layer ([`a316164`](https://github.com/mateo-m/empo-app/commit/a3161649414946c3c2533db9497cfb00cb117f23))
- Migrate from ObservableObject to @Observable macro ([`60e92d1`](https://github.com/mateo-m/empo-app/commit/60e92d1023a3d84b4aaea430b0fe84a944af7935))
- Replace timer-based polling with bridge callbacks ([`1203e9c`](https://github.com/mateo-m/empo-app/commit/1203e9c1bc1f3b0d36663cc64d5478b7466c87a8))
- Use native list sections and fix banner layout in game info view ([`715643e`](https://github.com/mateo-m/empo-app/commit/715643ee2620fd3c32feea8c2e2840f0e8c9ccb3))
- Use listSectionMargins for full-bleed banner in game info view ([`d951db8`](https://github.com/mateo-m/empo-app/commit/d951db82c80ffcd5d487880d95afa75c86e6c7be))
- Extract movie playback, shared ui components, and deduplicate patterns ([`86e8734`](https://github.com/mateo-m/empo-app/commit/86e87345be616b8d7cfe1de4ac7ea7e6b987dbe1))
- Split AppState into AppState and EngineState ([`958e914`](https://github.com/mateo-m/empo-app/commit/958e9144c794b9c7f37aed6016a28743cfcbb5d3))
- Replace AppPhase with optional GamePhase ([`7131fa1`](https://github.com/mateo-m/empo-app/commit/7131fa122dc669299f8002f310fa04b90fc11422))
- Add @MainActor to observable state classes ([`1abc066`](https://github.com/mateo-m/empo-app/commit/1abc0662b61a79448c85e5778830a3e06cceec3d))
- Decompose PlayerView into KeyCatalog, DebugOverlayView, and ControlsEditModifier ([`2bdebf0`](https://github.com/mateo-m/empo-app/commit/2bdebf0a40e49c77943db170480d5756ccdaac0b))
- Decompose GameLibraryView into ImportButton and GameContextMenu ([`c87d1b3`](https://github.com/mateo-m/empo-app/commit/c87d1b31c44345fb2b2dc8906390b14dc82e85ae))
- Remove dead AppState forwarding methods to EngineState ([`a47836b`](https://github.com/mateo-m/empo-app/commit/a47836b7396488bc38573ef95f28197873f2b124))
- Remove unnecessary comments and improve hasCustomizations scalability ([`4b6b94d`](https://github.com/mateo-m/empo-app/commit/4b6b94d2b4f9f68aff02b8b6cfbe35bcd114d998))
- Extract pause/resume into PauseManager, inline quit into PlayerView ([`7efb44d`](https://github.com/mateo-m/empo-app/commit/7efb44d235d5798abbc2d73c8a1004ba6084faaf))
- Use anchor-based positioning for import button expanded state ([`a1d66fc`](https://github.com/mateo-m/empo-app/commit/a1d66fc8343316c0f8b1b2d1794cfcaab70eeb87))
- Rename spacing tokens xxl/xxxl/xxxxl to _2xl/_3xl/_4xl ([`1204d94`](https://github.com/mateo-m/empo-app/commit/1204d94d4dcfb4805f68a28a389a3029c5d9b85d))
- Add IconButton component, migrate indicators, remove MARK comments ([`6f1debb`](https://github.com/mateo-m/empo-app/commit/6f1debb8126be04733c62fbc677fa42884c98aea))
- Split Primitives.swift, add Chip component, fix title edit dismiss ([`43150b4`](https://github.com/mateo-m/empo-app/commit/43150b42ea4993aa4e4ef9767a6f38b0e6c3f927))
- IconButton style variants, use in player toolbar, fix header tint ([`e311551`](https://github.com/mateo-m/empo-app/commit/e311551a7af05497df1b725204c76a18ce168b13))
- Game info view from List to ScrollView with full-bleed banner ([`1886faf`](https://github.com/mateo-m/empo-app/commit/1886faf4f29cbd6ea9481c70156830cce8f85db9))
- Codebase cleanup - deduplicate, remove unused code, fix circular deps, strengthen types ([`dd6614c`](https://github.com/mateo-m/empo-app/commit/dd6614ca455a7a70729703b39b2c63fe2fe403bb))
- Extract spinnerring + pausesnapshotoverlay, widen hero card in landscape ([`ce4f187`](https://github.com/mateo-m/empo-app/commit/ce4f187ae58b2ceb6a7c6f922a107678c75c70e4))
- Gamestatusindicator kind enum + stale crash marker detection ([`429c7f4`](https://github.com/mateo-m/empo-app/commit/429c7f4948d259d922f21e5777b9fff89e2b1c29))
- Assemble assets.bundle from engine submodule at build time ([`a0403fe`](https://github.com/mateo-m/empo-app/commit/a0403fe39e703e4bbb6189fd832631e436cdb365))
- Rename ios-prefixed files to platform-neutral ([`959f0ab`](https://github.com/mateo-m/empo-app/commit/959f0ab28f6d90e05db88e22e667f9d904149d3f))
- Splash panning uses continuous canvas phase, drop gamepad icon ([`780b08a`](https://github.com/mateo-m/empo-app/commit/780b08acf6e6f270aa515f9e60ac3a267a77ec1e))
- Rename ios_settings.json to game_settings.json and simplify save ([`23fbf54`](https://github.com/mateo-m/empo-app/commit/23fbf5449f5395e0411d0b6611578a12820faf21))
- Give ExperimentalSheetScaffold title/caption/message api ([`6d33df4`](https://github.com/mateo-m/empo-app/commit/6d33df47522a9297608ab36ec258b22a88f83c42))
- Collapse experimental sheets into native navigation pattern ([`73849f7`](https://github.com/mateo-m/empo-app/commit/73849f796fc7adc17297f3260adcc4cb357c77ac))
- Centralize UserDefaults keys, drop unshipped migrations (#11) ([`f01793f`](https://github.com/mateo-m/empo-app/commit/f01793f4bc9075ba31fcac58e308da3f75d2f7d0))
- Consolidate design tokens in theme (#12) ([`2afb532`](https://github.com/mateo-m/empo-app/commit/2afb532ff63db91317c267a9165a6ae1838909d6))
- Inject app services via swiftui environment (#13) ([`e07eb20`](https://github.com/mateo-m/empo-app/commit/e07eb208634ff9022b7f0bf69bb9d7348c5be364))
- Split appstate into crash, logging, termination helpers (#14) ([`33c8076`](https://github.com/mateo-m/empo-app/commit/33c8076b29c5303325a66ac625db15e6867501b3))
- Split playerview into geometry, toolbar, controls overlay (#15) ([`1882376`](https://github.com/mateo-m/empo-app/commit/188237649948e59ef524dd1c8e4946e133715950))
- Split gamelibraryview into hero card, search bar, sort sheet, sorting helpers (#16) ([`3155ae7`](https://github.com/mateo-m/empo-app/commit/3155ae7d86389df7cd3e5a64facdc250bc09a5e2))
- Remove dead code, add theme tokens, migrate literals (#17) ([`d7038df`](https://github.com/mateo-m/empo-app/commit/d7038df1a760ae4edc86d1969f3af072d21865b2))
- Migrate dispatchqueue hops to structured concurrency (#18) ([`5649b51`](https://github.com/mateo-m/empo-app/commit/5649b5129eeadf6480ea8762825c20146c880d72))
- Fill accessibility gaps and align debug overlay with theme tokens (#22) ([`43aebe9`](https://github.com/mateo-m/empo-app/commit/43aebe97d178f643a87e2078e30cc77f9cd8798b))
- Tidy up code comments (#23) ([`76b2299`](https://github.com/mateo-m/empo-app/commit/76b22992fceec11d807a150a6dcb6118b79e48de))
- Drop legacy config migration code (pre-launch, no users to migrate) ([`84d43aa`](https://github.com/mateo-m/empo-app/commit/84d43aabd4aae283192d8e500327f2d4007be90d))
- Drop dead per-game cheats toggle (was stored but never read at runtime) ([`2a9f1ba`](https://github.com/mateo-m/empo-app/commit/2a9f1ba4dd3cfe9a7af7acddd6f31a9ae55fc8dc))
- Co-locate per-game state under Games/<id>/ (#31) ([`9d7ed76`](https://github.com/mateo-m/empo-app/commit/9d7ed768f4ba51794ffbf804a157aacd07e844dd))
- Rename tip/tipstore to hint/hintstore (avoid app store reviewer iap ambiguity) ([`abccb81`](https://github.com/mateo-m/empo-app/commit/abccb8118e04725586269ed26312148b7a5b74f9))
- Drop mkxp.original.json snapshot; @setting wrappers; render-scale rework; vsync key fix ([`b60dc8a`](https://github.com/mateo-m/empo-app/commit/b60dc8a85205a0ffb031fa30df88e1d43c66d952))
- Consolidate per-session bridge resets via mkxp_resetsessionstate ([`a8b1967`](https://github.com/mateo-m/empo-app/commit/a8b1967c38e402232ef78da2cb7b4a4a7fb5b924))

### UI

- Show beta badge next to renderer label when angle selected ([`11c55b6`](https://github.com/mateo-m/empo-app/commit/11c55b637244e06818474abf0ded0cfdf616a02f))
- Add motion slow/gentle and radius.sheet tokens ([`2906ac1`](https://github.com/mateo-m/empo-app/commit/2906ac121841ba9ebcadb4c2ed4ca22f8fa6c57b))
- Accessibility, motion tokens, list press style, empty state polish ([`b7408b7`](https://github.com/mateo-m/empo-app/commit/b7408b7e49deba645918d5e88b3da1f2aa6abe06))
- Tip banner uses brand color and blur transition ([`4dc7de2`](https://github.com/mateo-m/empo-app/commit/4dc7de24b92530b3e21c95ba70caa2c1a4e64484))
- Brighten brand orange ([`86ec66c`](https://github.com/mateo-m/empo-app/commit/86ec66c790c3bfcd1b141e1fa315ab1a54fbeeff))
- Tip banner uses smaller semibold text ([`8f85c85`](https://github.com/mateo-m/empo-app/commit/8f85c85385e26f5ff83be85a6652434568830841))
- Add shadow to splash wordmark matching loading view ([`aaea4c1`](https://github.com/mateo-m/empo-app/commit/aaea4c1b4ac6fa84f7e7f1b2deedc6cfd9731107))
- Fix grid card placeholder ignoring color scheme; add gradient ([`fe109d5`](https://github.com/mateo-m/empo-app/commit/fe109d528a913586716bc85bd1352e121f828910))
- Remove gamepad icon and match splash wordmark in settings header ([`26012ae`](https://github.com/mateo-m/empo-app/commit/26012ae4aa00c2b48b01b9fcc93b3d6ced1a58ca))
