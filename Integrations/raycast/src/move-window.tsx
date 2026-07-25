import { Action, ActionPanel, Icon, List, showToast, Toast } from "@raycast/api";
import { useEffect, useState } from "react";
import { focusedWindowTitle, moveFocusedWindow, workspaces, Workspace } from "./panewright";

export default function MoveWindow() {
  const [items, setItems] = useState<Workspace[]>([]);
  const [window, setWindow] = useState("the focused window");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | undefined>();

  useEffect(() => {
    Promise.all([workspaces(), focusedWindowTitle()])
      .then(([spaces, title]) => {
        setItems(spaces);
        setWindow(title);
      })
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false));
  }, []);

  if (error) {
    return (
      <List>
        <List.EmptyView icon={Icon.Warning} title="Can't reach Panewright" description={error} />
      </List>
    );
  }

  return (
    <List isLoading={loading} searchBarPlaceholder={`Move ${window} to…`}>
      {items.map((workspace) => (
        <List.Item
          key={workspace.name}
          icon={Icon.Window}
          title={workspace.name}
          // Moving a window to where it already is does nothing; say so
          // rather than offering it as though it were a choice.
          subtitle={workspace.focused ? "current workspace" : workspace.apps.join(", ") || "empty"}
          actions={
            <ActionPanel>
              <Action
                title={`Move to Workspace ${workspace.name}`}
                icon={Icon.ArrowRight}
                onAction={async () => {
                  try {
                    await moveFocusedWindow(workspace.name);
                    await showToast({
                      style: Toast.Style.Success,
                      title: `Moved to workspace ${workspace.name}`,
                    });
                  } catch (e) {
                    await showToast({
                      style: Toast.Style.Failure,
                      title: "Couldn't move the window",
                      message: (e as Error).message,
                    });
                  }
                }}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
