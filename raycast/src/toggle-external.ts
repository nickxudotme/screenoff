import { showHUD } from "@raycast/api";
import { runScreenoff } from "./screenoff";

export default async function command() {
  await runScreenoff(["toggle", "external"]);
  await showHUD("External displays updated");
}
