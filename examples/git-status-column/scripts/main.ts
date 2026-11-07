import { fs, process } from "betterfinder";
import type { ColumnValuesHandler } from "betterfinder";

export const gitValues: ColumnValuesHandler = async (context, input) => {
  const root = await fs.root("repository");
  if (!root || !root.path) return input.items.map(item => ({ handle: item.handle, text: "" }));
  const rootPath = root.path;
  const status = await process.git.status(root);
  return input.items.map(item => {
    const relative = item.path && item.path.startsWith(rootPath + "/") ? item.path.slice(rootPath.length + 1) : undefined;
    const entry = status.entries.find(entry => entry.path === relative);
    return { handle: item.handle, text: entry ? entry.state : "" };
  });
};
