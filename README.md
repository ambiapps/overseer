# Overseer

A native macOS app for filing and managing the tickets our agents work on.

Tickets are GitHub issues in `ambiapps`, tracked on the [Code board](https://github.com/orgs/ambiapps/projects/8). Filing a ticket into **To Do**, or moving one there, hands it to the agents: `ambre-agent`'s Worker hears the board move and starts `ambre-agent.yml`. In public repositories that only happens for tickets an owner wrote.

- **⌘N** files a ticket into To Do or Backlog.
- The sidebar shows the board's columns (To Do, In Progress, In Review, Backlog, Done), all open issues, and each repository.
- A ticket shows its linked PRs and their checks, its comments, and buttons to move it on the board, restart the agents, comment, edit, close or reopen.

## Run

Open `Overseer.xcodeproj` in Xcode and run, or:

```sh
xcodebuild -project Overseer.xcodeproj -scheme Overseer -derivedDataPath build build
open build/Build/Products/Debug/Overseer.app
```

It uses your `gh` CLI login (`gh auth login`; the token needs `project` scope), or a token pasted in Settings. Settings also hold the organization and board number.
