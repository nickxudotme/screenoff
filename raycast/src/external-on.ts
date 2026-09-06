import { showHUD } from "@raycast/api";
import { runScreenoff } from "./screenoff";

export default async function command() {
  await runScreenoff(["reconnect", "all"]);
  await showHUD("External displays reconnected");
}
