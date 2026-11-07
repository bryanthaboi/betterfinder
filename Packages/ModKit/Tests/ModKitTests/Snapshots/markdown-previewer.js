"use strict";

export async function renderMarkdown(context, input) {
  let v_text = (await __bf.call("fs.readText", [input.item, input.maxBytes], context));
  return { "node": { "text": v_text, "type": "markdown" }, "title": input.item.name };
}
