Empo runs on your iPhone or iPad. There is no Empo account and no Empo server.

Last update: 7 September 2026.

## What Empo collects

Nothing. Empo has no analytics, no crash reporting service, and no advertising.

Your games, your save files, and your settings stay in the app container on the
device. iOS backs that container up to your own iCloud backup if you turn iCloud
backup on. That is an Apple feature, and Empo does not control it.

## What leaves the device

Empo makes two kinds of network request.

A version check reads the latest release of the Empo repository from
`api.github.com`. GitHub sees the request and the IP address it came from.

A certificate refresh reads `cacert.pem` from `curl.se`. Games need it for HTTPS.
The curl project sees the request and the IP address it came from.

Empo sends none of these to a server that Empo owns, because there is no such
server.

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

## Changes

A change to this policy shows here with a new date at the top.

## Contact

Open an issue at [github.com/mateo-m/empo-app](https://github.com/mateo-m/empo-app/issues),
or ask on the [Discord server](https://discord.gg/m3YnpXMxrB).
