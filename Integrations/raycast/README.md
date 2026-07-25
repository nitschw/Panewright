# Panewright for Raycast

Drive Panewright's tiling from Raycast, for the operations you reach for by
name rather than by chord.

## Commands

| Command | What it does |
| --- | --- |
| **Switch Workspace** | Lists every workspace with the apps on it, and marks the one you're on. Uses `summon-workspace`, matching Panewright's own bindings: a workspace visible on another monitor comes to you rather than throwing focus across the desk. |
| **Move Window to Workspace** | Sends the focused window elsewhere, naming the window in the search bar so you know what you're moving. |
| **Layout Command** | Tile, accordion, float, fullscreen, balance, and flatten. |
| **Open Panewright Settings** | Opens Settings, optionally on a tab: `general`, `keys`, `layout`, `appearance`, `bar`. |

## How it talks to Panewright

Window and workspace operations shell out to the **AeroSpace CLI**, not to the
Panewright app. That's deliberate: Panewright configures AeroSpace and restarts
itself on every config apply, so going through the CLI means the extension
keeps working while the app is bouncing.

The one exception is **Open Panewright Settings**, which uses Panewright's URL
scheme (`panewright://settings/<tab>`) because it's the only command that
addresses the app rather than the window manager.

Nothing here needs configuration on the Panewright side — there's no pairing
step, port, or token. If AeroSpace is installed, the extension works.

## Developing

Requires Node (Raycast extensions are TypeScript):

```
brew install node
cd Integrations/raycast
npm install
npm run dev
```

`npm run dev` registers the extension with your local Raycast; the commands
appear immediately and reload as you edit. `npm run build` produces a bundle
for submission to the Raycast store.

## Status

**Not yet run.** This was written without Node available on the development
machine, so it has never been typechecked, built, or executed — only the
underlying commands it issues were verified by hand against a live AeroSpace,
and the `panewright://settings/<tab>` deep links were confirmed to open the
right tab. Expect to fix small things on first `npm run dev`.
