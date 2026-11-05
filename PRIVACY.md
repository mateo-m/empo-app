Empo runs on your iPhone, iPad, or Mac. There is no Empo account. The one Empo
server, `api.empo.mateo.sh`, takes part only when you sign in with Patreon for
Empo Plus.

Last update: 5 November 2026.

## What Empo collects

Nothing. Empo has no analytics, no crash reporting service, and no advertising.

Your games, your save files, and your settings stay in the app container on the
device. On an iPhone or iPad, iOS backs that container up to your own iCloud
backup if you turn iCloud backup on. That is an Apple feature, and Empo does not control it.

## What leaves the device

Empo makes the network requests below. Each one goes only where this section says.

The version of Empo from GitHub checks for updates. It reads the latest release
of the Empo repository from `api.github.com`. GitHub sees the request and the IP
address it came from. The App Store version does not make this request.

A certificate refresh reads `cacert.pem` from `curl.se`. Games need it for HTTPS.
The curl project sees the request and the IP address it came from.

Backups go to the locations that you add on the Backups screen: iCloud Drive,
Dropbox, Google Drive, S3 storage, or a WebDAV server. Empo sends your save
files and settings straight from the device to that location. You sign in to
Dropbox and Google Drive on their own pages, and Empo keeps the sign-in in the
Keychain of the device.

## Empo Plus and Patreon

When you sign in with Patreon for Empo Plus, Patreon sends Empo's server a code.
The server uses the code to read two facts from Patreon: your Patreon user ID,
and whether you have a paid membership of Empo on Patreon. It does not read your
name, your email address, or your payment details.

The server sends back a signed note of these two facts and a random key. The
device keeps both in its Keychain. The server keeps the Patreon sign-in, locked
with that key, so that it can ask Patreon again later. The server does not keep
the key, so it cannot open the sign-in on its own. Every few days, the device
sends the key to get a new note. Cloudflare runs the server, and it sees each
request and the IP address it came from.

Empo Plus works on up to 3 devices for each Patreon account. Each device makes
its own signing key, in the Secure Enclave when the device has one. The private
part never leaves the device. The server keeps the public part with the locked
sign-in, and it accepts a request only when the device signs it. For each
Patreon user ID, the server keeps a list of the devices that are signed in. The
list holds a number made from each public key, and no other device details.

Sign out of Patreon in Settings > Empo Plus to delete the note and the key from
the device, and the locked sign-in from the server. The server also deletes a
locked sign-in that no device used for 90 days, and a device list with no
signed-in devices.

## Games that go online

A game that you import can connect to the internet, for example to check for
its own updates or for online features. That traffic goes from the game to the
servers that its makers chose. Empo does not read it or keep it. To stop an RPG
Maker XP, VX, or VX Ace game from going online, turn off **Network access** in
the settings of that game.

## Device permissions

Empo asks for the camera only when you take a photo for custom game artwork.
The photo stays on the device. When you pick an image from the photo library
instead, iOS gives Empo only that one image.

Empo links the CoreBluetooth framework because SDL2 uses it to find game
controllers. Empo reads no Bluetooth data.

Some games have local multiplayer. iOS asks for local network permission before
such a game can find other players. Empo itself does not use the local network.

## Children

Empo is not directed at children under 13 and collects no data from anybody.
Empo's server reads only the Patreon facts above, and keeps only the locked
Patreon sign-in.

## Changes

A change to this policy shows here with a new date at the top.

## Contact

Send an email to [empo@mateo.sh](mailto:empo@mateo.sh), open an issue at
[github.com/mateo-m/empo-app](https://github.com/mateo-m/empo-app/issues), or ask on the
[Discord server](https://discord.gg/m3YnpXMxrB).
