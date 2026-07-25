import { closeMainWindow, LaunchProps, open, showToast, Toast } from "@raycast/api";

const TABS = ["general", "keys", "layout", "appearance", "bar"];

/// Uses Panewright's own URL scheme rather than the AeroSpace CLI: this is the
/// one command that talks to the app rather than the window manager.
export default async function OpenSettings(
  props: LaunchProps<{ arguments: { tab?: string } }>,
) {
  const tab = props.arguments.tab?.trim().toLowerCase();
  if (tab && !TABS.includes(tab)) {
    await showToast({
      style: Toast.Style.Failure,
      title: `Unknown tab "${tab}"`,
      message: `Try one of: ${TABS.join(", ")}`,
    });
    return;
  }
  await closeMainWindow();
  // An unknown or absent segment opens Settings without jumping anywhere,
  // which is friendlier than refusing to open.
  await open(tab ? `panewright://settings/${tab}` : "panewright://settings");
}
