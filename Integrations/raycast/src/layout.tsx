import { Action, ActionPanel, Icon, List, showToast, Toast } from "@raycast/api";
import { aerospace, LAYOUT_ACTIONS } from "./panewright";

export default function Layout() {
  return (
    <List searchBarPlaceholder="Layout command…">
      {LAYOUT_ACTIONS.map((action) => (
        <List.Item
          key={action.id}
          icon={Icon.AppWindowGrid2x2}
          title={action.title}
          subtitle={action.subtitle}
          actions={
            <ActionPanel>
              <Action
                title={action.title}
                icon={Icon.Play}
                onAction={async () => {
                  try {
                    await aerospace(action.args);
                  } catch (e) {
                    await showToast({
                      style: Toast.Style.Failure,
                      title: "Command failed",
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
