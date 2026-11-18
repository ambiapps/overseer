# Overseer

A native macOS app for filing and managing the tickets our agents work on.

Tickets are GitHub issues on a GitHub project board. At Ambi that's the [Code board](https://github.com/orgs/ambiapps/projects/8). Filing a ticket into **To Do**, or moving one there, hands it to the agents: `ambre-agent`'s Worker hears the board move and starts `ambre-agent.yml`. In public repositories that only happens for tickets an owner wrote.

- **⌘N** files a ticket into To Do or Backlog.
- The board shows a column per state (Backlog, To Do, In Progress, In Review, Done); drag a card to move it. The toolbar filters by repository.
- A ticket shows its linked PRs and their checks, its comments, and buttons to move it on the board, restart the agents, comment, edit, close or reopen.

## Signing in

On first launch Overseer asks you to sign in to GitHub. It shows a code; enter it at github.com/login/device to approve Overseer for that account. Add as many accounts as you like in **Settings → GitHub Accounts**; tokens are kept in your Keychain. Then pick a board from any of them. Each account only sees what it already has access to on GitHub. An organization that restricts third-party apps needs an admin to approve Overseer once.

Overseer never reads the `gh` CLI's login or any other credentials on your Mac.

## Linear

The toolbar switches between the GitHub board and a Linear board. The Linear board shows one team's issues in a column per workflow state. Drag a card to change its state, and open it to read and add comments. Other agents pick Linear issues up on their own; Overseer only shows and moves them.

To connect it, sign in to linear.app (Google SSO works), create a personal API key under **Settings → Security & access**, and paste it in Overseer's Settings. Pick the team there or from the toolbar.

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
