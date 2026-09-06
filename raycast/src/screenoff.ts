import { environment } from "@raycast/api";
import { execFile as execFileCallback } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

const execFile = promisify(execFileCallback);

export type DisplayItem = {
  index: number;
  id: number;
  name: string;
  state: string;
  geometry: string;
  flags: string[];
  identity?: string;
  uuid?: string;
};

function bundledCLI(): string {
  return join(environment.assetsPath, "screenoff");
}

export async function runScreenoff(arguments_: string[]): Promise<string> {
  const executable = bundledCLI();
  if (!existsSync(executable)) {
    throw new Error("ScreenOff's bundled CLI is missing. Rebuild the extension with npm run dev.");
  }
  try {
    const { stdout, stderr } = await execFile(executable, arguments_, { maxBuffer: 1024 * 1024 });
    return `${stdout}${stderr}`.trim();
  } catch (error) {
    throw new Error(error instanceof Error ? error.message : String(error));
  }
}

export async function listDisplays(): Promise<DisplayItem[]> {
  const output = await runScreenoff(["list", "--json"]);
  return JSON.parse(output) as DisplayItem[];
}

export function isBuiltIn(display: DisplayItem): boolean {
  return display.flags.includes("built-in");
}
