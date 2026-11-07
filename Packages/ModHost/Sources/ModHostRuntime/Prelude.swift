import Foundation

enum ModPrelude {
    static let bridge = #"""
(function (native, names) {
  "use strict";
  const O = Object, A = Array, P = Promise, J = JSON, S = String, N = Number;
  const freeze = O.freeze, parse = J.parse, stringify = J.stringify, isArray = A.isArray, isSafe = N.isSafeInteger;
  const MapC = Map;
  class BFError extends Error {
    constructor(code, message) { super(S(message)); this.code = S(code); }
  }
  O.defineProperty(BFError.prototype, "name", { value: "BFError" });
  freeze(BFError.prototype); freeze(BFError);
  const pending = new MapC();
  let iterations = 0;
  let iterationLimit = 1000000;
  function deepFreeze(v, depth) {
    if (v === null || typeof v !== "object" || depth > 64) return v;
    freeze(v);
    for (const k of O.keys(v)) deepFreeze(v[k], depth + 1);
    return v;
  }
  function call(name, args) {
    return new P(function (resolve, reject) {
      if (typeof name !== "string") { reject(new BFError("invalidArgument", "call name must be a string")); return; }
      let text;
      try { text = stringify(isArray(args) ? args : []); } catch (e) { reject(new BFError("invalidArgument", "arguments must be plain data")); return; }
      const id = native.call(name, text === undefined ? "[]" : text);
      if (id.charAt(0) === "!") {
        const sep = id.indexOf(":");
        reject(new BFError(id.substring(1, sep), id.substring(sep + 1)));
        return;
      }
      pending.set(id, [resolve, reject]);
    });
  }
  function settle(id, ok, text, code) {
    const entry = pending.get(id);
    if (entry === undefined) return;
    pending.delete(id);
    if (ok) {
      let v;
      try { v = text === "" ? null : parse(text); } catch (e) { entry[1](new BFError("internal", "malformed result")); return; }
      entry[0](v);
    } else {
      entry[1](new BFError(code, text));
    }
  }
  const bf = {
    call: function (name, args, context) { return call(name, args); },
    checkCancelled: function (context) { if (native.cancelled()) throw new BFError("cancelled", "cancelled"); },
    loop: function (l, max) {
      if (!isArray(l)) throw new BFError("notIterable", "not a list");
      if (l.length > max) throw new BFError("limitExceeded", "loop bound " + max + " exceeded");
      iterations += l.length;
      if (iterations > iterationLimit) throw new BFError("limitExceeded", "iteration budget exceeded");
    },
    index: function (l, i) {
      if (!isArray(l) || !isSafe(i) || i < 0 || i >= l.length) throw new BFError("indexOutOfRange", "index out of range");
      return l[i];
    },
    i: function (n) { if (!isSafe(n)) throw new BFError("overflow", "integer overflow"); return n; },
    div: function (a, b) { if (b === 0) throw new BFError("divisionByZero", "division by zero"); return a / b; },
    mod: function (a, b) { if (b === 0) throw new BFError("divisionByZero", "division by zero"); return a % b; },
    substring: function (s, f, n) {
      s = S(s);
      if (!isSafe(f) || !isSafe(n) || f < 0 || n < 0) throw new BFError("indexOutOfRange", "substring out of range");
      return s.substring(f, f + n);
    },
    replace: function (s, a, b) { s = S(s); a = S(a); return a === "" ? s : s.split(a).join(S(b)); },
    unwrap: function (v) { if (v === null || v === undefined) throw new BFError("unwrapNull", "unwrap of null"); return v; },
    fail: function (m) { return new BFError("failed", S(m)); },
    BFError: BFError
  };
  for (const pair of names) {
    const name = pair[0];
    const full = pair[1];
    const parts = name.split(".");
    let target = bf;
    for (let i = 0; i < parts.length - 1; i++) {
      const p = parts[i];
      if (!O.prototype.hasOwnProperty.call(target, p)) target[p] = {};
      target = target[p];
    }
    target[parts[parts.length - 1]] = function () { return call(full, A.prototype.slice.call(arguments)); };
  }
  deepFreeze(bf, 0);
  function errorInfo(e) {
    try {
      if (e instanceof BFError) return [e.code, e.message];
      if (e instanceof Error) return ["scriptError", S(e.name) + ": " + S(e.message)];
      return ["scriptError", S(e)];
    } catch (x) {
      return ["scriptError", "unprintable error"];
    }
  }
  function run(fn, ctxText, inputText, ok, bad) {
    let p;
    try {
      if (typeof fn !== "function") { bad("notFound", "handler is not a function"); return; }
      const ctx = deepFreeze(parse(ctxText), 0);
      const input = parse(inputText);
      p = fn(ctx, input);
    } catch (e) {
      const i = errorInfo(e); bad(i[0], i[1]); return;
    }
    P.resolve(p).then(function (v) {
      let s;
      try { s = stringify(v === undefined ? null : v); } catch (e) { bad("invalidResult", "result must be plain data"); return; }
      ok(s === undefined ? "null" : s);
    }, function (e) {
      const i = errorInfo(e); bad(i[0], i[1]);
    });
  }
  function resetBudget(limit) { iterations = 0; iterationLimit = limit; }
  function hasHandler(exportsObject, name) {
    return exportsObject !== null && typeof exportsObject === "object" && O.prototype.hasOwnProperty.call(exportsObject, name) && typeof exportsObject[name] === "function";
  }
  return freeze({ bf: bf, settle: settle, run: run, resetBudget: resetBudget, hasHandler: hasHandler });
})
"""#

    static let harden = #"""
(function () {
  "use strict";
  const g = globalThis;
  const O = Object;
  const ctors = [
    (function () {}).constructor,
    (async function () {}).constructor,
    (function* () {}).constructor,
    (async function* () {}).constructor
  ];
  for (const C of ctors) {
    try { O.defineProperty(C.prototype, "constructor", { value: undefined, writable: false, configurable: false }); } catch (e) {}
  }
  for (const name of ["eval", "Function", "WebAssembly", "SharedArrayBuffer", "Atomics", "FinalizationRegistry", "WeakRef"]) {
    try { delete g[name]; } catch (e) {}
    if (name in g) { try { O.defineProperty(g, name, { value: undefined, writable: false, configurable: false }); } catch (e) {} }
  }
  const roots = [
    O, O.prototype, Array, Array.prototype, ctors[0].prototype, ctors[1].prototype, ctors[2].prototype, ctors[3].prototype,
    Promise, Promise.prototype, String, String.prototype, Number, Number.prototype, Boolean, Boolean.prototype,
    Symbol, Symbol.prototype, Error, Error.prototype, TypeError, TypeError.prototype, RangeError, RangeError.prototype,
    SyntaxError, SyntaxError.prototype, ReferenceError, ReferenceError.prototype, EvalError, EvalError.prototype, URIError, URIError.prototype,
    Map, Map.prototype, Set, Set.prototype, WeakMap, WeakMap.prototype, WeakSet, WeakSet.prototype,
    JSON, Math, Reflect, Date, Date.prototype, RegExp, RegExp.prototype, ArrayBuffer, ArrayBuffer.prototype,
    BigInt, BigInt.prototype, Proxy,
    O.getPrototypeOf([][Symbol.iterator]()), O.getPrototypeOf(O.getPrototypeOf([][Symbol.iterator]())),
    O.getPrototypeOf(new Map()[Symbol.iterator]()), O.getPrototypeOf(new Set()[Symbol.iterator]()),
    O.getPrototypeOf(""[Symbol.iterator]()), O.getPrototypeOf(Uint8Array), O.getPrototypeOf(Uint8Array.prototype),
    Uint8Array, Uint8Array.prototype, Int32Array, Int32Array.prototype, Float64Array, Float64Array.prototype, DataView, DataView.prototype
  ];
  for (const r of roots) { try { O.freeze(r); } catch (e) {} }
  return true;
})()
"""#

    static let benchmark = #"""
(function (n) {
  "use strict";
  let acc = 0;
  const arr = [];
  for (let i = 0; i < n; i++) {
    acc = (acc + i * 31) % 1000003;
    if ((i & 1023) === 0) arr.push({ handle: String(i), text: (acc % 640) + "×" + (acc % 480) });
  }
  return JSON.stringify(arr).length + acc;
})
"""#
}
