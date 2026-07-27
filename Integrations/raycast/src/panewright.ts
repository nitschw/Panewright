import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { promisify } from "node:util";

const run = promisify(execFile);

/// AeroSpace is the control surface — Panewright configures it, and every
/// window operation goes through its CLI rather than through Panewright
/// itself. That keeps this extension working even while the Panewright app is
/// restarting, which it does on every config apply.
const AEROSPACE_PATHS = [
  "/opt/homebrew/bin/aerospace",
  "/usr/local/bin/aerospace",
  // The symlink Panewright maintains to whichever CLI it actually uses,
  // and the copy inside the app bundle — so the extension works even when
  // no brew link exists.
  `${homedir()}/.config/panewright/bin/aerospace`,
  "/Applications/Panewright.app/Contents/Helpers/aerospace-cli",
];

export class PanewrightNotInstalled extends Error {
  constructor() {
    super("AeroSpace not found. Install Panewright and run its setup first.");
    this.name = "PanewrightNotInstalled";
  }
}

function aerospacePath(): string {
  const found = AEROSPACE_PATHS.find((path) => existsSync(path));
  if (!found) throw new PanewrightNotInstalled();
  return found;
}

/** Run an AeroSpace command and return trimmed stdout. */
export async function aerospace(args: string[]): Promise<string> {
  const { stdout } = await run(aerospacePath(), args);
  return stdout.trim();
}

/** Run and split into non-empty lines — most queries are line-oriented. */
async function lines(args: string[]): Promise<string[]> {
  const out = await aerospace(args);
  return out.length === 0 ? [] : out.split("\n").map((l) => l.trim());
}

export type Workspace = {
  name: string;
  focused: boolean;
  /** App names of the windows on it, for the list subtitle. */
  apps: string[];
};

export async function workspaces(): Promise<Workspace[]> {
  const [names, focused] = await Promise.all([
    lines(["list-workspaces", "--monitor", "all", "--format", "%{workspace}"]),
    aerospace(["list-workspaces", "--focused"]),
  ]);

  // One query per workspace, run together rather than in sequence: on ten
  // workspaces the serial version is visibly slow to open.
  const populations = await Promise.all(
    names.map(async (name) => {
      try {
        return await lines(["list-windows", "--workspace", name, "--format", "%{app-name}"]);
      } catch {
        // A workspace that vanished between the two queries isn't an error
        // worth failing the whole list over.
        return [];
      }
    }),
  );

  return names.map((name, index) => ({
    name,
    focused: name === focused,
    apps: populations[index],
  }));
}

export async function focusWorkspace(name: string): Promise<void> {
  // summon-workspace, matching the binding Panewright generates: if the
  // workspace is visible on another monitor it comes to the focused one
  // rather than throwing focus across the desk.
  //
  // Note for anyone adding free-text entry here: AeroSpace accepts an unknown
  // workspace name without erroring — verified — so a typo would look like it
  // worked. Safe today only because every name offered comes from
  // `workspaces()`.
  await aerospace(["summon-workspace", name]);
}

export async function focusedWindowID(): Promise<string | undefined> {
  const found = await lines(["list-windows", "--focused", "--format", "%{window-id}"]);
  return found[0];
}

export async function focusedWindowTitle(): Promise<string> {
  const found = await lines([
    "list-windows",
    "--focused",
    "--format",
    "%{app-name} — %{window-title}",
  ]);
  return found[0] ?? "the focused window";
}

export async function moveFocusedWindow(workspace: string): Promise<void> {
  const id = await focusedWindowID();
  if (!id) throw new Error("No focused window to move.");
  await aerospace(["move-node-to-workspace", "--window-id", id, workspace]);
}

export type LayoutAction = {
  id: string;
  title: string;
  subtitle: string;
  args: string[];
};

/// Deliberately a short list. Anything needing a keystroke per second belongs
/// on a keybinding, not behind a launcher — these are the operations worth
/// reaching for by name when you can't remember the chord.
export const LAYOUT_ACTIONS: LayoutAction[] = [
  {
    id: "tiles",
    title: "Tile Horizontally",
    subtitle: "Side by side",
    args: ["layout", "tiles", "horizontal"],
  },
  {
    id: "tiles-vertical",
    title: "Tile Vertically",
    subtitle: "Stacked",
    args: ["layout", "tiles", "vertical"],
  },
  {
    id: "accordion",
    title: "Accordion Layout",
    subtitle: "Layered, one at a time",
    args: ["layout", "accordion"],
  },
  {
    id: "float",
    title: "Toggle Floating",
    subtitle: "Lift the window out of the tiling",
    args: ["layout", "floating", "tiling"],
  },
  {
    id: "fullscreen",
    title: "Toggle Fullscreen",
    subtitle: "Fill the workspace",
    args: ["fullscreen"],
  },
  {
    id: "balance",
    title: "Balance Sizes",
    subtitle: "Give every window an equal share",
    args: ["balance-sizes"],
  },
  {
    id: "flatten",
    title: "Flatten Workspace",
    subtitle: "Undo nested containers — the layout panic button",
    args: ["flatten-workspace-tree"],
  },
];
