import { showHUD } from "@raycast/api";
import { runScreenoff } from "./screenoff";

export default async function command() {
  await runScreenoff(["disconnect", "all"]);
  await showHUD("External displays disconnected");
}
