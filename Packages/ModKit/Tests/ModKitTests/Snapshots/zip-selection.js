"use strict";

export async function zipSelection(context, input) {
  if (((input.selection).length === 0)) {
    return { "message": "Select something to zip first" };
  }
  let v_dest = (await __bf.call("ui.pickDestination", ["Choose where to save the archive"], context));
  if ((v_dest == null)) {
    return {};
  }
  let v_ticket = (await __bf.call("process.archive.create", [input.selection, __bf.unwrap(v_dest), "Archive", "zip"], context));
  return { "message": ("Zipping " + String((input.selection).length) + " items"), "operationId": v_ticket.operationId };
}
