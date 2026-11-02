---
title: Detect Empo from a game
description: The Ruby globals that tell a game script that Empo runs it, and which Empo version runs it.
---

Empo sets three Ruby globals before the first script of a game runs.
A script can read them to find out that Empo runs the game.

| Global              | Value                              | Example    |
| ------------------- | ---------------------------------- | ---------- |
| `$userAgent`        | The name of the launcher.          | `"empo"`   |
| `$empo`             | `true`.                            | `true`     |
| `$userAgentVersion` | The Empo version, a frozen string. | `"0.11.0"` |

## Which games get them

| Game                         | Gets the globals                          |
| ---------------------------- | ----------------------------------------- |
| RPG Maker XP, VX, and VX Ace | Yes                                       |
| Pokémon SDK (PSDK)           | Yes                                       |
| RPG Maker MV and MZ          | No. These games run JavaScript, not Ruby. |

## Check that Empo runs the game

```ruby
if $empo
  # Empo runs the game.
end
```

On a launcher that does not set `$empo`, the global is `nil`, so the
check is false.

## Check the Empo version

`$userAgentVersion` has three numbers with a period between each,
for example `"0.11.0"`. Compare the numbers, not the strings: as
strings, `"0.9.0"` is greater than `"0.11.0"`.

```ruby
def empo_at_least?(*wanted)
  parts = $userAgentVersion.to_s.split('.').map { |part| part.to_i }
  (parts <=> wanted) >= 0
end

if empo_at_least?(0, 11, 0)
  # Empo 0.11.0 or later runs the game.
end
```

When Empo cannot read its own version, `$userAgentVersion` is
`"unknown"`. Versions of Empo before the global existed do not set it,
so it is `nil`. The example above reads both as a version lower than
all others.

Do not read the version out of `$userAgent`. Other scripts use
`$userAgent` as a name, so it stays the name only.

## The engine version is a different value

In RPG Maker XP, VX, and VX Ace games, `System::VERSION` is the
version of the game engine inside Empo, not the version of Empo. One
Empo version can change its engine, and the engine version uses a
different format. To check Empo, use `$userAgentVersion`.
