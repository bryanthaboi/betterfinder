import { fs } from "betterfinder";
import type { PreviewRenderHandler } from "betterfinder";

export const render: PreviewRenderHandler = async (context, input) => {
  const text = await fs.readText(input.item, Math.min(input.maxBytes, 262144));
  return { title: input.item.name, node: { type: "markdown", text, label: input.item.name } };
};
