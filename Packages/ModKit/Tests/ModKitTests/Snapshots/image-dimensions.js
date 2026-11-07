"use strict";

export async function dimensions(context, input) {
  return (await __bf.call("media.imageDimensions", [input.items], context));
}
