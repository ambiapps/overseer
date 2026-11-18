# Overseer

A native macOS app for filing and managing the tickets our agents work on.

Tickets are GitHub issues in `ambiapps`, tracked on the [Code board](https://github.com/orgs/ambiapps/projects/8). Filing a ticket into **To Do**, or moving one there, hands it to the agents: `ambre-agent`'s Worker hears the board move and starts `ambre-agent.yml`. In public repositories that only happens for tickets an owner wrote.

- **⌘N** files a ticket into To Do or Backlog.
- The board shows a column per state (Backlog, To Do, In Progress, In Review, Done); drag a card to move it. The toolbar filters by repository.
- A ticket shows its linked PRs and their checks, its comments, and buttons to move it on the board, restart the agents, comment, edit, close or reopen.

## Install and updates

Every merge to `main` runs `.github/workflows/release.yml` on a GitHub-hosted macOS runner (`macos-26`). It runs the tests, builds `Overseer-<version>-<build>.dmg` and publishes a GitHub release tagged `v<VERSION>(<run number>)`.

Install the DMG from the [latest release](https://github.com/ambiapps/overseer/releases/latest) once. After that the app checks for a newer release at launch and hourly, offers it, and replaces and relaunches itself, as Orchard does. **Overseer → Check for Updates…** checks right away.

Bump `VERSION` for a new marketing version. The build number is the workflow's run number.

## Run from source

Open `Overseer.xcodeproj` in Xcode and run, or:

```sh
./scripts/build-app.sh --install
```

Local builds are build 0. They're only offered a release with a newer marketing version, and a Debug build from Xcode doesn't check for updates.

It uses your `gh` CLI login (`gh auth login`; the token needs `project` scope), or a token pasted in Settings. Settings also hold the organization and board number.
