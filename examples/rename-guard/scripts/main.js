/** @type {import("betterfinder").FileopBeforeRenameHandler} */
export const guardRename = async (context, input) => {
  if (input.items.some(item => item.destinationName !== undefined && item.destinationName.endsWith(" "))) {
    return { decision: "deny", reason: "Names must not end with a space." };
  }
  return { decision: "allow" };
};
