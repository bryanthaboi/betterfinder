import { ui, process, settings } from "betterfinder";
import type { ActivateHandler, CommandRunHandler } from "betterfinder";

export const activate: ActivateHandler = async (context, input) => {
  await ui.setPanel("terminal", { type: "vstack", children: [
    { type: "text", text: "Configure a shell command in settings, then run it.", label: "Terminal instructions" },
    { type: "button", text: "Run", label: "Run configured shell command", command: "run" }
  ] });
};

export const run: CommandRunHandler = async (context, input) => {
  const command = await settings.get("command");
  if (typeof command !== "string" || command.length === 0) return { message: "Set a shell command first" };
  const result = await process.run("/bin/zsh", ["-lc", command]);
  await ui.setPanel("terminal", { type: "vstack", children: [
    { type: "text", text: "$ " + command + "\n" + result.stdout + result.stderr, label: "Command output" },
    { type: "button", text: "Run again", label: "Run configured shell command again", command: "run" }
  ] });
  return { message: "Exit " + result.exitCode };
};
