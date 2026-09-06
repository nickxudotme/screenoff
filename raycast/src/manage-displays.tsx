import { Action, ActionPanel, Icon, List, openExtensionPreferences, showToast, Toast } from "@raycast/api";
import { useEffect, useState } from "react";
import { DisplayItem, isBuiltIn, listDisplays, runScreenoff } from "./screenoff";

function displayTitle(display: DisplayItem): string {
  return display.name || `Display ${display.id}`;
}

export default function ManageDisplays() {
  const [displays, setDisplays] = useState<DisplayItem[]>();
  const [error, setError] = useState<Error>();
  const [isLoading, setIsLoading] = useState(true);

  async function revalidate() {
    setIsLoading(true);
    setError(undefined);
    try {
      setDisplays(await listDisplays());
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError : new Error(String(loadError)));
    } finally {
      setIsLoading(false);
    }
  }

  useEffect(() => {
    void revalidate();
  }, []);

  async function run(display: DisplayItem, command: "on" | "off") {
    const verb = command === "off" ? "Disconnecting" : "Reconnecting";
    const pastTense = command === "off" ? "Disconnected" : "Reconnected";
    const toast = await showToast({ style: Toast.Style.Animated, title: `${verb} ${displayTitle(display)}` });
    try {
      await runScreenoff([command === "off" ? "disconnect" : "reconnect", String(display.id)]);
      toast.style = Toast.Style.Success;
      toast.title = `${pastTense} ${displayTitle(display)}`;
      await revalidate();
    } catch (actionError) {
      toast.style = Toast.Style.Failure;
      toast.title = "ScreenOff command failed";
      toast.message = actionError instanceof Error ? actionError.message : String(actionError);
    }
  }

  if (error) {
    return <List.EmptyView icon={Icon.ExclamationMark} title="Could not list displays" description={error.message} actions={<ActionPanel><Action title="Open Extension Preferences" onAction={openExtensionPreferences} /></ActionPanel>} />;
  }

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search displays...">
      {(displays ?? []).map((display) => (
        <List.Item
          key={display.id}
          icon={isBuiltIn(display) ? Icon.ComputerChip : Icon.Monitor}
          title={displayTitle(display)}
          subtitle={display.geometry}
          accessories={[{ text: display.state }, { tag: isBuiltIn(display) ? "Built-in" : "External" }]}
          actions={
            <ActionPanel>
              {!isBuiltIn(display) && (
                display.state === "disabled" || display.flags.includes("offline") ? (
                  <Action title="Reconnect Display" icon={Icon.Circle} onAction={() => run(display, "on")} shortcut={{ modifiers: ["cmd"], key: "r" }} />
                ) : (
                  <Action title="Disconnect Display" icon={Icon.Power} onAction={() => run(display, "off")} shortcut={{ modifiers: ["cmd"], key: "o" }} />
                )
              )}
              <ActionPanel.Section>
                <Action title="Refresh" icon={Icon.ArrowClockwise} onAction={revalidate} shortcut={{ modifiers: ["cmd"], key: "r" }} />
                <Action title="Open Extension Preferences" onAction={openExtensionPreferences} />
              </ActionPanel.Section>
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
