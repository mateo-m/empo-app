Empo is one person's spare-time project. There is no support desk. There is a Discord server, a
GitHub issue tracker, and a maintainer who reads both.

## Ask on Discord

The [Empo Discord](https://discord.gg/m3YnpXMxrB) is the fastest place for a question. Other
players have often seen the same game fail and know the fix. Search the channel before you ask.

## Report a game on GitHub

Open an issue on [GitHub](https://github.com/mateo-m/empo-app/issues) when a game crashes,
renders wrong, or refuses to start. One issue per game. Include:

- The game title and the game version.
- The Empo version, from **Settings → About**.
- Your device and iOS version.
- What you did, what you expected, and what happened.
- The log file, collected as described below.

A report with a log is fixed in days. A report without one usually waits for the maintainer to
find the game and reproduce it.

## Collect the logs

1. Go to **Settings → Advanced**, and turn on **Debug logs**. Empo removes the older logs at
   the start of each session.
2. Start the game, and repeat the steps that fail.
3. Open the Files app, go to **On My iPhone → Empo**, and share the newest log file. Attach it
   to the issue, or post it on Discord.

## Suggest a feature

Open an issue with the word "idea" in the title. Say what you want to do, not how Empo should
do it.

## Contribute code

Read [CONTRIBUTING.md](https://github.com/mateo-m/empo-app/blob/main/CONTRIBUTING.md) for the
build requirements and the pull request rules. [How it works](https://empo.mateo.sh/how-it-works/) gives the
architecture in one page. Game compatibility reports and engine bridge work help the most.
