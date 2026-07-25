import { Action, ActionPanel, Icon, List, showToast, Toast } from "@raycast/api";
import { useEffect, useState } from "react";
import { focusWorkspace, workspaces, Workspace } from "./panewright";

export default function SwitchWorkspace() {
  const [items, setItems] = useState<Workspace[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | undefined>();

  useEffect(() => {
    workspaces()
      .then(setItems)
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
    <List isLoading={loading} searchBarPlaceholder="Switch to workspace…">
      {items.map((workspace) => (
        <List.Item
          key={workspace.name}
          // The workspace you're on is worth marking: half the time this list
          // is open to find out where you are, not to go somewhere.
          icon={workspace.focused ? Icon.Dot : Icon.Window}
          title={workspace.name}
          subtitle={workspace.apps.length > 0 ? workspace.apps.join(", ") : "empty"}
          accessories={workspace.focused ? [{ text: "current" }] : undefined}
          actions={
            <ActionPanel>
              <Action
                title="Switch to Workspace"
                icon={Icon.ArrowRight}
                onAction={async () => {
                  try {
                    await focusWorkspace(workspace.name);
                  } catch (e) {
                    await showToast({
                      style: Toast.Style.Failure,
                      title: "Couldn't switch",
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
