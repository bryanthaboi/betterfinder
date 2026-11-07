"use strict";

export async function recentDownloads(context, input) {
  let v_root = (await __bf.call("fs.root", ["downloads"], context));
  if ((v_root == null)) {
    return { "items": [] };
  }
  let v_page = (await __bf.call("fs.list", [__bf.unwrap(v_root), input.limit, "modifiedDescending"], context));
  let v_out = [];
  {
    const l_1 = v_page.entries;
    __bf.loop(l_1, 128);
    for (const v_entry of l_1) {
      __bf.checkCancelled(context);
      v_out.push({ "id": v_entry.handle, "kind": v_entry.kind, "modified": v_entry.modified, "name": v_entry.name, "size": v_entry.size });
    }
  }
  return { "items": v_out };
}
