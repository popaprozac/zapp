#!/usr/bin/env bun
// @bun
var __create = Object.create;
var __getProtoOf = Object.getPrototypeOf;
var __defProp = Object.defineProperty;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __toESM = (mod, isNodeMode, target) => {
  target = mod != null ? __create(__getProtoOf(mod)) : {};
  const to = isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target;
  for (let key of __getOwnPropNames(mod))
    if (!__hasOwnProp.call(to, key))
      __defProp(to, key, {
        get: () => mod[key],
        enumerable: true
      });
  return to;
};
var __commonJS = (cb, mod) => () => (mod || cb((mod = { exports: {} }).exports, mod), mod.exports);
var __require = import.meta.require;

// node_modules/get-caller-file/index.js
var require_get_caller_file = __commonJS((exports, module) => {
  module.exports = function getCallerFile(position) {
    if (position === undefined) {
      position = 2;
    }
    if (position >= Error.stackTraceLimit) {
      throw new TypeError("getCallerFile(position) requires position be less then Error.stackTraceLimit but position was: `" + position + "` and Error.stackTraceLimit was: `" + Error.stackTraceLimit + "`");
    }
    var oldPrepareStackTrace = Error.prepareStackTrace;
    Error.prepareStackTrace = function(_, stack2) {
      return stack2;
    };
    var stack = new Error().stack;
    Error.prepareStackTrace = oldPrepareStackTrace;
    if (stack !== null && typeof stack === "object") {
      return stack[position] ? stack[position].getFileName() : undefined;
    }
  };
});

// node_modules/esbuild/lib/main.js
var require_main = __commonJS((exports, module) => {
  var __dirname = "/Users/zach/code/zapp/packages/cli/node_modules/esbuild/lib", __filename = "/Users/zach/code/zapp/packages/cli/node_modules/esbuild/lib/main.js";
  var __defProp2 = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames2 = Object.getOwnPropertyNames;
  var __hasOwnProp2 = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp2(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames2(from))
        if (!__hasOwnProp2.call(to, key) && key !== except)
          __defProp2(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp2({}, "__esModule", { value: true }), mod);
  var node_exports = {};
  __export(node_exports, {
    analyzeMetafile: () => analyzeMetafile,
    analyzeMetafileSync: () => analyzeMetafileSync,
    build: () => build,
    buildSync: () => buildSync,
    context: () => context,
    default: () => node_default2,
    formatMessages: () => formatMessages,
    formatMessagesSync: () => formatMessagesSync,
    initialize: () => initialize,
    stop: () => stop,
    transform: () => transform,
    transformSync: () => transformSync,
    version: () => version
  });
  module.exports = __toCommonJS(node_exports);
  function encodePacket(packet) {
    let visit = (value) => {
      if (value === null) {
        bb.write8(0);
      } else if (typeof value === "boolean") {
        bb.write8(1);
        bb.write8(+value);
      } else if (typeof value === "number") {
        bb.write8(2);
        bb.write32(value | 0);
      } else if (typeof value === "string") {
        bb.write8(3);
        bb.write(encodeUTF8(value));
      } else if (value instanceof Uint8Array) {
        bb.write8(4);
        bb.write(value);
      } else if (value instanceof Array) {
        bb.write8(5);
        bb.write32(value.length);
        for (let item of value) {
          visit(item);
        }
      } else {
        let keys = Object.keys(value);
        bb.write8(6);
        bb.write32(keys.length);
        for (let key of keys) {
          bb.write(encodeUTF8(key));
          visit(value[key]);
        }
      }
    };
    let bb = new ByteBuffer;
    bb.write32(0);
    bb.write32(packet.id << 1 | +!packet.isRequest);
    visit(packet.value);
    writeUInt32LE(bb.buf, bb.len - 4, 0);
    return bb.buf.subarray(0, bb.len);
  }
  function decodePacket(bytes) {
    let visit = () => {
      switch (bb.read8()) {
        case 0:
          return null;
        case 1:
          return !!bb.read8();
        case 2:
          return bb.read32();
        case 3:
          return decodeUTF8(bb.read());
        case 4:
          return bb.read();
        case 5: {
          let count = bb.read32();
          let value2 = [];
          for (let i = 0;i < count; i++) {
            value2.push(visit());
          }
          return value2;
        }
        case 6: {
          let count = bb.read32();
          let value2 = {};
          for (let i = 0;i < count; i++) {
            value2[decodeUTF8(bb.read())] = visit();
          }
          return value2;
        }
        default:
          throw new Error("Invalid packet");
      }
    };
    let bb = new ByteBuffer(bytes);
    let id = bb.read32();
    let isRequest = (id & 1) === 0;
    id >>>= 1;
    let value = visit();
    if (bb.ptr !== bytes.length) {
      throw new Error("Invalid packet");
    }
    return { id, isRequest, value };
  }
  var ByteBuffer = class {
    constructor(buf = new Uint8Array(1024)) {
      this.buf = buf;
      this.len = 0;
      this.ptr = 0;
    }
    _write(delta) {
      if (this.len + delta > this.buf.length) {
        let clone = new Uint8Array((this.len + delta) * 2);
        clone.set(this.buf);
        this.buf = clone;
      }
      this.len += delta;
      return this.len - delta;
    }
    write8(value) {
      let offset = this._write(1);
      this.buf[offset] = value;
    }
    write32(value) {
      let offset = this._write(4);
      writeUInt32LE(this.buf, value, offset);
    }
    write(bytes) {
      let offset = this._write(4 + bytes.length);
      writeUInt32LE(this.buf, bytes.length, offset);
      this.buf.set(bytes, offset + 4);
    }
    _read(delta) {
      if (this.ptr + delta > this.buf.length) {
        throw new Error("Invalid packet");
      }
      this.ptr += delta;
      return this.ptr - delta;
    }
    read8() {
      return this.buf[this._read(1)];
    }
    read32() {
      return readUInt32LE(this.buf, this._read(4));
    }
    read() {
      let length = this.read32();
      let bytes = new Uint8Array(length);
      let ptr = this._read(bytes.length);
      bytes.set(this.buf.subarray(ptr, ptr + length));
      return bytes;
    }
  };
  var encodeUTF8;
  var decodeUTF8;
  var encodeInvariant;
  if (typeof TextEncoder !== "undefined" && typeof TextDecoder !== "undefined") {
    let encoder = new TextEncoder;
    let decoder = new TextDecoder;
    encodeUTF8 = (text) => encoder.encode(text);
    decodeUTF8 = (bytes) => decoder.decode(bytes);
    encodeInvariant = 'new TextEncoder().encode("")';
  } else if (typeof Buffer !== "undefined") {
    encodeUTF8 = (text) => Buffer.from(text);
    decodeUTF8 = (bytes) => {
      let { buffer, byteOffset, byteLength } = bytes;
      return Buffer.from(buffer, byteOffset, byteLength).toString();
    };
    encodeInvariant = 'Buffer.from("")';
  } else {
    throw new Error("No UTF-8 codec found");
  }
  if (!(encodeUTF8("") instanceof Uint8Array))
    throw new Error(`Invariant violation: "${encodeInvariant} instanceof Uint8Array" is incorrectly false

This indicates that your JavaScript environment is broken. You cannot use
esbuild in this environment because esbuild relies on this invariant. This
is not a problem with esbuild. You need to fix your environment instead.
`);
  function readUInt32LE(buffer, offset) {
    return (buffer[offset++] | buffer[offset++] << 8 | buffer[offset++] << 16 | buffer[offset++] << 24) >>> 0;
  }
  function writeUInt32LE(buffer, value, offset) {
    buffer[offset++] = value;
    buffer[offset++] = value >> 8;
    buffer[offset++] = value >> 16;
    buffer[offset++] = value >> 24;
  }
  var fromCharCode = String.fromCharCode;
  function throwSyntaxError(bytes, index, message) {
    const c = bytes[index];
    let line = 1;
    let column = 0;
    for (let i = 0;i < index; i++) {
      if (bytes[i] === 10) {
        line++;
        column = 0;
      } else {
        column++;
      }
    }
    throw new SyntaxError(message ? message : index === bytes.length ? "Unexpected end of input while parsing JSON" : c >= 32 && c <= 126 ? `Unexpected character ${fromCharCode(c)} in JSON at position ${index} (line ${line}, column ${column})` : `Unexpected byte 0x${c.toString(16)} in JSON at position ${index} (line ${line}, column ${column})`);
  }
  function JSON_parse(bytes) {
    if (!(bytes instanceof Uint8Array)) {
      throw new Error(`JSON input must be a Uint8Array`);
    }
    const propertyStack = [];
    const objectStack = [];
    const stateStack = [];
    const length = bytes.length;
    let property = null;
    let state = 0;
    let object;
    let i = 0;
    while (i < length) {
      let c = bytes[i++];
      if (c <= 32) {
        continue;
      }
      let value;
      if (state === 2 && property === null && c !== 34 && c !== 125) {
        throwSyntaxError(bytes, --i);
      }
      switch (c) {
        case 116: {
          if (bytes[i++] !== 114 || bytes[i++] !== 117 || bytes[i++] !== 101) {
            throwSyntaxError(bytes, --i);
          }
          value = true;
          break;
        }
        case 102: {
          if (bytes[i++] !== 97 || bytes[i++] !== 108 || bytes[i++] !== 115 || bytes[i++] !== 101) {
            throwSyntaxError(bytes, --i);
          }
          value = false;
          break;
        }
        case 110: {
          if (bytes[i++] !== 117 || bytes[i++] !== 108 || bytes[i++] !== 108) {
            throwSyntaxError(bytes, --i);
          }
          value = null;
          break;
        }
        case 45:
        case 46:
        case 48:
        case 49:
        case 50:
        case 51:
        case 52:
        case 53:
        case 54:
        case 55:
        case 56:
        case 57: {
          let index = i;
          value = fromCharCode(c);
          c = bytes[i];
          while (true) {
            switch (c) {
              case 43:
              case 45:
              case 46:
              case 48:
              case 49:
              case 50:
              case 51:
              case 52:
              case 53:
              case 54:
              case 55:
              case 56:
              case 57:
              case 101:
              case 69: {
                value += fromCharCode(c);
                c = bytes[++i];
                continue;
              }
            }
            break;
          }
          value = +value;
          if (isNaN(value)) {
            throwSyntaxError(bytes, --index, "Invalid number");
          }
          break;
        }
        case 34: {
          value = "";
          while (true) {
            if (i >= length) {
              throwSyntaxError(bytes, length);
            }
            c = bytes[i++];
            if (c === 34) {
              break;
            } else if (c === 92) {
              switch (bytes[i++]) {
                case 34:
                  value += '"';
                  break;
                case 47:
                  value += "/";
                  break;
                case 92:
                  value += "\\";
                  break;
                case 98:
                  value += "\b";
                  break;
                case 102:
                  value += "\f";
                  break;
                case 110:
                  value += `
`;
                  break;
                case 114:
                  value += "\r";
                  break;
                case 116:
                  value += "\t";
                  break;
                case 117: {
                  let code = 0;
                  for (let j = 0;j < 4; j++) {
                    c = bytes[i++];
                    code <<= 4;
                    if (c >= 48 && c <= 57)
                      code |= c - 48;
                    else if (c >= 97 && c <= 102)
                      code |= c + (10 - 97);
                    else if (c >= 65 && c <= 70)
                      code |= c + (10 - 65);
                    else
                      throwSyntaxError(bytes, --i);
                  }
                  value += fromCharCode(code);
                  break;
                }
                default:
                  throwSyntaxError(bytes, --i);
                  break;
              }
            } else if (c <= 127) {
              value += fromCharCode(c);
            } else if ((c & 224) === 192) {
              value += fromCharCode((c & 31) << 6 | bytes[i++] & 63);
            } else if ((c & 240) === 224) {
              value += fromCharCode((c & 15) << 12 | (bytes[i++] & 63) << 6 | bytes[i++] & 63);
            } else if ((c & 248) == 240) {
              let codePoint = (c & 7) << 18 | (bytes[i++] & 63) << 12 | (bytes[i++] & 63) << 6 | bytes[i++] & 63;
              if (codePoint > 65535) {
                codePoint -= 65536;
                value += fromCharCode(codePoint >> 10 & 1023 | 55296);
                codePoint = 56320 | codePoint & 1023;
              }
              value += fromCharCode(codePoint);
            }
          }
          value[0];
          break;
        }
        case 91: {
          value = [];
          propertyStack.push(property);
          objectStack.push(object);
          stateStack.push(state);
          property = null;
          object = value;
          state = 1;
          continue;
        }
        case 123: {
          value = {};
          propertyStack.push(property);
          objectStack.push(object);
          stateStack.push(state);
          property = null;
          object = value;
          state = 2;
          continue;
        }
        case 93: {
          if (state !== 1) {
            throwSyntaxError(bytes, --i);
          }
          value = object;
          property = propertyStack.pop();
          object = objectStack.pop();
          state = stateStack.pop();
          break;
        }
        case 125: {
          if (state !== 2) {
            throwSyntaxError(bytes, --i);
          }
          value = object;
          property = propertyStack.pop();
          object = objectStack.pop();
          state = stateStack.pop();
          break;
        }
        default: {
          throwSyntaxError(bytes, --i);
        }
      }
      c = bytes[i];
      while (c <= 32) {
        c = bytes[++i];
      }
      switch (state) {
        case 0: {
          if (i === length) {
            return value;
          }
          break;
        }
        case 1: {
          object.push(value);
          if (c === 44) {
            i++;
            continue;
          }
          if (c === 93) {
            continue;
          }
          break;
        }
        case 2: {
          if (property === null) {
            property = value;
            if (c === 58) {
              i++;
              continue;
            }
          } else {
            object[property] = value;
            property = null;
            if (c === 44) {
              i++;
              continue;
            }
            if (c === 125) {
              continue;
            }
          }
          break;
        }
      }
      break;
    }
    throwSyntaxError(bytes, i);
  }
  var quote = JSON.stringify;
  var buildLogLevelDefault = "warning";
  var transformLogLevelDefault = "silent";
  function validateAndJoinStringArray(values, what) {
    const toJoin = [];
    for (const value of values) {
      validateStringValue(value, what);
      if (value.indexOf(",") >= 0)
        throw new Error(`Invalid ${what}: ${value}`);
      toJoin.push(value);
    }
    return toJoin.join(",");
  }
  var canBeAnything = () => null;
  var mustBeBoolean = (value) => typeof value === "boolean" ? null : "a boolean";
  var mustBeString = (value) => typeof value === "string" ? null : "a string";
  var mustBeRegExp = (value) => value instanceof RegExp ? null : "a RegExp object";
  var mustBeInteger = (value) => typeof value === "number" && value === (value | 0) ? null : "an integer";
  var mustBeValidPortNumber = (value) => typeof value === "number" && value === (value | 0) && value >= 0 && value <= 65535 ? null : "a valid port number";
  var mustBeFunction = (value) => typeof value === "function" ? null : "a function";
  var mustBeArray = (value) => Array.isArray(value) ? null : "an array";
  var mustBeArrayOfStrings = (value) => Array.isArray(value) && value.every((x) => typeof x === "string") ? null : "an array of strings";
  var mustBeObject = (value) => typeof value === "object" && value !== null && !Array.isArray(value) ? null : "an object";
  var mustBeEntryPoints = (value) => typeof value === "object" && value !== null ? null : "an array or an object";
  var mustBeWebAssemblyModule = (value) => value instanceof WebAssembly.Module ? null : "a WebAssembly.Module";
  var mustBeObjectOrNull = (value) => typeof value === "object" && !Array.isArray(value) ? null : "an object or null";
  var mustBeStringOrBoolean = (value) => typeof value === "string" || typeof value === "boolean" ? null : "a string or a boolean";
  var mustBeStringOrObject = (value) => typeof value === "string" || typeof value === "object" && value !== null && !Array.isArray(value) ? null : "a string or an object";
  var mustBeStringOrArrayOfStrings = (value) => typeof value === "string" || Array.isArray(value) && value.every((x) => typeof x === "string") ? null : "a string or an array of strings";
  var mustBeStringOrUint8Array = (value) => typeof value === "string" || value instanceof Uint8Array ? null : "a string or a Uint8Array";
  var mustBeStringOrURL = (value) => typeof value === "string" || value instanceof URL ? null : "a string or a URL";
  function getFlag(object, keys, key, mustBeFn) {
    let value = object[key];
    keys[key + ""] = true;
    if (value === undefined)
      return;
    let mustBe = mustBeFn(value);
    if (mustBe !== null)
      throw new Error(`${quote(key)} must be ${mustBe}`);
    return value;
  }
  function checkForInvalidFlags(object, keys, where) {
    for (let key in object) {
      if (!(key in keys)) {
        throw new Error(`Invalid option ${where}: ${quote(key)}`);
      }
    }
  }
  function validateInitializeOptions(options) {
    let keys = /* @__PURE__ */ Object.create(null);
    let wasmURL = getFlag(options, keys, "wasmURL", mustBeStringOrURL);
    let wasmModule = getFlag(options, keys, "wasmModule", mustBeWebAssemblyModule);
    let worker = getFlag(options, keys, "worker", mustBeBoolean);
    checkForInvalidFlags(options, keys, "in initialize() call");
    return {
      wasmURL,
      wasmModule,
      worker
    };
  }
  function validateMangleCache(mangleCache) {
    let validated;
    if (mangleCache !== undefined) {
      validated = /* @__PURE__ */ Object.create(null);
      for (let key in mangleCache) {
        let value = mangleCache[key];
        if (typeof value === "string" || value === false) {
          validated[key] = value;
        } else {
          throw new Error(`Expected ${quote(key)} in mangle cache to map to either a string or false`);
        }
      }
    }
    return validated;
  }
  function pushLogFlags(flags, options, keys, isTTY2, logLevelDefault) {
    let color = getFlag(options, keys, "color", mustBeBoolean);
    let logLevel = getFlag(options, keys, "logLevel", mustBeString);
    let logLimit = getFlag(options, keys, "logLimit", mustBeInteger);
    if (color !== undefined)
      flags.push(`--color=${color}`);
    else if (isTTY2)
      flags.push(`--color=true`);
    flags.push(`--log-level=${logLevel || logLevelDefault}`);
    flags.push(`--log-limit=${logLimit || 0}`);
  }
  function validateStringValue(value, what, key) {
    if (typeof value !== "string") {
      throw new Error(`Expected value for ${what}${key !== undefined ? " " + quote(key) : ""} to be a string, got ${typeof value} instead`);
    }
    return value;
  }
  function pushCommonFlags(flags, options, keys) {
    let legalComments = getFlag(options, keys, "legalComments", mustBeString);
    let sourceRoot = getFlag(options, keys, "sourceRoot", mustBeString);
    let sourcesContent = getFlag(options, keys, "sourcesContent", mustBeBoolean);
    let target = getFlag(options, keys, "target", mustBeStringOrArrayOfStrings);
    let format3 = getFlag(options, keys, "format", mustBeString);
    let globalName = getFlag(options, keys, "globalName", mustBeString);
    let mangleProps = getFlag(options, keys, "mangleProps", mustBeRegExp);
    let reserveProps = getFlag(options, keys, "reserveProps", mustBeRegExp);
    let mangleQuoted = getFlag(options, keys, "mangleQuoted", mustBeBoolean);
    let minify = getFlag(options, keys, "minify", mustBeBoolean);
    let minifySyntax = getFlag(options, keys, "minifySyntax", mustBeBoolean);
    let minifyWhitespace = getFlag(options, keys, "minifyWhitespace", mustBeBoolean);
    let minifyIdentifiers = getFlag(options, keys, "minifyIdentifiers", mustBeBoolean);
    let lineLimit = getFlag(options, keys, "lineLimit", mustBeInteger);
    let drop = getFlag(options, keys, "drop", mustBeArrayOfStrings);
    let dropLabels = getFlag(options, keys, "dropLabels", mustBeArrayOfStrings);
    let charset = getFlag(options, keys, "charset", mustBeString);
    let treeShaking = getFlag(options, keys, "treeShaking", mustBeBoolean);
    let ignoreAnnotations = getFlag(options, keys, "ignoreAnnotations", mustBeBoolean);
    let jsx = getFlag(options, keys, "jsx", mustBeString);
    let jsxFactory = getFlag(options, keys, "jsxFactory", mustBeString);
    let jsxFragment = getFlag(options, keys, "jsxFragment", mustBeString);
    let jsxImportSource = getFlag(options, keys, "jsxImportSource", mustBeString);
    let jsxDev = getFlag(options, keys, "jsxDev", mustBeBoolean);
    let jsxSideEffects = getFlag(options, keys, "jsxSideEffects", mustBeBoolean);
    let define = getFlag(options, keys, "define", mustBeObject);
    let logOverride = getFlag(options, keys, "logOverride", mustBeObject);
    let supported = getFlag(options, keys, "supported", mustBeObject);
    let pure = getFlag(options, keys, "pure", mustBeArrayOfStrings);
    let keepNames = getFlag(options, keys, "keepNames", mustBeBoolean);
    let platform = getFlag(options, keys, "platform", mustBeString);
    let tsconfigRaw = getFlag(options, keys, "tsconfigRaw", mustBeStringOrObject);
    let absPaths = getFlag(options, keys, "absPaths", mustBeArrayOfStrings);
    if (legalComments)
      flags.push(`--legal-comments=${legalComments}`);
    if (sourceRoot !== undefined)
      flags.push(`--source-root=${sourceRoot}`);
    if (sourcesContent !== undefined)
      flags.push(`--sources-content=${sourcesContent}`);
    if (target)
      flags.push(`--target=${validateAndJoinStringArray(Array.isArray(target) ? target : [target], "target")}`);
    if (format3)
      flags.push(`--format=${format3}`);
    if (globalName)
      flags.push(`--global-name=${globalName}`);
    if (platform)
      flags.push(`--platform=${platform}`);
    if (tsconfigRaw)
      flags.push(`--tsconfig-raw=${typeof tsconfigRaw === "string" ? tsconfigRaw : JSON.stringify(tsconfigRaw)}`);
    if (minify)
      flags.push("--minify");
    if (minifySyntax)
      flags.push("--minify-syntax");
    if (minifyWhitespace)
      flags.push("--minify-whitespace");
    if (minifyIdentifiers)
      flags.push("--minify-identifiers");
    if (lineLimit)
      flags.push(`--line-limit=${lineLimit}`);
    if (charset)
      flags.push(`--charset=${charset}`);
    if (treeShaking !== undefined)
      flags.push(`--tree-shaking=${treeShaking}`);
    if (ignoreAnnotations)
      flags.push(`--ignore-annotations`);
    if (drop)
      for (let what of drop)
        flags.push(`--drop:${validateStringValue(what, "drop")}`);
    if (dropLabels)
      flags.push(`--drop-labels=${validateAndJoinStringArray(dropLabels, "drop label")}`);
    if (absPaths)
      flags.push(`--abs-paths=${validateAndJoinStringArray(absPaths, "abs paths")}`);
    if (mangleProps)
      flags.push(`--mangle-props=${jsRegExpToGoRegExp(mangleProps)}`);
    if (reserveProps)
      flags.push(`--reserve-props=${jsRegExpToGoRegExp(reserveProps)}`);
    if (mangleQuoted !== undefined)
      flags.push(`--mangle-quoted=${mangleQuoted}`);
    if (jsx)
      flags.push(`--jsx=${jsx}`);
    if (jsxFactory)
      flags.push(`--jsx-factory=${jsxFactory}`);
    if (jsxFragment)
      flags.push(`--jsx-fragment=${jsxFragment}`);
    if (jsxImportSource)
      flags.push(`--jsx-import-source=${jsxImportSource}`);
    if (jsxDev)
      flags.push(`--jsx-dev`);
    if (jsxSideEffects)
      flags.push(`--jsx-side-effects`);
    if (define) {
      for (let key in define) {
        if (key.indexOf("=") >= 0)
          throw new Error(`Invalid define: ${key}`);
        flags.push(`--define:${key}=${validateStringValue(define[key], "define", key)}`);
      }
    }
    if (logOverride) {
      for (let key in logOverride) {
        if (key.indexOf("=") >= 0)
          throw new Error(`Invalid log override: ${key}`);
        flags.push(`--log-override:${key}=${validateStringValue(logOverride[key], "log override", key)}`);
      }
    }
    if (supported) {
      for (let key in supported) {
        if (key.indexOf("=") >= 0)
          throw new Error(`Invalid supported: ${key}`);
        const value = supported[key];
        if (typeof value !== "boolean")
          throw new Error(`Expected value for supported ${quote(key)} to be a boolean, got ${typeof value} instead`);
        flags.push(`--supported:${key}=${value}`);
      }
    }
    if (pure)
      for (let fn of pure)
        flags.push(`--pure:${validateStringValue(fn, "pure")}`);
    if (keepNames)
      flags.push(`--keep-names`);
  }
  function flagsForBuildOptions(callName, options, isTTY2, logLevelDefault, writeDefault) {
    var _a22;
    let flags = [];
    let entries = [];
    let keys = /* @__PURE__ */ Object.create(null);
    let stdinContents = null;
    let stdinResolveDir = null;
    pushLogFlags(flags, options, keys, isTTY2, logLevelDefault);
    pushCommonFlags(flags, options, keys);
    let sourcemap = getFlag(options, keys, "sourcemap", mustBeStringOrBoolean);
    let bundle = getFlag(options, keys, "bundle", mustBeBoolean);
    let splitting = getFlag(options, keys, "splitting", mustBeBoolean);
    let preserveSymlinks = getFlag(options, keys, "preserveSymlinks", mustBeBoolean);
    let metafile = getFlag(options, keys, "metafile", mustBeBoolean);
    let outfile = getFlag(options, keys, "outfile", mustBeString);
    let outdir = getFlag(options, keys, "outdir", mustBeString);
    let outbase = getFlag(options, keys, "outbase", mustBeString);
    let tsconfig = getFlag(options, keys, "tsconfig", mustBeString);
    let resolveExtensions = getFlag(options, keys, "resolveExtensions", mustBeArrayOfStrings);
    let nodePathsInput = getFlag(options, keys, "nodePaths", mustBeArrayOfStrings);
    let mainFields = getFlag(options, keys, "mainFields", mustBeArrayOfStrings);
    let conditions = getFlag(options, keys, "conditions", mustBeArrayOfStrings);
    let external = getFlag(options, keys, "external", mustBeArrayOfStrings);
    let packages = getFlag(options, keys, "packages", mustBeString);
    let alias = getFlag(options, keys, "alias", mustBeObject);
    let loader = getFlag(options, keys, "loader", mustBeObject);
    let outExtension = getFlag(options, keys, "outExtension", mustBeObject);
    let publicPath = getFlag(options, keys, "publicPath", mustBeString);
    let entryNames = getFlag(options, keys, "entryNames", mustBeString);
    let chunkNames = getFlag(options, keys, "chunkNames", mustBeString);
    let assetNames = getFlag(options, keys, "assetNames", mustBeString);
    let inject = getFlag(options, keys, "inject", mustBeArrayOfStrings);
    let banner = getFlag(options, keys, "banner", mustBeObject);
    let footer = getFlag(options, keys, "footer", mustBeObject);
    let entryPoints = getFlag(options, keys, "entryPoints", mustBeEntryPoints);
    let absWorkingDir = getFlag(options, keys, "absWorkingDir", mustBeString);
    let stdin = getFlag(options, keys, "stdin", mustBeObject);
    let write = (_a22 = getFlag(options, keys, "write", mustBeBoolean)) != null ? _a22 : writeDefault;
    let allowOverwrite = getFlag(options, keys, "allowOverwrite", mustBeBoolean);
    let mangleCache = getFlag(options, keys, "mangleCache", mustBeObject);
    keys.plugins = true;
    checkForInvalidFlags(options, keys, `in ${callName}() call`);
    if (sourcemap)
      flags.push(`--sourcemap${sourcemap === true ? "" : `=${sourcemap}`}`);
    if (bundle)
      flags.push("--bundle");
    if (allowOverwrite)
      flags.push("--allow-overwrite");
    if (splitting)
      flags.push("--splitting");
    if (preserveSymlinks)
      flags.push("--preserve-symlinks");
    if (metafile)
      flags.push(`--metafile`);
    if (outfile)
      flags.push(`--outfile=${outfile}`);
    if (outdir)
      flags.push(`--outdir=${outdir}`);
    if (outbase)
      flags.push(`--outbase=${outbase}`);
    if (tsconfig)
      flags.push(`--tsconfig=${tsconfig}`);
    if (packages)
      flags.push(`--packages=${packages}`);
    if (resolveExtensions)
      flags.push(`--resolve-extensions=${validateAndJoinStringArray(resolveExtensions, "resolve extension")}`);
    if (publicPath)
      flags.push(`--public-path=${publicPath}`);
    if (entryNames)
      flags.push(`--entry-names=${entryNames}`);
    if (chunkNames)
      flags.push(`--chunk-names=${chunkNames}`);
    if (assetNames)
      flags.push(`--asset-names=${assetNames}`);
    if (mainFields)
      flags.push(`--main-fields=${validateAndJoinStringArray(mainFields, "main field")}`);
    if (conditions)
      flags.push(`--conditions=${validateAndJoinStringArray(conditions, "condition")}`);
    if (external)
      for (let name of external)
        flags.push(`--external:${validateStringValue(name, "external")}`);
    if (alias) {
      for (let old in alias) {
        if (old.indexOf("=") >= 0)
          throw new Error(`Invalid package name in alias: ${old}`);
        flags.push(`--alias:${old}=${validateStringValue(alias[old], "alias", old)}`);
      }
    }
    if (banner) {
      for (let type in banner) {
        if (type.indexOf("=") >= 0)
          throw new Error(`Invalid banner file type: ${type}`);
        flags.push(`--banner:${type}=${validateStringValue(banner[type], "banner", type)}`);
      }
    }
    if (footer) {
      for (let type in footer) {
        if (type.indexOf("=") >= 0)
          throw new Error(`Invalid footer file type: ${type}`);
        flags.push(`--footer:${type}=${validateStringValue(footer[type], "footer", type)}`);
      }
    }
    if (inject)
      for (let path32 of inject)
        flags.push(`--inject:${validateStringValue(path32, "inject")}`);
    if (loader) {
      for (let ext in loader) {
        if (ext.indexOf("=") >= 0)
          throw new Error(`Invalid loader extension: ${ext}`);
        flags.push(`--loader:${ext}=${validateStringValue(loader[ext], "loader", ext)}`);
      }
    }
    if (outExtension) {
      for (let ext in outExtension) {
        if (ext.indexOf("=") >= 0)
          throw new Error(`Invalid out extension: ${ext}`);
        flags.push(`--out-extension:${ext}=${validateStringValue(outExtension[ext], "out extension", ext)}`);
      }
    }
    if (entryPoints) {
      if (Array.isArray(entryPoints)) {
        for (let i = 0, n = entryPoints.length;i < n; i++) {
          let entryPoint = entryPoints[i];
          if (typeof entryPoint === "object" && entryPoint !== null) {
            let entryPointKeys = /* @__PURE__ */ Object.create(null);
            let input = getFlag(entryPoint, entryPointKeys, "in", mustBeString);
            let output = getFlag(entryPoint, entryPointKeys, "out", mustBeString);
            checkForInvalidFlags(entryPoint, entryPointKeys, "in entry point at index " + i);
            if (input === undefined)
              throw new Error('Missing property "in" for entry point at index ' + i);
            if (output === undefined)
              throw new Error('Missing property "out" for entry point at index ' + i);
            entries.push([output, input]);
          } else {
            entries.push(["", validateStringValue(entryPoint, "entry point at index " + i)]);
          }
        }
      } else {
        for (let key in entryPoints) {
          entries.push([key, validateStringValue(entryPoints[key], "entry point", key)]);
        }
      }
    }
    if (stdin) {
      let stdinKeys = /* @__PURE__ */ Object.create(null);
      let contents = getFlag(stdin, stdinKeys, "contents", mustBeStringOrUint8Array);
      let resolveDir = getFlag(stdin, stdinKeys, "resolveDir", mustBeString);
      let sourcefile = getFlag(stdin, stdinKeys, "sourcefile", mustBeString);
      let loader2 = getFlag(stdin, stdinKeys, "loader", mustBeString);
      checkForInvalidFlags(stdin, stdinKeys, 'in "stdin" object');
      if (sourcefile)
        flags.push(`--sourcefile=${sourcefile}`);
      if (loader2)
        flags.push(`--loader=${loader2}`);
      if (resolveDir)
        stdinResolveDir = resolveDir;
      if (typeof contents === "string")
        stdinContents = encodeUTF8(contents);
      else if (contents instanceof Uint8Array)
        stdinContents = contents;
    }
    let nodePaths = [];
    if (nodePathsInput) {
      for (let value of nodePathsInput) {
        value += "";
        nodePaths.push(value);
      }
    }
    return {
      entries,
      flags,
      write,
      stdinContents,
      stdinResolveDir,
      absWorkingDir,
      nodePaths,
      mangleCache: validateMangleCache(mangleCache)
    };
  }
  function flagsForTransformOptions(callName, options, isTTY2, logLevelDefault) {
    let flags = [];
    let keys = /* @__PURE__ */ Object.create(null);
    pushLogFlags(flags, options, keys, isTTY2, logLevelDefault);
    pushCommonFlags(flags, options, keys);
    let sourcemap = getFlag(options, keys, "sourcemap", mustBeStringOrBoolean);
    let sourcefile = getFlag(options, keys, "sourcefile", mustBeString);
    let loader = getFlag(options, keys, "loader", mustBeString);
    let banner = getFlag(options, keys, "banner", mustBeString);
    let footer = getFlag(options, keys, "footer", mustBeString);
    let mangleCache = getFlag(options, keys, "mangleCache", mustBeObject);
    checkForInvalidFlags(options, keys, `in ${callName}() call`);
    if (sourcemap)
      flags.push(`--sourcemap=${sourcemap === true ? "external" : sourcemap}`);
    if (sourcefile)
      flags.push(`--sourcefile=${sourcefile}`);
    if (loader)
      flags.push(`--loader=${loader}`);
    if (banner)
      flags.push(`--banner=${banner}`);
    if (footer)
      flags.push(`--footer=${footer}`);
    return {
      flags,
      mangleCache: validateMangleCache(mangleCache)
    };
  }
  function createChannel(streamIn) {
    const requestCallbacksByKey = {};
    const closeData = { didClose: false, reason: "" };
    let responseCallbacks = {};
    let nextRequestID = 0;
    let nextBuildKey = 0;
    let stdout = new Uint8Array(16 * 1024);
    let stdoutUsed = 0;
    let readFromStdout = (chunk) => {
      let limit = stdoutUsed + chunk.length;
      if (limit > stdout.length) {
        let swap = new Uint8Array(limit * 2);
        swap.set(stdout);
        stdout = swap;
      }
      stdout.set(chunk, stdoutUsed);
      stdoutUsed += chunk.length;
      let offset = 0;
      while (offset + 4 <= stdoutUsed) {
        let length = readUInt32LE(stdout, offset);
        if (offset + 4 + length > stdoutUsed) {
          break;
        }
        offset += 4;
        handleIncomingPacket(stdout.subarray(offset, offset + length));
        offset += length;
      }
      if (offset > 0) {
        stdout.copyWithin(0, offset, stdoutUsed);
        stdoutUsed -= offset;
      }
    };
    let afterClose = (error) => {
      closeData.didClose = true;
      if (error)
        closeData.reason = ": " + (error.message || error);
      const text = "The service was stopped" + closeData.reason;
      for (let id in responseCallbacks) {
        responseCallbacks[id](text, null);
      }
      responseCallbacks = {};
    };
    let sendRequest = (refs, value, callback) => {
      if (closeData.didClose)
        return callback("The service is no longer running" + closeData.reason, null);
      let id = nextRequestID++;
      responseCallbacks[id] = (error, response) => {
        try {
          callback(error, response);
        } finally {
          if (refs)
            refs.unref();
        }
      };
      if (refs)
        refs.ref();
      streamIn.writeToStdin(encodePacket({ id, isRequest: true, value }));
    };
    let sendResponse = (id, value) => {
      if (closeData.didClose)
        throw new Error("The service is no longer running" + closeData.reason);
      streamIn.writeToStdin(encodePacket({ id, isRequest: false, value }));
    };
    let handleRequest = async (id, request) => {
      try {
        if (request.command === "ping") {
          sendResponse(id, {});
          return;
        }
        if (typeof request.key === "number") {
          const requestCallbacks = requestCallbacksByKey[request.key];
          if (!requestCallbacks) {
            return;
          }
          const callback = requestCallbacks[request.command];
          if (callback) {
            await callback(id, request);
            return;
          }
        }
        throw new Error(`Invalid command: ` + request.command);
      } catch (e) {
        const errors = [extractErrorMessageV8(e, streamIn, null, undefined, "")];
        try {
          sendResponse(id, { errors });
        } catch {}
      }
    };
    let isFirstPacket = true;
    let handleIncomingPacket = (bytes) => {
      if (isFirstPacket) {
        isFirstPacket = false;
        let binaryVersion = String.fromCharCode(...bytes);
        if (binaryVersion !== "0.27.4") {
          throw new Error(`Cannot start service: Host version "${"0.27.4"}" does not match binary version ${quote(binaryVersion)}`);
        }
        return;
      }
      let packet = decodePacket(bytes);
      if (packet.isRequest) {
        handleRequest(packet.id, packet.value);
      } else {
        let callback = responseCallbacks[packet.id];
        delete responseCallbacks[packet.id];
        if (packet.value.error)
          callback(packet.value.error, {});
        else
          callback(null, packet.value);
      }
    };
    let buildOrContext = ({ callName, refs, options, isTTY: isTTY2, defaultWD: defaultWD2, callback }) => {
      let refCount = 0;
      const buildKey = nextBuildKey++;
      const requestCallbacks = {};
      const buildRefs = {
        ref() {
          if (++refCount === 1) {
            if (refs)
              refs.ref();
          }
        },
        unref() {
          if (--refCount === 0) {
            delete requestCallbacksByKey[buildKey];
            if (refs)
              refs.unref();
          }
        }
      };
      requestCallbacksByKey[buildKey] = requestCallbacks;
      buildRefs.ref();
      buildOrContextImpl(callName, buildKey, sendRequest, sendResponse, buildRefs, streamIn, requestCallbacks, options, isTTY2, defaultWD2, (err, res) => {
        try {
          callback(err, res);
        } finally {
          buildRefs.unref();
        }
      });
    };
    let transform2 = ({ callName, refs, input, options, isTTY: isTTY2, fs: fs3, callback }) => {
      const details = createObjectStash();
      let start = (inputPath) => {
        try {
          if (typeof input !== "string" && !(input instanceof Uint8Array))
            throw new Error('The input to "transform" must be a string or a Uint8Array');
          let {
            flags,
            mangleCache
          } = flagsForTransformOptions(callName, options, isTTY2, transformLogLevelDefault);
          let request = {
            command: "transform",
            flags,
            inputFS: inputPath !== null,
            input: inputPath !== null ? encodeUTF8(inputPath) : typeof input === "string" ? encodeUTF8(input) : input
          };
          if (mangleCache)
            request.mangleCache = mangleCache;
          sendRequest(refs, request, (error, response) => {
            if (error)
              return callback(new Error(error), null);
            let errors = replaceDetailsInMessages(response.errors, details);
            let warnings = replaceDetailsInMessages(response.warnings, details);
            let outstanding = 1;
            let next = () => {
              if (--outstanding === 0) {
                let result = {
                  warnings,
                  code: response.code,
                  map: response.map,
                  mangleCache: undefined,
                  legalComments: undefined
                };
                if ("legalComments" in response)
                  result.legalComments = response == null ? undefined : response.legalComments;
                if (response.mangleCache)
                  result.mangleCache = response == null ? undefined : response.mangleCache;
                callback(null, result);
              }
            };
            if (errors.length > 0)
              return callback(failureErrorWithLog("Transform failed", errors, warnings), null);
            if (response.codeFS) {
              outstanding++;
              fs3.readFile(response.code, (err, contents) => {
                if (err !== null) {
                  callback(err, null);
                } else {
                  response.code = contents;
                  next();
                }
              });
            }
            if (response.mapFS) {
              outstanding++;
              fs3.readFile(response.map, (err, contents) => {
                if (err !== null) {
                  callback(err, null);
                } else {
                  response.map = contents;
                  next();
                }
              });
            }
            next();
          });
        } catch (e) {
          let flags = [];
          try {
            pushLogFlags(flags, options, {}, isTTY2, transformLogLevelDefault);
          } catch {}
          const error = extractErrorMessageV8(e, streamIn, details, undefined, "");
          sendRequest(refs, { command: "error", flags, error }, () => {
            error.detail = details.load(error.detail);
            callback(failureErrorWithLog("Transform failed", [error], []), null);
          });
        }
      };
      if ((typeof input === "string" || input instanceof Uint8Array) && input.length > 1024 * 1024) {
        let next = start;
        start = () => fs3.writeFile(input, next);
      }
      start(null);
    };
    let formatMessages2 = ({ callName, refs, messages, options, callback }) => {
      if (!options)
        throw new Error(`Missing second argument in ${callName}() call`);
      let keys = {};
      let kind = getFlag(options, keys, "kind", mustBeString);
      let color = getFlag(options, keys, "color", mustBeBoolean);
      let terminalWidth = getFlag(options, keys, "terminalWidth", mustBeInteger);
      checkForInvalidFlags(options, keys, `in ${callName}() call`);
      if (kind === undefined)
        throw new Error(`Missing "kind" in ${callName}() call`);
      if (kind !== "error" && kind !== "warning")
        throw new Error(`Expected "kind" to be "error" or "warning" in ${callName}() call`);
      let request = {
        command: "format-msgs",
        messages: sanitizeMessages(messages, "messages", null, "", terminalWidth),
        isWarning: kind === "warning"
      };
      if (color !== undefined)
        request.color = color;
      if (terminalWidth !== undefined)
        request.terminalWidth = terminalWidth;
      sendRequest(refs, request, (error, response) => {
        if (error)
          return callback(new Error(error), null);
        callback(null, response.messages);
      });
    };
    let analyzeMetafile2 = ({ callName, refs, metafile, options, callback }) => {
      if (options === undefined)
        options = {};
      let keys = {};
      let color = getFlag(options, keys, "color", mustBeBoolean);
      let verbose = getFlag(options, keys, "verbose", mustBeBoolean);
      checkForInvalidFlags(options, keys, `in ${callName}() call`);
      let request = {
        command: "analyze-metafile",
        metafile
      };
      if (color !== undefined)
        request.color = color;
      if (verbose !== undefined)
        request.verbose = verbose;
      sendRequest(refs, request, (error, response) => {
        if (error)
          return callback(new Error(error), null);
        callback(null, response.result);
      });
    };
    return {
      readFromStdout,
      afterClose,
      service: {
        buildOrContext,
        transform: transform2,
        formatMessages: formatMessages2,
        analyzeMetafile: analyzeMetafile2
      }
    };
  }
  function buildOrContextImpl(callName, buildKey, sendRequest, sendResponse, refs, streamIn, requestCallbacks, options, isTTY2, defaultWD2, callback) {
    const details = createObjectStash();
    const isContext = callName === "context";
    const handleError = (e, pluginName) => {
      const flags = [];
      try {
        pushLogFlags(flags, options, {}, isTTY2, buildLogLevelDefault);
      } catch {}
      const message = extractErrorMessageV8(e, streamIn, details, undefined, pluginName);
      sendRequest(refs, { command: "error", flags, error: message }, () => {
        message.detail = details.load(message.detail);
        callback(failureErrorWithLog(isContext ? "Context failed" : "Build failed", [message], []), null);
      });
    };
    let plugins;
    if (typeof options === "object") {
      const value = options.plugins;
      if (value !== undefined) {
        if (!Array.isArray(value))
          return handleError(new Error(`"plugins" must be an array`), "");
        plugins = value;
      }
    }
    if (plugins && plugins.length > 0) {
      if (streamIn.isSync)
        return handleError(new Error("Cannot use plugins in synchronous API calls"), "");
      handlePlugins(buildKey, sendRequest, sendResponse, refs, streamIn, requestCallbacks, options, plugins, details).then((result) => {
        if (!result.ok)
          return handleError(result.error, result.pluginName);
        try {
          buildOrContextContinue(result.requestPlugins, result.runOnEndCallbacks, result.scheduleOnDisposeCallbacks);
        } catch (e) {
          handleError(e, "");
        }
      }, (e) => handleError(e, ""));
      return;
    }
    try {
      buildOrContextContinue(null, (result, done) => done([], []), () => {});
    } catch (e) {
      handleError(e, "");
    }
    function buildOrContextContinue(requestPlugins, runOnEndCallbacks, scheduleOnDisposeCallbacks) {
      const writeDefault = streamIn.hasFS;
      const {
        entries,
        flags,
        write,
        stdinContents,
        stdinResolveDir,
        absWorkingDir,
        nodePaths,
        mangleCache
      } = flagsForBuildOptions(callName, options, isTTY2, buildLogLevelDefault, writeDefault);
      if (write && !streamIn.hasFS)
        throw new Error(`The "write" option is unavailable in this environment`);
      const request = {
        command: "build",
        key: buildKey,
        entries,
        flags,
        write,
        stdinContents,
        stdinResolveDir,
        absWorkingDir: absWorkingDir || defaultWD2,
        nodePaths,
        context: isContext
      };
      if (requestPlugins)
        request.plugins = requestPlugins;
      if (mangleCache)
        request.mangleCache = mangleCache;
      const buildResponseToResult = (response, callback2) => {
        const result = {
          errors: replaceDetailsInMessages(response.errors, details),
          warnings: replaceDetailsInMessages(response.warnings, details),
          outputFiles: undefined,
          metafile: undefined,
          mangleCache: undefined
        };
        const originalErrors = result.errors.slice();
        const originalWarnings = result.warnings.slice();
        if (response.outputFiles)
          result.outputFiles = response.outputFiles.map(convertOutputFiles);
        if (response.metafile)
          result.metafile = parseJSON(response.metafile);
        if (response.mangleCache)
          result.mangleCache = response.mangleCache;
        if (response.writeToStdout !== undefined)
          console.log(decodeUTF8(response.writeToStdout).replace(/\n$/, ""));
        runOnEndCallbacks(result, (onEndErrors, onEndWarnings) => {
          if (originalErrors.length > 0 || onEndErrors.length > 0) {
            const error = failureErrorWithLog("Build failed", originalErrors.concat(onEndErrors), originalWarnings.concat(onEndWarnings));
            return callback2(error, null, onEndErrors, onEndWarnings);
          }
          callback2(null, result, onEndErrors, onEndWarnings);
        });
      };
      let latestResultPromise;
      let provideLatestResult;
      if (isContext)
        requestCallbacks["on-end"] = (id, request2) => new Promise((resolve5) => {
          buildResponseToResult(request2, (err, result, onEndErrors, onEndWarnings) => {
            const response = {
              errors: onEndErrors,
              warnings: onEndWarnings
            };
            if (provideLatestResult)
              provideLatestResult(err, result);
            latestResultPromise = undefined;
            provideLatestResult = undefined;
            sendResponse(id, response);
            resolve5();
          });
        });
      sendRequest(refs, request, (error, response) => {
        if (error)
          return callback(new Error(error), null);
        if (!isContext) {
          return buildResponseToResult(response, (err, res) => {
            scheduleOnDisposeCallbacks();
            return callback(err, res);
          });
        }
        if (response.errors.length > 0) {
          return callback(failureErrorWithLog("Context failed", response.errors, response.warnings), null);
        }
        let didDispose = false;
        const result = {
          rebuild: () => {
            if (!latestResultPromise)
              latestResultPromise = new Promise((resolve5, reject) => {
                let settlePromise;
                provideLatestResult = (err, result2) => {
                  if (!settlePromise)
                    settlePromise = () => err ? reject(err) : resolve5(result2);
                };
                const triggerAnotherBuild = () => {
                  const request2 = {
                    command: "rebuild",
                    key: buildKey
                  };
                  sendRequest(refs, request2, (error2, response2) => {
                    if (error2) {
                      reject(new Error(error2));
                    } else if (settlePromise) {
                      settlePromise();
                    } else {
                      triggerAnotherBuild();
                    }
                  });
                };
                triggerAnotherBuild();
              });
            return latestResultPromise;
          },
          watch: (options2 = {}) => new Promise((resolve5, reject) => {
            if (!streamIn.hasFS)
              throw new Error(`Cannot use the "watch" API in this environment`);
            const keys = {};
            const delay = getFlag(options2, keys, "delay", mustBeInteger);
            checkForInvalidFlags(options2, keys, `in watch() call`);
            const request2 = {
              command: "watch",
              key: buildKey
            };
            if (delay)
              request2.delay = delay;
            sendRequest(refs, request2, (error2) => {
              if (error2)
                reject(new Error(error2));
              else
                resolve5(undefined);
            });
          }),
          serve: (options2 = {}) => new Promise((resolve5, reject) => {
            if (!streamIn.hasFS)
              throw new Error(`Cannot use the "serve" API in this environment`);
            const keys = {};
            const port = getFlag(options2, keys, "port", mustBeValidPortNumber);
            const host = getFlag(options2, keys, "host", mustBeString);
            const servedir = getFlag(options2, keys, "servedir", mustBeString);
            const keyfile = getFlag(options2, keys, "keyfile", mustBeString);
            const certfile = getFlag(options2, keys, "certfile", mustBeString);
            const fallback = getFlag(options2, keys, "fallback", mustBeString);
            const cors = getFlag(options2, keys, "cors", mustBeObject);
            const onRequest = getFlag(options2, keys, "onRequest", mustBeFunction);
            checkForInvalidFlags(options2, keys, `in serve() call`);
            const request2 = {
              command: "serve",
              key: buildKey,
              onRequest: !!onRequest
            };
            if (port !== undefined)
              request2.port = port;
            if (host !== undefined)
              request2.host = host;
            if (servedir !== undefined)
              request2.servedir = servedir;
            if (keyfile !== undefined)
              request2.keyfile = keyfile;
            if (certfile !== undefined)
              request2.certfile = certfile;
            if (fallback !== undefined)
              request2.fallback = fallback;
            if (cors) {
              const corsKeys = {};
              const origin = getFlag(cors, corsKeys, "origin", mustBeStringOrArrayOfStrings);
              checkForInvalidFlags(cors, corsKeys, `on "cors" object`);
              if (Array.isArray(origin))
                request2.corsOrigin = origin;
              else if (origin !== undefined)
                request2.corsOrigin = [origin];
            }
            sendRequest(refs, request2, (error2, response2) => {
              if (error2)
                return reject(new Error(error2));
              if (onRequest) {
                requestCallbacks["serve-request"] = (id, request3) => {
                  onRequest(request3.args);
                  sendResponse(id, {});
                };
              }
              resolve5(response2);
            });
          }),
          cancel: () => new Promise((resolve5) => {
            if (didDispose)
              return resolve5();
            const request2 = {
              command: "cancel",
              key: buildKey
            };
            sendRequest(refs, request2, () => {
              resolve5();
            });
          }),
          dispose: () => new Promise((resolve5) => {
            if (didDispose)
              return resolve5();
            didDispose = true;
            const request2 = {
              command: "dispose",
              key: buildKey
            };
            sendRequest(refs, request2, () => {
              resolve5();
              scheduleOnDisposeCallbacks();
              refs.unref();
            });
          })
        };
        refs.ref();
        callback(null, result);
      });
    }
  }
  var handlePlugins = async (buildKey, sendRequest, sendResponse, refs, streamIn, requestCallbacks, initialOptions, plugins, details) => {
    let onStartCallbacks = [];
    let onEndCallbacks = [];
    let onResolveCallbacks = {};
    let onLoadCallbacks = {};
    let onDisposeCallbacks = [];
    let nextCallbackID = 0;
    let i = 0;
    let requestPlugins = [];
    let isSetupDone = false;
    plugins = [...plugins];
    for (let item of plugins) {
      let keys = {};
      if (typeof item !== "object")
        throw new Error(`Plugin at index ${i} must be an object`);
      const name = getFlag(item, keys, "name", mustBeString);
      if (typeof name !== "string" || name === "")
        throw new Error(`Plugin at index ${i} is missing a name`);
      try {
        let setup = getFlag(item, keys, "setup", mustBeFunction);
        if (typeof setup !== "function")
          throw new Error(`Plugin is missing a setup function`);
        checkForInvalidFlags(item, keys, `on plugin ${quote(name)}`);
        let plugin = {
          name,
          onStart: false,
          onEnd: false,
          onResolve: [],
          onLoad: []
        };
        i++;
        let resolve5 = (path32, options = {}) => {
          if (!isSetupDone)
            throw new Error('Cannot call "resolve" before plugin setup has completed');
          if (typeof path32 !== "string")
            throw new Error(`The path to resolve must be a string`);
          let keys2 = /* @__PURE__ */ Object.create(null);
          let pluginName = getFlag(options, keys2, "pluginName", mustBeString);
          let importer = getFlag(options, keys2, "importer", mustBeString);
          let namespace = getFlag(options, keys2, "namespace", mustBeString);
          let resolveDir = getFlag(options, keys2, "resolveDir", mustBeString);
          let kind = getFlag(options, keys2, "kind", mustBeString);
          let pluginData = getFlag(options, keys2, "pluginData", canBeAnything);
          let importAttributes = getFlag(options, keys2, "with", mustBeObject);
          checkForInvalidFlags(options, keys2, "in resolve() call");
          return new Promise((resolve22, reject) => {
            const request = {
              command: "resolve",
              path: path32,
              key: buildKey,
              pluginName: name
            };
            if (pluginName != null)
              request.pluginName = pluginName;
            if (importer != null)
              request.importer = importer;
            if (namespace != null)
              request.namespace = namespace;
            if (resolveDir != null)
              request.resolveDir = resolveDir;
            if (kind != null)
              request.kind = kind;
            else
              throw new Error(`Must specify "kind" when calling "resolve"`);
            if (pluginData != null)
              request.pluginData = details.store(pluginData);
            if (importAttributes != null)
              request.with = sanitizeStringMap(importAttributes, "with");
            sendRequest(refs, request, (error, response) => {
              if (error !== null)
                reject(new Error(error));
              else
                resolve22({
                  errors: replaceDetailsInMessages(response.errors, details),
                  warnings: replaceDetailsInMessages(response.warnings, details),
                  path: response.path,
                  external: response.external,
                  sideEffects: response.sideEffects,
                  namespace: response.namespace,
                  suffix: response.suffix,
                  pluginData: details.load(response.pluginData)
                });
            });
          });
        };
        let promise = setup({
          initialOptions,
          resolve: resolve5,
          onStart(callback) {
            let registeredText = `This error came from the "onStart" callback registered here:`;
            let registeredNote = extractCallerV8(new Error(registeredText), streamIn, "onStart");
            onStartCallbacks.push({ name, callback, note: registeredNote });
            plugin.onStart = true;
          },
          onEnd(callback) {
            let registeredText = `This error came from the "onEnd" callback registered here:`;
            let registeredNote = extractCallerV8(new Error(registeredText), streamIn, "onEnd");
            onEndCallbacks.push({ name, callback, note: registeredNote });
            plugin.onEnd = true;
          },
          onResolve(options, callback) {
            let registeredText = `This error came from the "onResolve" callback registered here:`;
            let registeredNote = extractCallerV8(new Error(registeredText), streamIn, "onResolve");
            let keys2 = {};
            let filter = getFlag(options, keys2, "filter", mustBeRegExp);
            let namespace = getFlag(options, keys2, "namespace", mustBeString);
            checkForInvalidFlags(options, keys2, `in onResolve() call for plugin ${quote(name)}`);
            if (filter == null)
              throw new Error(`onResolve() call is missing a filter`);
            let id = nextCallbackID++;
            onResolveCallbacks[id] = { name, callback, note: registeredNote };
            plugin.onResolve.push({ id, filter: jsRegExpToGoRegExp(filter), namespace: namespace || "" });
          },
          onLoad(options, callback) {
            let registeredText = `This error came from the "onLoad" callback registered here:`;
            let registeredNote = extractCallerV8(new Error(registeredText), streamIn, "onLoad");
            let keys2 = {};
            let filter = getFlag(options, keys2, "filter", mustBeRegExp);
            let namespace = getFlag(options, keys2, "namespace", mustBeString);
            checkForInvalidFlags(options, keys2, `in onLoad() call for plugin ${quote(name)}`);
            if (filter == null)
              throw new Error(`onLoad() call is missing a filter`);
            let id = nextCallbackID++;
            onLoadCallbacks[id] = { name, callback, note: registeredNote };
            plugin.onLoad.push({ id, filter: jsRegExpToGoRegExp(filter), namespace: namespace || "" });
          },
          onDispose(callback) {
            onDisposeCallbacks.push(callback);
          },
          esbuild: streamIn.esbuild
        });
        if (promise)
          await promise;
        requestPlugins.push(plugin);
      } catch (e) {
        return { ok: false, error: e, pluginName: name };
      }
    }
    requestCallbacks["on-start"] = async (id, request) => {
      details.clear();
      let response = { errors: [], warnings: [] };
      await Promise.all(onStartCallbacks.map(async ({ name, callback, note }) => {
        try {
          let result = await callback();
          if (result != null) {
            if (typeof result !== "object")
              throw new Error(`Expected onStart() callback in plugin ${quote(name)} to return an object`);
            let keys = {};
            let errors = getFlag(result, keys, "errors", mustBeArray);
            let warnings = getFlag(result, keys, "warnings", mustBeArray);
            checkForInvalidFlags(result, keys, `from onStart() callback in plugin ${quote(name)}`);
            if (errors != null)
              response.errors.push(...sanitizeMessages(errors, "errors", details, name, undefined));
            if (warnings != null)
              response.warnings.push(...sanitizeMessages(warnings, "warnings", details, name, undefined));
          }
        } catch (e) {
          response.errors.push(extractErrorMessageV8(e, streamIn, details, note && note(), name));
        }
      }));
      sendResponse(id, response);
    };
    requestCallbacks["on-resolve"] = async (id, request) => {
      let response = {}, name = "", callback, note;
      for (let id2 of request.ids) {
        try {
          ({ name, callback, note } = onResolveCallbacks[id2]);
          let result = await callback({
            path: request.path,
            importer: request.importer,
            namespace: request.namespace,
            resolveDir: request.resolveDir,
            kind: request.kind,
            pluginData: details.load(request.pluginData),
            with: request.with
          });
          if (result != null) {
            if (typeof result !== "object")
              throw new Error(`Expected onResolve() callback in plugin ${quote(name)} to return an object`);
            let keys = {};
            let pluginName = getFlag(result, keys, "pluginName", mustBeString);
            let path32 = getFlag(result, keys, "path", mustBeString);
            let namespace = getFlag(result, keys, "namespace", mustBeString);
            let suffix = getFlag(result, keys, "suffix", mustBeString);
            let external = getFlag(result, keys, "external", mustBeBoolean);
            let sideEffects = getFlag(result, keys, "sideEffects", mustBeBoolean);
            let pluginData = getFlag(result, keys, "pluginData", canBeAnything);
            let errors = getFlag(result, keys, "errors", mustBeArray);
            let warnings = getFlag(result, keys, "warnings", mustBeArray);
            let watchFiles = getFlag(result, keys, "watchFiles", mustBeArrayOfStrings);
            let watchDirs = getFlag(result, keys, "watchDirs", mustBeArrayOfStrings);
            checkForInvalidFlags(result, keys, `from onResolve() callback in plugin ${quote(name)}`);
            response.id = id2;
            if (pluginName != null)
              response.pluginName = pluginName;
            if (path32 != null)
              response.path = path32;
            if (namespace != null)
              response.namespace = namespace;
            if (suffix != null)
              response.suffix = suffix;
            if (external != null)
              response.external = external;
            if (sideEffects != null)
              response.sideEffects = sideEffects;
            if (pluginData != null)
              response.pluginData = details.store(pluginData);
            if (errors != null)
              response.errors = sanitizeMessages(errors, "errors", details, name, undefined);
            if (warnings != null)
              response.warnings = sanitizeMessages(warnings, "warnings", details, name, undefined);
            if (watchFiles != null)
              response.watchFiles = sanitizeStringArray(watchFiles, "watchFiles");
            if (watchDirs != null)
              response.watchDirs = sanitizeStringArray(watchDirs, "watchDirs");
            break;
          }
        } catch (e) {
          response = { id: id2, errors: [extractErrorMessageV8(e, streamIn, details, note && note(), name)] };
          break;
        }
      }
      sendResponse(id, response);
    };
    requestCallbacks["on-load"] = async (id, request) => {
      let response = {}, name = "", callback, note;
      for (let id2 of request.ids) {
        try {
          ({ name, callback, note } = onLoadCallbacks[id2]);
          let result = await callback({
            path: request.path,
            namespace: request.namespace,
            suffix: request.suffix,
            pluginData: details.load(request.pluginData),
            with: request.with
          });
          if (result != null) {
            if (typeof result !== "object")
              throw new Error(`Expected onLoad() callback in plugin ${quote(name)} to return an object`);
            let keys = {};
            let pluginName = getFlag(result, keys, "pluginName", mustBeString);
            let contents = getFlag(result, keys, "contents", mustBeStringOrUint8Array);
            let resolveDir = getFlag(result, keys, "resolveDir", mustBeString);
            let pluginData = getFlag(result, keys, "pluginData", canBeAnything);
            let loader = getFlag(result, keys, "loader", mustBeString);
            let errors = getFlag(result, keys, "errors", mustBeArray);
            let warnings = getFlag(result, keys, "warnings", mustBeArray);
            let watchFiles = getFlag(result, keys, "watchFiles", mustBeArrayOfStrings);
            let watchDirs = getFlag(result, keys, "watchDirs", mustBeArrayOfStrings);
            checkForInvalidFlags(result, keys, `from onLoad() callback in plugin ${quote(name)}`);
            response.id = id2;
            if (pluginName != null)
              response.pluginName = pluginName;
            if (contents instanceof Uint8Array)
              response.contents = contents;
            else if (contents != null)
              response.contents = encodeUTF8(contents);
            if (resolveDir != null)
              response.resolveDir = resolveDir;
            if (pluginData != null)
              response.pluginData = details.store(pluginData);
            if (loader != null)
              response.loader = loader;
            if (errors != null)
              response.errors = sanitizeMessages(errors, "errors", details, name, undefined);
            if (warnings != null)
              response.warnings = sanitizeMessages(warnings, "warnings", details, name, undefined);
            if (watchFiles != null)
              response.watchFiles = sanitizeStringArray(watchFiles, "watchFiles");
            if (watchDirs != null)
              response.watchDirs = sanitizeStringArray(watchDirs, "watchDirs");
            break;
          }
        } catch (e) {
          response = { id: id2, errors: [extractErrorMessageV8(e, streamIn, details, note && note(), name)] };
          break;
        }
      }
      sendResponse(id, response);
    };
    let runOnEndCallbacks = (result, done) => done([], []);
    if (onEndCallbacks.length > 0) {
      runOnEndCallbacks = (result, done) => {
        (async () => {
          const onEndErrors = [];
          const onEndWarnings = [];
          for (const { name, callback, note } of onEndCallbacks) {
            let newErrors;
            let newWarnings;
            try {
              const value = await callback(result);
              if (value != null) {
                if (typeof value !== "object")
                  throw new Error(`Expected onEnd() callback in plugin ${quote(name)} to return an object`);
                let keys = {};
                let errors = getFlag(value, keys, "errors", mustBeArray);
                let warnings = getFlag(value, keys, "warnings", mustBeArray);
                checkForInvalidFlags(value, keys, `from onEnd() callback in plugin ${quote(name)}`);
                if (errors != null)
                  newErrors = sanitizeMessages(errors, "errors", details, name, undefined);
                if (warnings != null)
                  newWarnings = sanitizeMessages(warnings, "warnings", details, name, undefined);
              }
            } catch (e) {
              newErrors = [extractErrorMessageV8(e, streamIn, details, note && note(), name)];
            }
            if (newErrors) {
              onEndErrors.push(...newErrors);
              try {
                result.errors.push(...newErrors);
              } catch {}
            }
            if (newWarnings) {
              onEndWarnings.push(...newWarnings);
              try {
                result.warnings.push(...newWarnings);
              } catch {}
            }
          }
          done(onEndErrors, onEndWarnings);
        })();
      };
    }
    let scheduleOnDisposeCallbacks = () => {
      for (const cb of onDisposeCallbacks) {
        setTimeout(() => cb(), 0);
      }
    };
    isSetupDone = true;
    return {
      ok: true,
      requestPlugins,
      runOnEndCallbacks,
      scheduleOnDisposeCallbacks
    };
  };
  function createObjectStash() {
    const map = /* @__PURE__ */ new Map;
    let nextID = 0;
    return {
      clear() {
        map.clear();
      },
      load(id) {
        return map.get(id);
      },
      store(value) {
        if (value === undefined)
          return -1;
        const id = nextID++;
        map.set(id, value);
        return id;
      }
    };
  }
  function extractCallerV8(e, streamIn, ident) {
    let note;
    let tried = false;
    return () => {
      if (tried)
        return note;
      tried = true;
      try {
        let lines = (e.stack + "").split(`
`);
        lines.splice(1, 1);
        let location = parseStackLinesV8(streamIn, lines, ident);
        if (location) {
          note = { text: e.message, location };
          return note;
        }
      } catch {}
    };
  }
  function extractErrorMessageV8(e, streamIn, stash, note, pluginName) {
    let text = "Internal error";
    let location = null;
    try {
      text = (e && e.message || e) + "";
    } catch {}
    try {
      location = parseStackLinesV8(streamIn, (e.stack + "").split(`
`), "");
    } catch {}
    return { id: "", pluginName, text, location, notes: note ? [note] : [], detail: stash ? stash.store(e) : -1 };
  }
  function parseStackLinesV8(streamIn, lines, ident) {
    let at = "    at ";
    if (streamIn.readFileSync && !lines[0].startsWith(at) && lines[1].startsWith(at)) {
      for (let i = 1;i < lines.length; i++) {
        let line = lines[i];
        if (!line.startsWith(at))
          continue;
        line = line.slice(at.length);
        while (true) {
          let match = /^(?:new |async )?\S+ \((.*)\)$/.exec(line);
          if (match) {
            line = match[1];
            continue;
          }
          match = /^eval at \S+ \((.*)\)(?:, \S+:\d+:\d+)?$/.exec(line);
          if (match) {
            line = match[1];
            continue;
          }
          match = /^(\S+):(\d+):(\d+)$/.exec(line);
          if (match) {
            let contents;
            try {
              contents = streamIn.readFileSync(match[1], "utf8");
            } catch {
              break;
            }
            let lineText = contents.split(/\r\n|\r|\n|\u2028|\u2029/)[+match[2] - 1] || "";
            let column = +match[3] - 1;
            let length = lineText.slice(column, column + ident.length) === ident ? ident.length : 0;
            return {
              file: match[1],
              namespace: "file",
              line: +match[2],
              column: encodeUTF8(lineText.slice(0, column)).length,
              length: encodeUTF8(lineText.slice(column, column + length)).length,
              lineText: lineText + `
` + lines.slice(1).join(`
`),
              suggestion: ""
            };
          }
          break;
        }
      }
    }
    return null;
  }
  function failureErrorWithLog(text, errors, warnings) {
    let limit = 5;
    text += errors.length < 1 ? "" : ` with ${errors.length} error${errors.length < 2 ? "" : "s"}:` + errors.slice(0, limit + 1).map((e, i) => {
      if (i === limit)
        return `
...`;
      if (!e.location)
        return `
error: ${e.text}`;
      let { file, line, column } = e.location;
      let pluginText = e.pluginName ? `[plugin: ${e.pluginName}] ` : "";
      return `
${file}:${line}:${column}: ERROR: ${pluginText}${e.text}`;
    }).join("");
    let error = new Error(text);
    for (const [key, value] of [["errors", errors], ["warnings", warnings]]) {
      Object.defineProperty(error, key, {
        configurable: true,
        enumerable: true,
        get: () => value,
        set: (value2) => Object.defineProperty(error, key, {
          configurable: true,
          enumerable: true,
          value: value2
        })
      });
    }
    return error;
  }
  function replaceDetailsInMessages(messages, stash) {
    for (const message of messages) {
      message.detail = stash.load(message.detail);
    }
    return messages;
  }
  function sanitizeLocation(location, where, terminalWidth) {
    if (location == null)
      return null;
    let keys = {};
    let file = getFlag(location, keys, "file", mustBeString);
    let namespace = getFlag(location, keys, "namespace", mustBeString);
    let line = getFlag(location, keys, "line", mustBeInteger);
    let column = getFlag(location, keys, "column", mustBeInteger);
    let length = getFlag(location, keys, "length", mustBeInteger);
    let lineText = getFlag(location, keys, "lineText", mustBeString);
    let suggestion = getFlag(location, keys, "suggestion", mustBeString);
    checkForInvalidFlags(location, keys, where);
    if (lineText) {
      const relevantASCII = lineText.slice(0, (column && column > 0 ? column : 0) + (length && length > 0 ? length : 0) + (terminalWidth && terminalWidth > 0 ? terminalWidth : 80));
      if (!/[\x7F-\uFFFF]/.test(relevantASCII) && !/\n/.test(lineText)) {
        lineText = relevantASCII;
      }
    }
    return {
      file: file || "",
      namespace: namespace || "",
      line: line || 0,
      column: column || 0,
      length: length || 0,
      lineText: lineText || "",
      suggestion: suggestion || ""
    };
  }
  function sanitizeMessages(messages, property, stash, fallbackPluginName, terminalWidth) {
    let messagesClone = [];
    let index = 0;
    for (const message of messages) {
      let keys = {};
      let id = getFlag(message, keys, "id", mustBeString);
      let pluginName = getFlag(message, keys, "pluginName", mustBeString);
      let text = getFlag(message, keys, "text", mustBeString);
      let location = getFlag(message, keys, "location", mustBeObjectOrNull);
      let notes = getFlag(message, keys, "notes", mustBeArray);
      let detail = getFlag(message, keys, "detail", canBeAnything);
      let where = `in element ${index} of "${property}"`;
      checkForInvalidFlags(message, keys, where);
      let notesClone = [];
      if (notes) {
        for (const note of notes) {
          let noteKeys = {};
          let noteText = getFlag(note, noteKeys, "text", mustBeString);
          let noteLocation = getFlag(note, noteKeys, "location", mustBeObjectOrNull);
          checkForInvalidFlags(note, noteKeys, where);
          notesClone.push({
            text: noteText || "",
            location: sanitizeLocation(noteLocation, where, terminalWidth)
          });
        }
      }
      messagesClone.push({
        id: id || "",
        pluginName: pluginName || fallbackPluginName,
        text: text || "",
        location: sanitizeLocation(location, where, terminalWidth),
        notes: notesClone,
        detail: stash ? stash.store(detail) : -1
      });
      index++;
    }
    return messagesClone;
  }
  function sanitizeStringArray(values, property) {
    const result = [];
    for (const value of values) {
      if (typeof value !== "string")
        throw new Error(`${quote(property)} must be an array of strings`);
      result.push(value);
    }
    return result;
  }
  function sanitizeStringMap(map, property) {
    const result = /* @__PURE__ */ Object.create(null);
    for (const key in map) {
      const value = map[key];
      if (typeof value !== "string")
        throw new Error(`key ${quote(key)} in object ${quote(property)} must be a string`);
      result[key] = value;
    }
    return result;
  }
  function convertOutputFiles({ path: path32, contents, hash }) {
    let text = null;
    return {
      path: path32,
      contents,
      hash,
      get text() {
        const binary = this.contents;
        if (text === null || binary !== contents) {
          contents = binary;
          text = decodeUTF8(binary);
        }
        return text;
      }
    };
  }
  function jsRegExpToGoRegExp(regexp) {
    let result = regexp.source;
    if (regexp.flags)
      result = `(?${regexp.flags})${result}`;
    return result;
  }
  function parseJSON(bytes) {
    let text;
    try {
      text = decodeUTF8(bytes);
    } catch {
      return JSON_parse(bytes);
    }
    return JSON.parse(text);
  }
  var fs = __require("fs");
  var os = __require("os");
  var path3 = __require("path");
  var ESBUILD_BINARY_PATH = process.env.ESBUILD_BINARY_PATH || ESBUILD_BINARY_PATH;
  var isValidBinaryPath = (x) => !!x && x !== "/usr/bin/esbuild";
  var packageDarwin_arm64 = "@esbuild/darwin-arm64";
  var packageDarwin_x64 = "@esbuild/darwin-x64";
  var knownWindowsPackages = {
    "win32 arm64 LE": "@esbuild/win32-arm64",
    "win32 ia32 LE": "@esbuild/win32-ia32",
    "win32 x64 LE": "@esbuild/win32-x64"
  };
  var knownUnixlikePackages = {
    "aix ppc64 BE": "@esbuild/aix-ppc64",
    "android arm64 LE": "@esbuild/android-arm64",
    "darwin arm64 LE": "@esbuild/darwin-arm64",
    "darwin x64 LE": "@esbuild/darwin-x64",
    "freebsd arm64 LE": "@esbuild/freebsd-arm64",
    "freebsd x64 LE": "@esbuild/freebsd-x64",
    "linux arm LE": "@esbuild/linux-arm",
    "linux arm64 LE": "@esbuild/linux-arm64",
    "linux ia32 LE": "@esbuild/linux-ia32",
    "linux mips64el LE": "@esbuild/linux-mips64el",
    "linux ppc64 LE": "@esbuild/linux-ppc64",
    "linux riscv64 LE": "@esbuild/linux-riscv64",
    "linux s390x BE": "@esbuild/linux-s390x",
    "linux x64 LE": "@esbuild/linux-x64",
    "linux loong64 LE": "@esbuild/linux-loong64",
    "netbsd arm64 LE": "@esbuild/netbsd-arm64",
    "netbsd x64 LE": "@esbuild/netbsd-x64",
    "openbsd arm64 LE": "@esbuild/openbsd-arm64",
    "openbsd x64 LE": "@esbuild/openbsd-x64",
    "sunos x64 LE": "@esbuild/sunos-x64"
  };
  var knownWebAssemblyFallbackPackages = {
    "android arm LE": "@esbuild/android-arm",
    "android x64 LE": "@esbuild/android-x64",
    "openharmony arm64 LE": "@esbuild/openharmony-arm64"
  };
  function pkgAndSubpathForCurrentPlatform() {
    let pkg;
    let subpath;
    let isWASM = false;
    let platformKey = `${process.platform} ${os.arch()} ${os.endianness()}`;
    if (platformKey in knownWindowsPackages) {
      pkg = knownWindowsPackages[platformKey];
      subpath = "esbuild.exe";
    } else if (platformKey in knownUnixlikePackages) {
      pkg = knownUnixlikePackages[platformKey];
      subpath = "bin/esbuild";
    } else if (platformKey in knownWebAssemblyFallbackPackages) {
      pkg = knownWebAssemblyFallbackPackages[platformKey];
      subpath = "bin/esbuild";
      isWASM = true;
    } else {
      throw new Error(`Unsupported platform: ${platformKey}`);
    }
    return { pkg, subpath, isWASM };
  }
  function pkgForSomeOtherPlatform() {
    const libMainJS = __require.resolve("esbuild");
    const nodeModulesDirectory = path3.dirname(path3.dirname(path3.dirname(libMainJS)));
    if (path3.basename(nodeModulesDirectory) === "node_modules") {
      for (const unixKey in knownUnixlikePackages) {
        try {
          const pkg = knownUnixlikePackages[unixKey];
          if (fs.existsSync(path3.join(nodeModulesDirectory, pkg)))
            return pkg;
        } catch {}
      }
      for (const windowsKey in knownWindowsPackages) {
        try {
          const pkg = knownWindowsPackages[windowsKey];
          if (fs.existsSync(path3.join(nodeModulesDirectory, pkg)))
            return pkg;
        } catch {}
      }
    }
    return null;
  }
  function downloadedBinPath(pkg, subpath) {
    const esbuildLibDir = path3.dirname(__require.resolve("esbuild"));
    return path3.join(esbuildLibDir, `downloaded-${pkg.replace("/", "-")}-${path3.basename(subpath)}`);
  }
  function generateBinPath() {
    if (isValidBinaryPath(ESBUILD_BINARY_PATH)) {
      if (!fs.existsSync(ESBUILD_BINARY_PATH)) {
        console.warn(`[esbuild] Ignoring bad configuration: ESBUILD_BINARY_PATH=${ESBUILD_BINARY_PATH}`);
      } else {
        return { binPath: ESBUILD_BINARY_PATH, isWASM: false };
      }
    }
    const { pkg, subpath, isWASM } = pkgAndSubpathForCurrentPlatform();
    let binPath;
    try {
      binPath = __require.resolve(`${pkg}/${subpath}`);
    } catch (e) {
      binPath = downloadedBinPath(pkg, subpath);
      if (!fs.existsSync(binPath)) {
        try {
          __require.resolve(pkg);
        } catch {
          const otherPkg = pkgForSomeOtherPlatform();
          if (otherPkg) {
            let suggestions = `
Specifically the "${otherPkg}" package is present but this platform
needs the "${pkg}" package instead. People often get into this
situation by installing esbuild on Windows or macOS and copying "node_modules"
into a Docker image that runs Linux, or by copying "node_modules" between
Windows and WSL environments.

If you are installing with npm, you can try not copying the "node_modules"
directory when you copy the files over, and running "npm ci" or "npm install"
on the destination platform after the copy. Or you could consider using yarn
instead of npm which has built-in support for installing a package on multiple
platforms simultaneously.

If you are installing with yarn, you can try listing both this platform and the
other platform in your ".yarnrc.yml" file using the "supportedArchitectures"
feature: https://yarnpkg.com/configuration/yarnrc/#supportedArchitectures
Keep in mind that this means multiple copies of esbuild will be present.
`;
            if (pkg === packageDarwin_x64 && otherPkg === packageDarwin_arm64 || pkg === packageDarwin_arm64 && otherPkg === packageDarwin_x64) {
              suggestions = `
Specifically the "${otherPkg}" package is present but this platform
needs the "${pkg}" package instead. People often get into this
situation by installing esbuild with npm running inside of Rosetta 2 and then
trying to use it with node running outside of Rosetta 2, or vice versa (Rosetta
2 is Apple's on-the-fly x86_64-to-arm64 translation service).

If you are installing with npm, you can try ensuring that both npm and node are
not running under Rosetta 2 and then reinstalling esbuild. This likely involves
changing how you installed npm and/or node. For example, installing node with
the universal installer here should work: https://nodejs.org/en/download/. Or
you could consider using yarn instead of npm which has built-in support for
installing a package on multiple platforms simultaneously.

If you are installing with yarn, you can try listing both "arm64" and "x64"
in your ".yarnrc.yml" file using the "supportedArchitectures" feature:
https://yarnpkg.com/configuration/yarnrc/#supportedArchitectures
Keep in mind that this means multiple copies of esbuild will be present.
`;
            }
            throw new Error(`
You installed esbuild for another platform than the one you're currently using.
This won't work because esbuild is written with native code and needs to
install a platform-specific binary executable.
${suggestions}
Another alternative is to use the "esbuild-wasm" package instead, which works
the same way on all platforms. But it comes with a heavy performance cost and
can sometimes be 10x slower than the "esbuild" package, so you may also not
want to do that.
`);
          }
          throw new Error(`The package "${pkg}" could not be found, and is needed by esbuild.

If you are installing esbuild with npm, make sure that you don't specify the
"--no-optional" or "--omit=optional" flags. The "optionalDependencies" feature
of "package.json" is used by esbuild to install the correct binary executable
for your current platform.`);
        }
        throw e;
      }
    }
    if (/\.zip\//.test(binPath)) {
      let pnpapi;
      try {
        pnpapi = (()=>{throw new Error("Cannot require module "+"pnpapi");})();
      } catch (e) {}
      if (pnpapi) {
        const root = pnpapi.getPackageInformation(pnpapi.topLevel).packageLocation;
        const binTargetPath = path3.join(root, "node_modules", ".cache", "esbuild", `pnpapi-${pkg.replace("/", "-")}-${"0.27.4"}-${path3.basename(subpath)}`);
        if (!fs.existsSync(binTargetPath)) {
          fs.mkdirSync(path3.dirname(binTargetPath), { recursive: true });
          fs.copyFileSync(binPath, binTargetPath);
          fs.chmodSync(binTargetPath, 493);
        }
        return { binPath: binTargetPath, isWASM };
      }
    }
    return { binPath, isWASM };
  }
  var child_process = __require("child_process");
  var crypto = __require("crypto");
  var path22 = __require("path");
  var fs2 = __require("fs");
  var os2 = __require("os");
  var tty = __require("tty");
  var worker_threads;
  if (process.env.ESBUILD_WORKER_THREADS !== "0") {
    try {
      worker_threads = __require("worker_threads");
    } catch {}
    let [major, minor] = process.versions.node.split(".");
    if (+major < 12 || +major === 12 && +minor < 17 || +major === 13 && +minor < 13) {
      worker_threads = undefined;
    }
  }
  var _a2;
  var isInternalWorkerThread = ((_a2 = worker_threads == null ? undefined : worker_threads.workerData) == null ? undefined : _a2.esbuildVersion) === "0.27.4";
  var esbuildCommandAndArgs = () => {
    if ((!ESBUILD_BINARY_PATH || false) && (path22.basename(__filename) !== "main.js" || path22.basename(__dirname) !== "lib")) {
      throw new Error(`The esbuild JavaScript API cannot be bundled. Please mark the "esbuild" package as external so it's not included in the bundle.

More information: The file containing the code for esbuild's JavaScript API (${__filename}) does not appear to be inside the esbuild package on the file system, which usually means that the esbuild package was bundled into another file. This is problematic because the API needs to run a binary executable inside the esbuild package which is located using a relative path from the API code to the executable. If the esbuild package is bundled, the relative path will be incorrect and the executable won't be found.`);
    }
    if (false) {} else {
      const { binPath, isWASM } = generateBinPath();
      if (isWASM) {
        return ["node", [binPath]];
      } else {
        return [binPath, []];
      }
    }
  };
  var isTTY = () => tty.isatty(2);
  var fsSync = {
    readFile(tempFile, callback) {
      try {
        let contents = fs2.readFileSync(tempFile, "utf8");
        try {
          fs2.unlinkSync(tempFile);
        } catch {}
        callback(null, contents);
      } catch (err) {
        callback(err, null);
      }
    },
    writeFile(contents, callback) {
      try {
        let tempFile = randomFileName();
        fs2.writeFileSync(tempFile, contents);
        callback(tempFile);
      } catch {
        callback(null);
      }
    }
  };
  var fsAsync = {
    readFile(tempFile, callback) {
      try {
        fs2.readFile(tempFile, "utf8", (err, contents) => {
          try {
            fs2.unlink(tempFile, () => callback(err, contents));
          } catch {
            callback(err, contents);
          }
        });
      } catch (err) {
        callback(err, null);
      }
    },
    writeFile(contents, callback) {
      try {
        let tempFile = randomFileName();
        fs2.writeFile(tempFile, contents, (err) => err !== null ? callback(null) : callback(tempFile));
      } catch {
        callback(null);
      }
    }
  };
  var version = "0.27.4";
  var build = (options) => ensureServiceIsRunning().build(options);
  var context = (buildOptions) => ensureServiceIsRunning().context(buildOptions);
  var transform = (input, options) => ensureServiceIsRunning().transform(input, options);
  var formatMessages = (messages, options) => ensureServiceIsRunning().formatMessages(messages, options);
  var analyzeMetafile = (messages, options) => ensureServiceIsRunning().analyzeMetafile(messages, options);
  var buildSync = (options) => {
    if (worker_threads && !isInternalWorkerThread) {
      if (!workerThreadService)
        workerThreadService = startWorkerThreadService(worker_threads);
      return workerThreadService.buildSync(options);
    }
    let result;
    runServiceSync((service) => service.buildOrContext({
      callName: "buildSync",
      refs: null,
      options,
      isTTY: isTTY(),
      defaultWD,
      callback: (err, res) => {
        if (err)
          throw err;
        result = res;
      }
    }));
    return result;
  };
  var transformSync = (input, options) => {
    if (worker_threads && !isInternalWorkerThread) {
      if (!workerThreadService)
        workerThreadService = startWorkerThreadService(worker_threads);
      return workerThreadService.transformSync(input, options);
    }
    let result;
    runServiceSync((service) => service.transform({
      callName: "transformSync",
      refs: null,
      input,
      options: options || {},
      isTTY: isTTY(),
      fs: fsSync,
      callback: (err, res) => {
        if (err)
          throw err;
        result = res;
      }
    }));
    return result;
  };
  var formatMessagesSync = (messages, options) => {
    if (worker_threads && !isInternalWorkerThread) {
      if (!workerThreadService)
        workerThreadService = startWorkerThreadService(worker_threads);
      return workerThreadService.formatMessagesSync(messages, options);
    }
    let result;
    runServiceSync((service) => service.formatMessages({
      callName: "formatMessagesSync",
      refs: null,
      messages,
      options,
      callback: (err, res) => {
        if (err)
          throw err;
        result = res;
      }
    }));
    return result;
  };
  var analyzeMetafileSync = (metafile, options) => {
    if (worker_threads && !isInternalWorkerThread) {
      if (!workerThreadService)
        workerThreadService = startWorkerThreadService(worker_threads);
      return workerThreadService.analyzeMetafileSync(metafile, options);
    }
    let result;
    runServiceSync((service) => service.analyzeMetafile({
      callName: "analyzeMetafileSync",
      refs: null,
      metafile: typeof metafile === "string" ? metafile : JSON.stringify(metafile),
      options,
      callback: (err, res) => {
        if (err)
          throw err;
        result = res;
      }
    }));
    return result;
  };
  var stop = () => {
    if (stopService)
      stopService();
    if (workerThreadService)
      workerThreadService.stop();
    return Promise.resolve();
  };
  var initializeWasCalled = false;
  var initialize = (options) => {
    options = validateInitializeOptions(options || {});
    if (options.wasmURL)
      throw new Error(`The "wasmURL" option only works in the browser`);
    if (options.wasmModule)
      throw new Error(`The "wasmModule" option only works in the browser`);
    if (options.worker)
      throw new Error(`The "worker" option only works in the browser`);
    if (initializeWasCalled)
      throw new Error('Cannot call "initialize" more than once');
    ensureServiceIsRunning();
    initializeWasCalled = true;
    return Promise.resolve();
  };
  var defaultWD = process.cwd();
  var longLivedService;
  var stopService;
  var ensureServiceIsRunning = () => {
    if (longLivedService)
      return longLivedService;
    let [command2, args] = esbuildCommandAndArgs();
    let child = child_process.spawn(command2, args.concat(`--service=${"0.27.4"}`, "--ping"), {
      windowsHide: true,
      stdio: ["pipe", "pipe", "inherit"],
      cwd: defaultWD
    });
    let { readFromStdout, afterClose, service } = createChannel({
      writeToStdin(bytes) {
        child.stdin.write(bytes, (err) => {
          if (err)
            afterClose(err);
        });
      },
      readFileSync: fs2.readFileSync,
      isSync: false,
      hasFS: true,
      esbuild: node_exports
    });
    child.stdin.on("error", afterClose);
    child.on("error", afterClose);
    const stdin = child.stdin;
    const stdout = child.stdout;
    stdout.on("data", readFromStdout);
    stdout.on("end", afterClose);
    stopService = () => {
      stdin.destroy();
      stdout.destroy();
      child.kill();
      initializeWasCalled = false;
      longLivedService = undefined;
      stopService = undefined;
    };
    let refCount = 0;
    child.unref();
    if (stdin.unref) {
      stdin.unref();
    }
    if (stdout.unref) {
      stdout.unref();
    }
    const refs = {
      ref() {
        if (++refCount === 1)
          child.ref();
      },
      unref() {
        if (--refCount === 0)
          child.unref();
      }
    };
    longLivedService = {
      build: (options) => new Promise((resolve5, reject) => {
        service.buildOrContext({
          callName: "build",
          refs,
          options,
          isTTY: isTTY(),
          defaultWD,
          callback: (err, res) => err ? reject(err) : resolve5(res)
        });
      }),
      context: (options) => new Promise((resolve5, reject) => service.buildOrContext({
        callName: "context",
        refs,
        options,
        isTTY: isTTY(),
        defaultWD,
        callback: (err, res) => err ? reject(err) : resolve5(res)
      })),
      transform: (input, options) => new Promise((resolve5, reject) => service.transform({
        callName: "transform",
        refs,
        input,
        options: options || {},
        isTTY: isTTY(),
        fs: fsAsync,
        callback: (err, res) => err ? reject(err) : resolve5(res)
      })),
      formatMessages: (messages, options) => new Promise((resolve5, reject) => service.formatMessages({
        callName: "formatMessages",
        refs,
        messages,
        options,
        callback: (err, res) => err ? reject(err) : resolve5(res)
      })),
      analyzeMetafile: (metafile, options) => new Promise((resolve5, reject) => service.analyzeMetafile({
        callName: "analyzeMetafile",
        refs,
        metafile: typeof metafile === "string" ? metafile : JSON.stringify(metafile),
        options,
        callback: (err, res) => err ? reject(err) : resolve5(res)
      }))
    };
    return longLivedService;
  };
  var runServiceSync = (callback) => {
    let [command2, args] = esbuildCommandAndArgs();
    let stdin = new Uint8Array;
    let { readFromStdout, afterClose, service } = createChannel({
      writeToStdin(bytes) {
        if (stdin.length !== 0)
          throw new Error("Must run at most one command");
        stdin = bytes;
      },
      isSync: true,
      hasFS: true,
      esbuild: node_exports
    });
    callback(service);
    let stdout = child_process.execFileSync(command2, args.concat(`--service=${"0.27.4"}`), {
      cwd: defaultWD,
      windowsHide: true,
      input: stdin,
      maxBuffer: +process.env.ESBUILD_MAX_BUFFER || 16 * 1024 * 1024
    });
    readFromStdout(stdout);
    afterClose(null);
  };
  var randomFileName = () => {
    return path22.join(os2.tmpdir(), `esbuild-${crypto.randomBytes(32).toString("hex")}`);
  };
  var workerThreadService = null;
  var startWorkerThreadService = (worker_threads2) => {
    let { port1: mainPort, port2: workerPort } = new worker_threads2.MessageChannel;
    let worker = new worker_threads2.Worker(__filename, {
      workerData: { workerPort, defaultWD, esbuildVersion: "0.27.4" },
      transferList: [workerPort],
      execArgv: []
    });
    let nextID = 0;
    let fakeBuildError = (text) => {
      let error = new Error(`Build failed with 1 error:
error: ${text}`);
      let errors = [{ id: "", pluginName: "", text, location: null, notes: [], detail: undefined }];
      error.errors = errors;
      error.warnings = [];
      return error;
    };
    let validateBuildSyncOptions = (options) => {
      if (!options)
        return;
      let plugins = options.plugins;
      if (plugins && plugins.length > 0)
        throw fakeBuildError(`Cannot use plugins in synchronous API calls`);
    };
    let applyProperties = (object, properties) => {
      for (let key in properties) {
        object[key] = properties[key];
      }
    };
    let runCallSync = (command2, args) => {
      let id = nextID++;
      let sharedBuffer = new SharedArrayBuffer(8);
      let sharedBufferView = new Int32Array(sharedBuffer);
      let msg = { sharedBuffer, id, command: command2, args };
      worker.postMessage(msg);
      let status = Atomics.wait(sharedBufferView, 0, 0);
      if (status !== "ok" && status !== "not-equal")
        throw new Error("Internal error: Atomics.wait() failed: " + status);
      let { message: { id: id2, resolve: resolve5, reject, properties } } = worker_threads2.receiveMessageOnPort(mainPort);
      if (id !== id2)
        throw new Error(`Internal error: Expected id ${id} but got id ${id2}`);
      if (reject) {
        applyProperties(reject, properties);
        throw reject;
      }
      return resolve5;
    };
    worker.unref();
    return {
      buildSync(options) {
        validateBuildSyncOptions(options);
        return runCallSync("build", [options]);
      },
      transformSync(input, options) {
        return runCallSync("transform", [input, options]);
      },
      formatMessagesSync(messages, options) {
        return runCallSync("formatMessages", [messages, options]);
      },
      analyzeMetafileSync(metafile, options) {
        return runCallSync("analyzeMetafile", [metafile, options]);
      },
      stop() {
        worker.terminate();
        workerThreadService = null;
      }
    };
  };
  var startSyncServiceWorker = () => {
    let workerPort = worker_threads.workerData.workerPort;
    let parentPort = worker_threads.parentPort;
    let extractProperties = (object) => {
      let properties = {};
      if (object && typeof object === "object") {
        for (let key in object) {
          properties[key] = object[key];
        }
      }
      return properties;
    };
    try {
      let service = ensureServiceIsRunning();
      defaultWD = worker_threads.workerData.defaultWD;
      parentPort.on("message", (msg) => {
        (async () => {
          let { sharedBuffer, id, command: command2, args } = msg;
          let sharedBufferView = new Int32Array(sharedBuffer);
          try {
            switch (command2) {
              case "build":
                workerPort.postMessage({ id, resolve: await service.build(args[0]) });
                break;
              case "transform":
                workerPort.postMessage({ id, resolve: await service.transform(args[0], args[1]) });
                break;
              case "formatMessages":
                workerPort.postMessage({ id, resolve: await service.formatMessages(args[0], args[1]) });
                break;
              case "analyzeMetafile":
                workerPort.postMessage({ id, resolve: await service.analyzeMetafile(args[0], args[1]) });
                break;
              default:
                throw new Error(`Invalid command: ${command2}`);
            }
          } catch (reject) {
            workerPort.postMessage({ id, reject, properties: extractProperties(reject) });
          }
          Atomics.add(sharedBufferView, 0, 1);
          Atomics.notify(sharedBufferView, 0, Infinity);
        })();
      });
    } catch (reject) {
      parentPort.on("message", (msg) => {
        let { sharedBuffer, id } = msg;
        let sharedBufferView = new Int32Array(sharedBuffer);
        workerPort.postMessage({ id, reject, properties: extractProperties(reject) });
        Atomics.add(sharedBufferView, 0, 1);
        Atomics.notify(sharedBufferView, 0, Infinity);
      });
    }
  };
  if (isInternalWorkerThread) {
    startSyncServiceWorker();
  }
  var node_default2 = node_exports;
});

// src/zapp-cli.ts
import path10 from "path";
import process8 from "process";

// node_modules/yargs/lib/platform-shims/esm.mjs
import { notStrictEqual, strictEqual } from "assert";

// node_modules/cliui/build/lib/index.js
var align = {
  right: alignRight,
  center: alignCenter
};
var top = 0;
var right = 1;
var bottom = 2;
var left = 3;

class UI {
  constructor(opts) {
    var _a;
    this.width = opts.width;
    this.wrap = (_a = opts.wrap) !== null && _a !== undefined ? _a : true;
    this.rows = [];
  }
  span(...args) {
    const cols = this.div(...args);
    cols.span = true;
  }
  resetOutput() {
    this.rows = [];
  }
  div(...args) {
    if (args.length === 0) {
      this.div("");
    }
    if (this.wrap && this.shouldApplyLayoutDSL(...args) && typeof args[0] === "string") {
      return this.applyLayoutDSL(args[0]);
    }
    const cols = args.map((arg) => {
      if (typeof arg === "string") {
        return this.colFromString(arg);
      }
      return arg;
    });
    this.rows.push(cols);
    return cols;
  }
  shouldApplyLayoutDSL(...args) {
    return args.length === 1 && typeof args[0] === "string" && /[\t\n]/.test(args[0]);
  }
  applyLayoutDSL(str) {
    const rows = str.split(`
`).map((row) => row.split("\t"));
    let leftColumnWidth = 0;
    rows.forEach((columns) => {
      if (columns.length > 1 && mixin.stringWidth(columns[0]) > leftColumnWidth) {
        leftColumnWidth = Math.min(Math.floor(this.width * 0.5), mixin.stringWidth(columns[0]));
      }
    });
    rows.forEach((columns) => {
      this.div(...columns.map((r, i) => {
        return {
          text: r.trim(),
          padding: this.measurePadding(r),
          width: i === 0 && columns.length > 1 ? leftColumnWidth : undefined
        };
      }));
    });
    return this.rows[this.rows.length - 1];
  }
  colFromString(text) {
    return {
      text,
      padding: this.measurePadding(text)
    };
  }
  measurePadding(str) {
    const noAnsi = mixin.stripAnsi(str);
    return [0, noAnsi.match(/\s*$/)[0].length, 0, noAnsi.match(/^\s*/)[0].length];
  }
  toString() {
    const lines = [];
    this.rows.forEach((row) => {
      this.rowToString(row, lines);
    });
    return lines.filter((line) => !line.hidden).map((line) => line.text).join(`
`);
  }
  rowToString(row, lines) {
    this.rasterize(row).forEach((rrow, r) => {
      let str = "";
      rrow.forEach((col, c) => {
        const { width } = row[c];
        const wrapWidth = this.negatePadding(row[c]);
        let ts = col;
        if (wrapWidth > mixin.stringWidth(col)) {
          ts += " ".repeat(wrapWidth - mixin.stringWidth(col));
        }
        if (row[c].align && row[c].align !== "left" && this.wrap) {
          const fn = align[row[c].align];
          ts = fn(ts, wrapWidth);
          if (mixin.stringWidth(ts) < wrapWidth) {
            ts += " ".repeat((width || 0) - mixin.stringWidth(ts) - 1);
          }
        }
        const padding = row[c].padding || [0, 0, 0, 0];
        if (padding[left]) {
          str += " ".repeat(padding[left]);
        }
        str += addBorder(row[c], ts, "| ");
        str += ts;
        str += addBorder(row[c], ts, " |");
        if (padding[right]) {
          str += " ".repeat(padding[right]);
        }
        if (r === 0 && lines.length > 0) {
          str = this.renderInline(str, lines[lines.length - 1]);
        }
      });
      lines.push({
        text: str.replace(/ +$/, ""),
        span: row.span
      });
    });
    return lines;
  }
  renderInline(source, previousLine) {
    const match = source.match(/^ */);
    const leadingWhitespace = match ? match[0].length : 0;
    const target = previousLine.text;
    const targetTextWidth = mixin.stringWidth(target.trimRight());
    if (!previousLine.span) {
      return source;
    }
    if (!this.wrap) {
      previousLine.hidden = true;
      return target + source;
    }
    if (leadingWhitespace < targetTextWidth) {
      return source;
    }
    previousLine.hidden = true;
    return target.trimRight() + " ".repeat(leadingWhitespace - targetTextWidth) + source.trimLeft();
  }
  rasterize(row) {
    const rrows = [];
    const widths = this.columnWidths(row);
    let wrapped;
    row.forEach((col, c) => {
      col.width = widths[c];
      if (this.wrap) {
        wrapped = mixin.wrap(col.text, this.negatePadding(col), { hard: true }).split(`
`);
      } else {
        wrapped = col.text.split(`
`);
      }
      if (col.border) {
        wrapped.unshift("." + "-".repeat(this.negatePadding(col) + 2) + ".");
        wrapped.push("'" + "-".repeat(this.negatePadding(col) + 2) + "'");
      }
      if (col.padding) {
        wrapped.unshift(...new Array(col.padding[top] || 0).fill(""));
        wrapped.push(...new Array(col.padding[bottom] || 0).fill(""));
      }
      wrapped.forEach((str, r) => {
        if (!rrows[r]) {
          rrows.push([]);
        }
        const rrow = rrows[r];
        for (let i = 0;i < c; i++) {
          if (rrow[i] === undefined) {
            rrow.push("");
          }
        }
        rrow.push(str);
      });
    });
    return rrows;
  }
  negatePadding(col) {
    let wrapWidth = col.width || 0;
    if (col.padding) {
      wrapWidth -= (col.padding[left] || 0) + (col.padding[right] || 0);
    }
    if (col.border) {
      wrapWidth -= 4;
    }
    return wrapWidth;
  }
  columnWidths(row) {
    if (!this.wrap) {
      return row.map((col) => {
        return col.width || mixin.stringWidth(col.text);
      });
    }
    let unset = row.length;
    let remainingWidth = this.width;
    const widths = row.map((col) => {
      if (col.width) {
        unset--;
        remainingWidth -= col.width;
        return col.width;
      }
      return;
    });
    const unsetWidth = unset ? Math.floor(remainingWidth / unset) : 0;
    return widths.map((w, i) => {
      if (w === undefined) {
        return Math.max(unsetWidth, _minWidth(row[i]));
      }
      return w;
    });
  }
}
function addBorder(col, ts, style) {
  if (col.border) {
    if (/[.']-+[.']/.test(ts)) {
      return "";
    }
    if (ts.trim().length !== 0) {
      return style;
    }
    return "  ";
  }
  return "";
}
function _minWidth(col) {
  const padding = col.padding || [];
  const minWidth = 1 + (padding[left] || 0) + (padding[right] || 0);
  if (col.border) {
    return minWidth + 4;
  }
  return minWidth;
}
function getWindowWidth() {
  if (typeof process === "object" && process.stdout && process.stdout.columns) {
    return process.stdout.columns;
  }
  return 80;
}
function alignRight(str, width) {
  str = str.trim();
  const strWidth = mixin.stringWidth(str);
  if (strWidth < width) {
    return " ".repeat(width - strWidth) + str;
  }
  return str;
}
function alignCenter(str, width) {
  str = str.trim();
  const strWidth = mixin.stringWidth(str);
  if (strWidth >= width) {
    return str;
  }
  return " ".repeat(width - strWidth >> 1) + str;
}
var mixin;
function cliui(opts, _mixin) {
  mixin = _mixin;
  return new UI({
    width: (opts === null || opts === undefined ? undefined : opts.width) || getWindowWidth(),
    wrap: opts === null || opts === undefined ? undefined : opts.wrap
  });
}

// node_modules/ansi-regex/index.js
function ansiRegex({ onlyFirst = false } = {}) {
  const ST = "(?:\\u0007|\\u001B\\u005C|\\u009C)";
  const osc = `(?:\\u001B\\][\\s\\S]*?${ST})`;
  const csi = "[\\u001B\\u009B][[\\]()#;?]*(?:\\d{1,4}(?:[;:]\\d{0,4})*)?[\\dA-PR-TZcf-nq-uy=><~]";
  const pattern = `${osc}|${csi}`;
  return new RegExp(pattern, onlyFirst ? undefined : "g");
}

// node_modules/strip-ansi/index.js
var regex = ansiRegex();
function stripAnsi(string) {
  if (typeof string !== "string") {
    throw new TypeError(`Expected a \`string\`, got \`${typeof string}\``);
  }
  if (!string.includes("\x1B") && !string.includes("\x9B")) {
    return string;
  }
  return string.replace(regex, "");
}

// node_modules/get-east-asian-width/lookup-data.js
var ambiguousRanges = [161, 161, 164, 164, 167, 168, 170, 170, 173, 174, 176, 180, 182, 186, 188, 191, 198, 198, 208, 208, 215, 216, 222, 225, 230, 230, 232, 234, 236, 237, 240, 240, 242, 243, 247, 250, 252, 252, 254, 254, 257, 257, 273, 273, 275, 275, 283, 283, 294, 295, 299, 299, 305, 307, 312, 312, 319, 322, 324, 324, 328, 331, 333, 333, 338, 339, 358, 359, 363, 363, 462, 462, 464, 464, 466, 466, 468, 468, 470, 470, 472, 472, 474, 474, 476, 476, 593, 593, 609, 609, 708, 708, 711, 711, 713, 715, 717, 717, 720, 720, 728, 731, 733, 733, 735, 735, 768, 879, 913, 929, 931, 937, 945, 961, 963, 969, 1025, 1025, 1040, 1103, 1105, 1105, 8208, 8208, 8211, 8214, 8216, 8217, 8220, 8221, 8224, 8226, 8228, 8231, 8240, 8240, 8242, 8243, 8245, 8245, 8251, 8251, 8254, 8254, 8308, 8308, 8319, 8319, 8321, 8324, 8364, 8364, 8451, 8451, 8453, 8453, 8457, 8457, 8467, 8467, 8470, 8470, 8481, 8482, 8486, 8486, 8491, 8491, 8531, 8532, 8539, 8542, 8544, 8555, 8560, 8569, 8585, 8585, 8592, 8601, 8632, 8633, 8658, 8658, 8660, 8660, 8679, 8679, 8704, 8704, 8706, 8707, 8711, 8712, 8715, 8715, 8719, 8719, 8721, 8721, 8725, 8725, 8730, 8730, 8733, 8736, 8739, 8739, 8741, 8741, 8743, 8748, 8750, 8750, 8756, 8759, 8764, 8765, 8776, 8776, 8780, 8780, 8786, 8786, 8800, 8801, 8804, 8807, 8810, 8811, 8814, 8815, 8834, 8835, 8838, 8839, 8853, 8853, 8857, 8857, 8869, 8869, 8895, 8895, 8978, 8978, 9312, 9449, 9451, 9547, 9552, 9587, 9600, 9615, 9618, 9621, 9632, 9633, 9635, 9641, 9650, 9651, 9654, 9655, 9660, 9661, 9664, 9665, 9670, 9672, 9675, 9675, 9678, 9681, 9698, 9701, 9711, 9711, 9733, 9734, 9737, 9737, 9742, 9743, 9756, 9756, 9758, 9758, 9792, 9792, 9794, 9794, 9824, 9825, 9827, 9829, 9831, 9834, 9836, 9837, 9839, 9839, 9886, 9887, 9919, 9919, 9926, 9933, 9935, 9939, 9941, 9953, 9955, 9955, 9960, 9961, 9963, 9969, 9972, 9972, 9974, 9977, 9979, 9980, 9982, 9983, 10045, 10045, 10102, 10111, 11094, 11097, 12872, 12879, 57344, 63743, 65024, 65039, 65533, 65533, 127232, 127242, 127248, 127277, 127280, 127337, 127344, 127373, 127375, 127376, 127387, 127404, 917760, 917999, 983040, 1048573, 1048576, 1114109];
var fullwidthRanges = [12288, 12288, 65281, 65376, 65504, 65510];
var halfwidthRanges = [8361, 8361, 65377, 65470, 65474, 65479, 65482, 65487, 65490, 65495, 65498, 65500, 65512, 65518];
var narrowRanges = [32, 126, 162, 163, 165, 166, 172, 172, 175, 175, 10214, 10221, 10629, 10630];
var wideRanges = [4352, 4447, 8986, 8987, 9001, 9002, 9193, 9196, 9200, 9200, 9203, 9203, 9725, 9726, 9748, 9749, 9776, 9783, 9800, 9811, 9855, 9855, 9866, 9871, 9875, 9875, 9889, 9889, 9898, 9899, 9917, 9918, 9924, 9925, 9934, 9934, 9940, 9940, 9962, 9962, 9970, 9971, 9973, 9973, 9978, 9978, 9981, 9981, 9989, 9989, 9994, 9995, 10024, 10024, 10060, 10060, 10062, 10062, 10067, 10069, 10071, 10071, 10133, 10135, 10160, 10160, 10175, 10175, 11035, 11036, 11088, 11088, 11093, 11093, 11904, 11929, 11931, 12019, 12032, 12245, 12272, 12287, 12289, 12350, 12353, 12438, 12441, 12543, 12549, 12591, 12593, 12686, 12688, 12773, 12783, 12830, 12832, 12871, 12880, 42124, 42128, 42182, 43360, 43388, 44032, 55203, 63744, 64255, 65040, 65049, 65072, 65106, 65108, 65126, 65128, 65131, 94176, 94180, 94192, 94198, 94208, 101589, 101631, 101662, 101760, 101874, 110576, 110579, 110581, 110587, 110589, 110590, 110592, 110882, 110898, 110898, 110928, 110930, 110933, 110933, 110948, 110951, 110960, 111355, 119552, 119638, 119648, 119670, 126980, 126980, 127183, 127183, 127374, 127374, 127377, 127386, 127488, 127490, 127504, 127547, 127552, 127560, 127568, 127569, 127584, 127589, 127744, 127776, 127789, 127797, 127799, 127868, 127870, 127891, 127904, 127946, 127951, 127955, 127968, 127984, 127988, 127988, 127992, 128062, 128064, 128064, 128066, 128252, 128255, 128317, 128331, 128334, 128336, 128359, 128378, 128378, 128405, 128406, 128420, 128420, 128507, 128591, 128640, 128709, 128716, 128716, 128720, 128722, 128725, 128728, 128732, 128735, 128747, 128748, 128756, 128764, 128992, 129003, 129008, 129008, 129292, 129338, 129340, 129349, 129351, 129535, 129648, 129660, 129664, 129674, 129678, 129734, 129736, 129736, 129741, 129756, 129759, 129770, 129775, 129784, 131072, 196605, 196608, 262141];

// node_modules/get-east-asian-width/utilities.js
var isInRange = (ranges, codePoint) => {
  let low = 0;
  let high = Math.floor(ranges.length / 2) - 1;
  while (low <= high) {
    const mid = Math.floor((low + high) / 2);
    const i = mid * 2;
    if (codePoint < ranges[i]) {
      high = mid - 1;
    } else if (codePoint > ranges[i + 1]) {
      low = mid + 1;
    } else {
      return true;
    }
  }
  return false;
};

// node_modules/get-east-asian-width/lookup.js
var minimumAmbiguousCodePoint = ambiguousRanges[0];
var maximumAmbiguousCodePoint = ambiguousRanges.at(-1);
var minimumFullWidthCodePoint = fullwidthRanges[0];
var maximumFullWidthCodePoint = fullwidthRanges.at(-1);
var minimumHalfWidthCodePoint = halfwidthRanges[0];
var maximumHalfWidthCodePoint = halfwidthRanges.at(-1);
var minimumNarrowCodePoint = narrowRanges[0];
var maximumNarrowCodePoint = narrowRanges.at(-1);
var minimumWideCodePoint = wideRanges[0];
var maximumWideCodePoint = wideRanges.at(-1);
var commonCjkCodePoint = 19968;
var [wideFastPathStart, wideFastPathEnd] = findWideFastPathRange(wideRanges);
function findWideFastPathRange(ranges) {
  let fastPathStart = ranges[0];
  let fastPathEnd = ranges[1];
  for (let index = 0;index < ranges.length; index += 2) {
    const start = ranges[index];
    const end = ranges[index + 1];
    if (commonCjkCodePoint >= start && commonCjkCodePoint <= end) {
      return [start, end];
    }
    if (end - start > fastPathEnd - fastPathStart) {
      fastPathStart = start;
      fastPathEnd = end;
    }
  }
  return [fastPathStart, fastPathEnd];
}
var isAmbiguous = (codePoint) => {
  if (codePoint < minimumAmbiguousCodePoint || codePoint > maximumAmbiguousCodePoint) {
    return false;
  }
  return isInRange(ambiguousRanges, codePoint);
};
var isFullWidth = (codePoint) => {
  if (codePoint < minimumFullWidthCodePoint || codePoint > maximumFullWidthCodePoint) {
    return false;
  }
  return isInRange(fullwidthRanges, codePoint);
};
var isWide = (codePoint) => {
  if (codePoint >= wideFastPathStart && codePoint <= wideFastPathEnd) {
    return true;
  }
  if (codePoint < minimumWideCodePoint || codePoint > maximumWideCodePoint) {
    return false;
  }
  return isInRange(wideRanges, codePoint);
};

// node_modules/get-east-asian-width/index.js
function validate(codePoint) {
  if (!Number.isSafeInteger(codePoint)) {
    throw new TypeError(`Expected a code point, got \`${typeof codePoint}\`.`);
  }
}
function eastAsianWidth(codePoint, { ambiguousAsWide = false } = {}) {
  validate(codePoint);
  if (isFullWidth(codePoint) || isWide(codePoint) || ambiguousAsWide && isAmbiguous(codePoint)) {
    return 2;
  }
  return 1;
}

// node_modules/emoji-regex/index.mjs
var emoji_regex_default = () => {
  return /[#*0-9]\uFE0F?\u20E3|[\xA9\xAE\u203C\u2049\u2122\u2139\u2194-\u2199\u21A9\u21AA\u231A\u231B\u2328\u23CF\u23ED-\u23EF\u23F1\u23F2\u23F8-\u23FA\u24C2\u25AA\u25AB\u25B6\u25C0\u25FB\u25FC\u25FE\u2600-\u2604\u260E\u2611\u2614\u2615\u2618\u2620\u2622\u2623\u2626\u262A\u262E\u262F\u2638-\u263A\u2640\u2642\u2648-\u2653\u265F\u2660\u2663\u2665\u2666\u2668\u267B\u267E\u267F\u2692\u2694-\u2697\u2699\u269B\u269C\u26A0\u26A7\u26AA\u26B0\u26B1\u26BD\u26BE\u26C4\u26C8\u26CF\u26D1\u26E9\u26F0-\u26F5\u26F7\u26F8\u26FA\u2702\u2708\u2709\u270F\u2712\u2714\u2716\u271D\u2721\u2733\u2734\u2744\u2747\u2757\u2763\u27A1\u2934\u2935\u2B05-\u2B07\u2B1B\u2B1C\u2B55\u3030\u303D\u3297\u3299]\uFE0F?|[\u261D\u270C\u270D](?:\uD83C[\uDFFB-\uDFFF]|\uFE0F)?|[\u270A\u270B](?:\uD83C[\uDFFB-\uDFFF])?|[\u23E9-\u23EC\u23F0\u23F3\u25FD\u2693\u26A1\u26AB\u26C5\u26CE\u26D4\u26EA\u26FD\u2705\u2728\u274C\u274E\u2753-\u2755\u2795-\u2797\u27B0\u27BF\u2B50]|\u26D3\uFE0F?(?:\u200D\uD83D\uDCA5)?|\u26F9(?:\uD83C[\uDFFB-\uDFFF]|\uFE0F)?(?:\u200D[\u2640\u2642]\uFE0F?)?|\u2764\uFE0F?(?:\u200D(?:\uD83D\uDD25|\uD83E\uDE79))?|\uD83C(?:[\uDC04\uDD70\uDD71\uDD7E\uDD7F\uDE02\uDE37\uDF21\uDF24-\uDF2C\uDF36\uDF7D\uDF96\uDF97\uDF99-\uDF9B\uDF9E\uDF9F\uDFCD\uDFCE\uDFD4-\uDFDF\uDFF5\uDFF7]\uFE0F?|[\uDF85\uDFC2\uDFC7](?:\uD83C[\uDFFB-\uDFFF])?|[\uDFC4\uDFCA](?:\uD83C[\uDFFB-\uDFFF])?(?:\u200D[\u2640\u2642]\uFE0F?)?|[\uDFCB\uDFCC](?:\uD83C[\uDFFB-\uDFFF]|\uFE0F)?(?:\u200D[\u2640\u2642]\uFE0F?)?|[\uDCCF\uDD8E\uDD91-\uDD9A\uDE01\uDE1A\uDE2F\uDE32-\uDE36\uDE38-\uDE3A\uDE50\uDE51\uDF00-\uDF20\uDF2D-\uDF35\uDF37-\uDF43\uDF45-\uDF4A\uDF4C-\uDF7C\uDF7E-\uDF84\uDF86-\uDF93\uDFA0-\uDFC1\uDFC5\uDFC6\uDFC8\uDFC9\uDFCF-\uDFD3\uDFE0-\uDFF0\uDFF8-\uDFFF]|\uDDE6\uD83C[\uDDE8-\uDDEC\uDDEE\uDDF1\uDDF2\uDDF4\uDDF6-\uDDFA\uDDFC\uDDFD\uDDFF]|\uDDE7\uD83C[\uDDE6\uDDE7\uDDE9-\uDDEF\uDDF1-\uDDF4\uDDF6-\uDDF9\uDDFB\uDDFC\uDDFE\uDDFF]|\uDDE8\uD83C[\uDDE6\uDDE8\uDDE9\uDDEB-\uDDEE\uDDF0-\uDDF7\uDDFA-\uDDFF]|\uDDE9\uD83C[\uDDEA\uDDEC\uDDEF\uDDF0\uDDF2\uDDF4\uDDFF]|\uDDEA\uD83C[\uDDE6\uDDE8\uDDEA\uDDEC\uDDED\uDDF7-\uDDFA]|\uDDEB\uD83C[\uDDEE-\uDDF0\uDDF2\uDDF4\uDDF7]|\uDDEC\uD83C[\uDDE6\uDDE7\uDDE9-\uDDEE\uDDF1-\uDDF3\uDDF5-\uDDFA\uDDFC\uDDFE]|\uDDED\uD83C[\uDDF0\uDDF2\uDDF3\uDDF7\uDDF9\uDDFA]|\uDDEE\uD83C[\uDDE8-\uDDEA\uDDF1-\uDDF4\uDDF6-\uDDF9]|\uDDEF\uD83C[\uDDEA\uDDF2\uDDF4\uDDF5]|\uDDF0\uD83C[\uDDEA\uDDEC-\uDDEE\uDDF2\uDDF3\uDDF5\uDDF7\uDDFC\uDDFE\uDDFF]|\uDDF1\uD83C[\uDDE6-\uDDE8\uDDEE\uDDF0\uDDF7-\uDDFB\uDDFE]|\uDDF2\uD83C[\uDDE6\uDDE8-\uDDED\uDDF0-\uDDFF]|\uDDF3\uD83C[\uDDE6\uDDE8\uDDEA-\uDDEC\uDDEE\uDDF1\uDDF4\uDDF5\uDDF7\uDDFA\uDDFF]|\uDDF4\uD83C\uDDF2|\uDDF5\uD83C[\uDDE6\uDDEA-\uDDED\uDDF0-\uDDF3\uDDF7-\uDDF9\uDDFC\uDDFE]|\uDDF6\uD83C\uDDE6|\uDDF7\uD83C[\uDDEA\uDDF4\uDDF8\uDDFA\uDDFC]|\uDDF8\uD83C[\uDDE6-\uDDEA\uDDEC-\uDDF4\uDDF7-\uDDF9\uDDFB\uDDFD-\uDDFF]|\uDDF9\uD83C[\uDDE6\uDDE8\uDDE9\uDDEB-\uDDED\uDDEF-\uDDF4\uDDF7\uDDF9\uDDFB\uDDFC\uDDFF]|\uDDFA\uD83C[\uDDE6\uDDEC\uDDF2\uDDF3\uDDF8\uDDFE\uDDFF]|\uDDFB\uD83C[\uDDE6\uDDE8\uDDEA\uDDEC\uDDEE\uDDF3\uDDFA]|\uDDFC\uD83C[\uDDEB\uDDF8]|\uDDFD\uD83C\uDDF0|\uDDFE\uD83C[\uDDEA\uDDF9]|\uDDFF\uD83C[\uDDE6\uDDF2\uDDFC]|\uDF44(?:\u200D\uD83D\uDFEB)?|\uDF4B(?:\u200D\uD83D\uDFE9)?|\uDFC3(?:\uD83C[\uDFFB-\uDFFF])?(?:\u200D(?:[\u2640\u2642]\uFE0F?(?:\u200D\u27A1\uFE0F?)?|\u27A1\uFE0F?))?|\uDFF3\uFE0F?(?:\u200D(?:\u26A7\uFE0F?|\uD83C\uDF08))?|\uDFF4(?:\u200D\u2620\uFE0F?|\uDB40\uDC67\uDB40\uDC62\uDB40(?:\uDC65\uDB40\uDC6E\uDB40\uDC67|\uDC73\uDB40\uDC63\uDB40\uDC74|\uDC77\uDB40\uDC6C\uDB40\uDC73)\uDB40\uDC7F)?)|\uD83D(?:[\uDC3F\uDCFD\uDD49\uDD4A\uDD6F\uDD70\uDD73\uDD76-\uDD79\uDD87\uDD8A-\uDD8D\uDDA5\uDDA8\uDDB1\uDDB2\uDDBC\uDDC2-\uDDC4\uDDD1-\uDDD3\uDDDC-\uDDDE\uDDE1\uDDE3\uDDE8\uDDEF\uDDF3\uDDFA\uDECB\uDECD-\uDECF\uDEE0-\uDEE5\uDEE9\uDEF0\uDEF3]\uFE0F?|[\uDC42\uDC43\uDC46-\uDC50\uDC66\uDC67\uDC6B-\uDC6D\uDC72\uDC74-\uDC76\uDC78\uDC7C\uDC83\uDC85\uDC8F\uDC91\uDCAA\uDD7A\uDD95\uDD96\uDE4C\uDE4F\uDEC0\uDECC](?:\uD83C[\uDFFB-\uDFFF])?|[\uDC6E-\uDC71\uDC73\uDC77\uDC81\uDC82\uDC86\uDC87\uDE45-\uDE47\uDE4B\uDE4D\uDE4E\uDEA3\uDEB4\uDEB5](?:\uD83C[\uDFFB-\uDFFF])?(?:\u200D[\u2640\u2642]\uFE0F?)?|[\uDD74\uDD90](?:\uD83C[\uDFFB-\uDFFF]|\uFE0F)?|[\uDC00-\uDC07\uDC09-\uDC14\uDC16-\uDC25\uDC27-\uDC3A\uDC3C-\uDC3E\uDC40\uDC44\uDC45\uDC51-\uDC65\uDC6A\uDC79-\uDC7B\uDC7D-\uDC80\uDC84\uDC88-\uDC8E\uDC90\uDC92-\uDCA9\uDCAB-\uDCFC\uDCFF-\uDD3D\uDD4B-\uDD4E\uDD50-\uDD67\uDDA4\uDDFB-\uDE2D\uDE2F-\uDE34\uDE37-\uDE41\uDE43\uDE44\uDE48-\uDE4A\uDE80-\uDEA2\uDEA4-\uDEB3\uDEB7-\uDEBF\uDEC1-\uDEC5\uDED0-\uDED2\uDED5-\uDED8\uDEDC-\uDEDF\uDEEB\uDEEC\uDEF4-\uDEFC\uDFE0-\uDFEB\uDFF0]|\uDC08(?:\u200D\u2B1B)?|\uDC15(?:\u200D\uD83E\uDDBA)?|\uDC26(?:\u200D(?:\u2B1B|\uD83D\uDD25))?|\uDC3B(?:\u200D\u2744\uFE0F?)?|\uDC41\uFE0F?(?:\u200D\uD83D\uDDE8\uFE0F?)?|\uDC68(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:\uDC8B\u200D\uD83D)?\uDC68|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDC68\uDC69]\u200D\uD83D(?:\uDC66(?:\u200D\uD83D\uDC66)?|\uDC67(?:\u200D\uD83D[\uDC66\uDC67])?)|[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC66(?:\u200D\uD83D\uDC66)?|\uDC67(?:\u200D\uD83D[\uDC66\uDC67])?)|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3]))|\uD83C(?:\uDFFB(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:\uDC8B\u200D\uD83D)?\uDC68\uD83C[\uDFFB-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83D\uDC68\uD83C[\uDFFC-\uDFFF])|\uD83E(?:[\uDD1D\uDEEF]\u200D\uD83D\uDC68\uD83C[\uDFFC-\uDFFF]|[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3])))?|\uDFFC(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:\uDC8B\u200D\uD83D)?\uDC68\uD83C[\uDFFB-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83D\uDC68\uD83C[\uDFFB\uDFFD-\uDFFF])|\uD83E(?:[\uDD1D\uDEEF]\u200D\uD83D\uDC68\uD83C[\uDFFB\uDFFD-\uDFFF]|[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3])))?|\uDFFD(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:\uDC8B\u200D\uD83D)?\uDC68\uD83C[\uDFFB-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83D\uDC68\uD83C[\uDFFB\uDFFC\uDFFE\uDFFF])|\uD83E(?:[\uDD1D\uDEEF]\u200D\uD83D\uDC68\uD83C[\uDFFB\uDFFC\uDFFE\uDFFF]|[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3])))?|\uDFFE(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:\uDC8B\u200D\uD83D)?\uDC68\uD83C[\uDFFB-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83D\uDC68\uD83C[\uDFFB-\uDFFD\uDFFF])|\uD83E(?:[\uDD1D\uDEEF]\u200D\uD83D\uDC68\uD83C[\uDFFB-\uDFFD\uDFFF]|[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3])))?|\uDFFF(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:\uDC8B\u200D\uD83D)?\uDC68\uD83C[\uDFFB-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83D\uDC68\uD83C[\uDFFB-\uDFFE])|\uD83E(?:[\uDD1D\uDEEF]\u200D\uD83D\uDC68\uD83C[\uDFFB-\uDFFE]|[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3])))?))?|\uDC69(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:\uDC8B\u200D\uD83D)?[\uDC68\uDC69]|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC66(?:\u200D\uD83D\uDC66)?|\uDC67(?:\u200D\uD83D[\uDC66\uDC67])?|\uDC69\u200D\uD83D(?:\uDC66(?:\u200D\uD83D\uDC66)?|\uDC67(?:\u200D\uD83D[\uDC66\uDC67])?))|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3]))|\uD83C(?:\uDFFB(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:[\uDC68\uDC69]|\uDC8B\u200D\uD83D[\uDC68\uDC69])\uD83C[\uDFFB-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83D\uDC69\uD83C[\uDFFC-\uDFFF])|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3]|\uDD1D\u200D\uD83D[\uDC68\uDC69]\uD83C[\uDFFC-\uDFFF]|\uDEEF\u200D\uD83D\uDC69\uD83C[\uDFFC-\uDFFF])))?|\uDFFC(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:[\uDC68\uDC69]|\uDC8B\u200D\uD83D[\uDC68\uDC69])\uD83C[\uDFFB-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83D\uDC69\uD83C[\uDFFB\uDFFD-\uDFFF])|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3]|\uDD1D\u200D\uD83D[\uDC68\uDC69]\uD83C[\uDFFB\uDFFD-\uDFFF]|\uDEEF\u200D\uD83D\uDC69\uD83C[\uDFFB\uDFFD-\uDFFF])))?|\uDFFD(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:[\uDC68\uDC69]|\uDC8B\u200D\uD83D[\uDC68\uDC69])\uD83C[\uDFFB-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83D\uDC69\uD83C[\uDFFB\uDFFC\uDFFE\uDFFF])|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3]|\uDD1D\u200D\uD83D[\uDC68\uDC69]\uD83C[\uDFFB\uDFFC\uDFFE\uDFFF]|\uDEEF\u200D\uD83D\uDC69\uD83C[\uDFFB\uDFFC\uDFFE\uDFFF])))?|\uDFFE(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:[\uDC68\uDC69]|\uDC8B\u200D\uD83D[\uDC68\uDC69])\uD83C[\uDFFB-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83D\uDC69\uD83C[\uDFFB-\uDFFD\uDFFF])|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3]|\uDD1D\u200D\uD83D[\uDC68\uDC69]\uD83C[\uDFFB-\uDFFD\uDFFF]|\uDEEF\u200D\uD83D\uDC69\uD83C[\uDFFB-\uDFFD\uDFFF])))?|\uDFFF(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D\uD83D(?:[\uDC68\uDC69]|\uDC8B\u200D\uD83D[\uDC68\uDC69])\uD83C[\uDFFB-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83D\uDC69\uD83C[\uDFFB-\uDFFE])|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3]|\uDD1D\u200D\uD83D[\uDC68\uDC69]\uD83C[\uDFFB-\uDFFE]|\uDEEF\u200D\uD83D\uDC69\uD83C[\uDFFB-\uDFFE])))?))?|\uDD75(?:\uD83C[\uDFFB-\uDFFF]|\uFE0F)?(?:\u200D[\u2640\u2642]\uFE0F?)?|\uDE2E(?:\u200D\uD83D\uDCA8)?|\uDE35(?:\u200D\uD83D\uDCAB)?|\uDE36(?:\u200D\uD83C\uDF2B\uFE0F?)?|\uDE42(?:\u200D[\u2194\u2195]\uFE0F?)?|\uDEB6(?:\uD83C[\uDFFB-\uDFFF])?(?:\u200D(?:[\u2640\u2642]\uFE0F?(?:\u200D\u27A1\uFE0F?)?|\u27A1\uFE0F?))?)|\uD83E(?:[\uDD0C\uDD0F\uDD18-\uDD1F\uDD30-\uDD34\uDD36\uDD77\uDDB5\uDDB6\uDDBB\uDDD2\uDDD3\uDDD5\uDEC3-\uDEC5\uDEF0\uDEF2-\uDEF8](?:\uD83C[\uDFFB-\uDFFF])?|[\uDD26\uDD35\uDD37-\uDD39\uDD3C-\uDD3E\uDDB8\uDDB9\uDDCD\uDDCF\uDDD4\uDDD6-\uDDDD](?:\uD83C[\uDFFB-\uDFFF])?(?:\u200D[\u2640\u2642]\uFE0F?)?|[\uDDDE\uDDDF](?:\u200D[\u2640\u2642]\uFE0F?)?|[\uDD0D\uDD0E\uDD10-\uDD17\uDD20-\uDD25\uDD27-\uDD2F\uDD3A\uDD3F-\uDD45\uDD47-\uDD76\uDD78-\uDDB4\uDDB7\uDDBA\uDDBC-\uDDCC\uDDD0\uDDE0-\uDDFF\uDE70-\uDE7C\uDE80-\uDE8A\uDE8E-\uDEC2\uDEC6\uDEC8\uDECD-\uDEDC\uDEDF-\uDEEA\uDEEF]|\uDDCE(?:\uD83C[\uDFFB-\uDFFF])?(?:\u200D(?:[\u2640\u2642]\uFE0F?(?:\u200D\u27A1\uFE0F?)?|\u27A1\uFE0F?))?|\uDDD1(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\uD83C[\uDF3E\uDF73\uDF7C\uDF84\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3\uDE70]|\uDD1D\u200D\uD83E\uDDD1|\uDDD1\u200D\uD83E\uDDD2(?:\u200D\uD83E\uDDD2)?|\uDDD2(?:\u200D\uD83E\uDDD2)?))|\uD83C(?:\uDFFB(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D(?:\uD83D\uDC8B\u200D)?\uD83E\uDDD1\uD83C[\uDFFC-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF84\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83E\uDDD1\uD83C[\uDFFC-\uDFFF])|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3\uDE70]|\uDD1D\u200D\uD83E\uDDD1\uD83C[\uDFFB-\uDFFF]|\uDEEF\u200D\uD83E\uDDD1\uD83C[\uDFFC-\uDFFF])))?|\uDFFC(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D(?:\uD83D\uDC8B\u200D)?\uD83E\uDDD1\uD83C[\uDFFB\uDFFD-\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF84\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83E\uDDD1\uD83C[\uDFFB\uDFFD-\uDFFF])|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3\uDE70]|\uDD1D\u200D\uD83E\uDDD1\uD83C[\uDFFB-\uDFFF]|\uDEEF\u200D\uD83E\uDDD1\uD83C[\uDFFB\uDFFD-\uDFFF])))?|\uDFFD(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D(?:\uD83D\uDC8B\u200D)?\uD83E\uDDD1\uD83C[\uDFFB\uDFFC\uDFFE\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF84\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83E\uDDD1\uD83C[\uDFFB\uDFFC\uDFFE\uDFFF])|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3\uDE70]|\uDD1D\u200D\uD83E\uDDD1\uD83C[\uDFFB-\uDFFF]|\uDEEF\u200D\uD83E\uDDD1\uD83C[\uDFFB\uDFFC\uDFFE\uDFFF])))?|\uDFFE(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D(?:\uD83D\uDC8B\u200D)?\uD83E\uDDD1\uD83C[\uDFFB-\uDFFD\uDFFF]|\uD83C[\uDF3E\uDF73\uDF7C\uDF84\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83E\uDDD1\uD83C[\uDFFB-\uDFFD\uDFFF])|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3\uDE70]|\uDD1D\u200D\uD83E\uDDD1\uD83C[\uDFFB-\uDFFF]|\uDEEF\u200D\uD83E\uDDD1\uD83C[\uDFFB-\uDFFD\uDFFF])))?|\uDFFF(?:\u200D(?:[\u2695\u2696\u2708]\uFE0F?|\u2764\uFE0F?\u200D(?:\uD83D\uDC8B\u200D)?\uD83E\uDDD1\uD83C[\uDFFB-\uDFFE]|\uD83C[\uDF3E\uDF73\uDF7C\uDF84\uDF93\uDFA4\uDFA8\uDFEB\uDFED]|\uD83D(?:[\uDCBB\uDCBC\uDD27\uDD2C\uDE80\uDE92]|\uDC30\u200D\uD83E\uDDD1\uD83C[\uDFFB-\uDFFE])|\uD83E(?:[\uDDAF\uDDBC\uDDBD](?:\u200D\u27A1\uFE0F?)?|[\uDDB0-\uDDB3\uDE70]|\uDD1D\u200D\uD83E\uDDD1\uD83C[\uDFFB-\uDFFF]|\uDEEF\u200D\uD83E\uDDD1\uD83C[\uDFFB-\uDFFE])))?))?|\uDEF1(?:\uD83C(?:\uDFFB(?:\u200D\uD83E\uDEF2\uD83C[\uDFFC-\uDFFF])?|\uDFFC(?:\u200D\uD83E\uDEF2\uD83C[\uDFFB\uDFFD-\uDFFF])?|\uDFFD(?:\u200D\uD83E\uDEF2\uD83C[\uDFFB\uDFFC\uDFFE\uDFFF])?|\uDFFE(?:\u200D\uD83E\uDEF2\uD83C[\uDFFB-\uDFFD\uDFFF])?|\uDFFF(?:\u200D\uD83E\uDEF2\uD83C[\uDFFB-\uDFFE])?))?)/g;
};

// node_modules/string-width/index.js
var segmenter = new Intl.Segmenter;
var defaultIgnorableCodePointRegex = /^\p{Default_Ignorable_Code_Point}$/u;
function stringWidth(string, options = {}) {
  if (typeof string !== "string" || string.length === 0) {
    return 0;
  }
  const {
    ambiguousIsNarrow = true,
    countAnsiEscapeCodes = false
  } = options;
  if (!countAnsiEscapeCodes) {
    string = stripAnsi(string);
  }
  if (string.length === 0) {
    return 0;
  }
  let width = 0;
  const eastAsianWidthOptions = { ambiguousAsWide: !ambiguousIsNarrow };
  for (const { segment: character } of segmenter.segment(string)) {
    const codePoint = character.codePointAt(0);
    if (codePoint <= 31 || codePoint >= 127 && codePoint <= 159) {
      continue;
    }
    if (codePoint >= 8203 && codePoint <= 8207 || codePoint === 65279) {
      continue;
    }
    if (codePoint >= 768 && codePoint <= 879 || codePoint >= 6832 && codePoint <= 6911 || codePoint >= 7616 && codePoint <= 7679 || codePoint >= 8400 && codePoint <= 8447 || codePoint >= 65056 && codePoint <= 65071) {
      continue;
    }
    if (codePoint >= 55296 && codePoint <= 57343) {
      continue;
    }
    if (codePoint >= 65024 && codePoint <= 65039) {
      continue;
    }
    if (defaultIgnorableCodePointRegex.test(character)) {
      continue;
    }
    if (emoji_regex_default().test(character)) {
      width += 2;
      continue;
    }
    width += eastAsianWidth(codePoint, eastAsianWidthOptions);
  }
  return width;
}

// node_modules/ansi-styles/index.js
var ANSI_BACKGROUND_OFFSET = 10;
var wrapAnsi16 = (offset = 0) => (code) => `\x1B[${code + offset}m`;
var wrapAnsi256 = (offset = 0) => (code) => `\x1B[${38 + offset};5;${code}m`;
var wrapAnsi16m = (offset = 0) => (red, green, blue) => `\x1B[${38 + offset};2;${red};${green};${blue}m`;
var styles = {
  modifier: {
    reset: [0, 0],
    bold: [1, 22],
    dim: [2, 22],
    italic: [3, 23],
    underline: [4, 24],
    overline: [53, 55],
    inverse: [7, 27],
    hidden: [8, 28],
    strikethrough: [9, 29]
  },
  color: {
    black: [30, 39],
    red: [31, 39],
    green: [32, 39],
    yellow: [33, 39],
    blue: [34, 39],
    magenta: [35, 39],
    cyan: [36, 39],
    white: [37, 39],
    blackBright: [90, 39],
    gray: [90, 39],
    grey: [90, 39],
    redBright: [91, 39],
    greenBright: [92, 39],
    yellowBright: [93, 39],
    blueBright: [94, 39],
    magentaBright: [95, 39],
    cyanBright: [96, 39],
    whiteBright: [97, 39]
  },
  bgColor: {
    bgBlack: [40, 49],
    bgRed: [41, 49],
    bgGreen: [42, 49],
    bgYellow: [43, 49],
    bgBlue: [44, 49],
    bgMagenta: [45, 49],
    bgCyan: [46, 49],
    bgWhite: [47, 49],
    bgBlackBright: [100, 49],
    bgGray: [100, 49],
    bgGrey: [100, 49],
    bgRedBright: [101, 49],
    bgGreenBright: [102, 49],
    bgYellowBright: [103, 49],
    bgBlueBright: [104, 49],
    bgMagentaBright: [105, 49],
    bgCyanBright: [106, 49],
    bgWhiteBright: [107, 49]
  }
};
var modifierNames = Object.keys(styles.modifier);
var foregroundColorNames = Object.keys(styles.color);
var backgroundColorNames = Object.keys(styles.bgColor);
var colorNames = [...foregroundColorNames, ...backgroundColorNames];
function assembleStyles() {
  const codes = new Map;
  for (const [groupName, group] of Object.entries(styles)) {
    for (const [styleName, style] of Object.entries(group)) {
      styles[styleName] = {
        open: `\x1B[${style[0]}m`,
        close: `\x1B[${style[1]}m`
      };
      group[styleName] = styles[styleName];
      codes.set(style[0], style[1]);
    }
    Object.defineProperty(styles, groupName, {
      value: group,
      enumerable: false
    });
  }
  Object.defineProperty(styles, "codes", {
    value: codes,
    enumerable: false
  });
  styles.color.close = "\x1B[39m";
  styles.bgColor.close = "\x1B[49m";
  styles.color.ansi = wrapAnsi16();
  styles.color.ansi256 = wrapAnsi256();
  styles.color.ansi16m = wrapAnsi16m();
  styles.bgColor.ansi = wrapAnsi16(ANSI_BACKGROUND_OFFSET);
  styles.bgColor.ansi256 = wrapAnsi256(ANSI_BACKGROUND_OFFSET);
  styles.bgColor.ansi16m = wrapAnsi16m(ANSI_BACKGROUND_OFFSET);
  Object.defineProperties(styles, {
    rgbToAnsi256: {
      value(red, green, blue) {
        if (red === green && green === blue) {
          if (red < 8) {
            return 16;
          }
          if (red > 248) {
            return 231;
          }
          return Math.round((red - 8) / 247 * 24) + 232;
        }
        return 16 + 36 * Math.round(red / 255 * 5) + 6 * Math.round(green / 255 * 5) + Math.round(blue / 255 * 5);
      },
      enumerable: false
    },
    hexToRgb: {
      value(hex) {
        const matches = /[a-f\d]{6}|[a-f\d]{3}/i.exec(hex.toString(16));
        if (!matches) {
          return [0, 0, 0];
        }
        let [colorString] = matches;
        if (colorString.length === 3) {
          colorString = [...colorString].map((character) => character + character).join("");
        }
        const integer = Number.parseInt(colorString, 16);
        return [
          integer >> 16 & 255,
          integer >> 8 & 255,
          integer & 255
        ];
      },
      enumerable: false
    },
    hexToAnsi256: {
      value: (hex) => styles.rgbToAnsi256(...styles.hexToRgb(hex)),
      enumerable: false
    },
    ansi256ToAnsi: {
      value(code) {
        if (code < 8) {
          return 30 + code;
        }
        if (code < 16) {
          return 90 + (code - 8);
        }
        let red;
        let green;
        let blue;
        if (code >= 232) {
          red = ((code - 232) * 10 + 8) / 255;
          green = red;
          blue = red;
        } else {
          code -= 16;
          const remainder = code % 36;
          red = Math.floor(code / 36) / 5;
          green = Math.floor(remainder / 6) / 5;
          blue = remainder % 6 / 5;
        }
        const value = Math.max(red, green, blue) * 2;
        if (value === 0) {
          return 30;
        }
        let result = 30 + (Math.round(blue) << 2 | Math.round(green) << 1 | Math.round(red));
        if (value === 2) {
          result += 60;
        }
        return result;
      },
      enumerable: false
    },
    rgbToAnsi: {
      value: (red, green, blue) => styles.ansi256ToAnsi(styles.rgbToAnsi256(red, green, blue)),
      enumerable: false
    },
    hexToAnsi: {
      value: (hex) => styles.ansi256ToAnsi(styles.hexToAnsi256(hex)),
      enumerable: false
    }
  });
  return styles;
}
var ansiStyles = assembleStyles();
var ansi_styles_default = ansiStyles;

// node_modules/wrap-ansi/index.js
var ESCAPES = new Set([
  "\x1B",
  "\x9B"
]);
var END_CODE = 39;
var ANSI_ESCAPE_BELL = "\x07";
var ANSI_CSI = "[";
var ANSI_OSC = "]";
var ANSI_SGR_TERMINATOR = "m";
var ANSI_ESCAPE_LINK = `${ANSI_OSC}8;;`;
var wrapAnsiCode = (code) => `${ESCAPES.values().next().value}${ANSI_CSI}${code}${ANSI_SGR_TERMINATOR}`;
var wrapAnsiHyperlink = (url) => `${ESCAPES.values().next().value}${ANSI_ESCAPE_LINK}${url}${ANSI_ESCAPE_BELL}`;
var wordLengths = (string) => string.split(" ").map((character) => stringWidth(character));
var wrapWord = (rows, word, columns) => {
  const characters = [...word];
  let isInsideEscape = false;
  let isInsideLinkEscape = false;
  let visible = stringWidth(stripAnsi(rows.at(-1)));
  for (const [index, character] of characters.entries()) {
    const characterLength = stringWidth(character);
    if (visible + characterLength <= columns) {
      rows[rows.length - 1] += character;
    } else {
      rows.push(character);
      visible = 0;
    }
    if (ESCAPES.has(character)) {
      isInsideEscape = true;
      const ansiEscapeLinkCandidate = characters.slice(index + 1, index + 1 + ANSI_ESCAPE_LINK.length).join("");
      isInsideLinkEscape = ansiEscapeLinkCandidate === ANSI_ESCAPE_LINK;
    }
    if (isInsideEscape) {
      if (isInsideLinkEscape) {
        if (character === ANSI_ESCAPE_BELL) {
          isInsideEscape = false;
          isInsideLinkEscape = false;
        }
      } else if (character === ANSI_SGR_TERMINATOR) {
        isInsideEscape = false;
      }
      continue;
    }
    visible += characterLength;
    if (visible === columns && index < characters.length - 1) {
      rows.push("");
      visible = 0;
    }
  }
  if (!visible && rows.at(-1).length > 0 && rows.length > 1) {
    rows[rows.length - 2] += rows.pop();
  }
};
var stringVisibleTrimSpacesRight = (string) => {
  const words = string.split(" ");
  let last = words.length;
  while (last > 0) {
    if (stringWidth(words[last - 1]) > 0) {
      break;
    }
    last--;
  }
  if (last === words.length) {
    return string;
  }
  return words.slice(0, last).join(" ") + words.slice(last).join("");
};
var exec = (string, columns, options = {}) => {
  if (options.trim !== false && string.trim() === "") {
    return "";
  }
  let returnValue = "";
  let escapeCode;
  let escapeUrl;
  const lengths = wordLengths(string);
  let rows = [""];
  for (const [index, word] of string.split(" ").entries()) {
    if (options.trim !== false) {
      rows[rows.length - 1] = rows.at(-1).trimStart();
    }
    let rowLength = stringWidth(rows.at(-1));
    if (index !== 0) {
      if (rowLength >= columns && (options.wordWrap === false || options.trim === false)) {
        rows.push("");
        rowLength = 0;
      }
      if (rowLength > 0 || options.trim === false) {
        rows[rows.length - 1] += " ";
        rowLength++;
      }
    }
    if (options.hard && lengths[index] > columns) {
      const remainingColumns = columns - rowLength;
      const breaksStartingThisLine = 1 + Math.floor((lengths[index] - remainingColumns - 1) / columns);
      const breaksStartingNextLine = Math.floor((lengths[index] - 1) / columns);
      if (breaksStartingNextLine < breaksStartingThisLine) {
        rows.push("");
      }
      wrapWord(rows, word, columns);
      continue;
    }
    if (rowLength + lengths[index] > columns && rowLength > 0 && lengths[index] > 0) {
      if (options.wordWrap === false && rowLength < columns) {
        wrapWord(rows, word, columns);
        continue;
      }
      rows.push("");
    }
    if (rowLength + lengths[index] > columns && options.wordWrap === false) {
      wrapWord(rows, word, columns);
      continue;
    }
    rows[rows.length - 1] += word;
  }
  if (options.trim !== false) {
    rows = rows.map((row) => stringVisibleTrimSpacesRight(row));
  }
  const preString = rows.join(`
`);
  const pre = [...preString];
  let preStringIndex = 0;
  for (const [index, character] of pre.entries()) {
    returnValue += character;
    if (ESCAPES.has(character)) {
      const { groups } = new RegExp(`(?:\\${ANSI_CSI}(?<code>\\d+)m|\\${ANSI_ESCAPE_LINK}(?<uri>.*)${ANSI_ESCAPE_BELL})`).exec(preString.slice(preStringIndex)) || { groups: {} };
      if (groups.code !== undefined) {
        const code2 = Number.parseFloat(groups.code);
        escapeCode = code2 === END_CODE ? undefined : code2;
      } else if (groups.uri !== undefined) {
        escapeUrl = groups.uri.length === 0 ? undefined : groups.uri;
      }
    }
    const code = ansi_styles_default.codes.get(Number(escapeCode));
    if (pre[index + 1] === `
`) {
      if (escapeUrl) {
        returnValue += wrapAnsiHyperlink("");
      }
      if (escapeCode && code) {
        returnValue += wrapAnsiCode(code);
      }
    } else if (character === `
`) {
      if (escapeCode && code) {
        returnValue += wrapAnsiCode(escapeCode);
      }
      if (escapeUrl) {
        returnValue += wrapAnsiHyperlink(escapeUrl);
      }
    }
    preStringIndex += character.length;
  }
  return returnValue;
};
function wrapAnsi(string, columns, options) {
  return String(string).normalize().replaceAll(`\r
`, `
`).split(`
`).map((line) => exec(line, columns, options)).join(`
`);
}

// node_modules/cliui/index.mjs
function ui(opts) {
  return cliui(opts, {
    stringWidth,
    stripAnsi,
    wrap: wrapAnsi
  });
}

// node_modules/escalade/sync/index.mjs
import { dirname, resolve } from "path";
import { readdirSync, statSync } from "fs";
function sync_default(start, callback) {
  let dir = resolve(".", start);
  let tmp, stats = statSync(dir);
  if (!stats.isDirectory()) {
    dir = dirname(dir);
  }
  while (true) {
    tmp = callback(dir, readdirSync(dir));
    if (tmp)
      return resolve(dir, tmp);
    dir = dirname(tmp = dir);
    if (tmp === dir)
      break;
  }
}

// node_modules/yargs/lib/platform-shims/esm.mjs
import { inspect } from "util";
import { fileURLToPath } from "url";

// node_modules/yargs-parser/build/lib/index.js
import { format } from "util";
import { normalize, resolve as resolve2 } from "path";

// node_modules/yargs-parser/build/lib/string-utils.js
function camelCase(str) {
  const isCamelCase = str !== str.toLowerCase() && str !== str.toUpperCase();
  if (!isCamelCase) {
    str = str.toLowerCase();
  }
  if (str.indexOf("-") === -1 && str.indexOf("_") === -1) {
    return str;
  } else {
    let camelcase = "";
    let nextChrUpper = false;
    const leadingHyphens = str.match(/^-+/);
    for (let i = leadingHyphens ? leadingHyphens[0].length : 0;i < str.length; i++) {
      let chr = str.charAt(i);
      if (nextChrUpper) {
        nextChrUpper = false;
        chr = chr.toUpperCase();
      }
      if (i !== 0 && (chr === "-" || chr === "_")) {
        nextChrUpper = true;
      } else if (chr !== "-" && chr !== "_") {
        camelcase += chr;
      }
    }
    return camelcase;
  }
}
function decamelize(str, joinString) {
  const lowercase = str.toLowerCase();
  joinString = joinString || "-";
  let notCamelcase = "";
  for (let i = 0;i < str.length; i++) {
    const chrLower = lowercase.charAt(i);
    const chrString = str.charAt(i);
    if (chrLower !== chrString && i > 0) {
      notCamelcase += `${joinString}${lowercase.charAt(i)}`;
    } else {
      notCamelcase += chrString;
    }
  }
  return notCamelcase;
}
function looksLikeNumber(x) {
  if (x === null || x === undefined)
    return false;
  if (typeof x === "number")
    return true;
  if (/^0x[0-9a-f]+$/i.test(x))
    return true;
  if (/^0[^.]/.test(x))
    return false;
  return /^[-]?(?:\d+(?:\.\d*)?|\.\d+)(e[-+]?\d+)?$/.test(x);
}

// node_modules/yargs-parser/build/lib/tokenize-arg-string.js
function tokenizeArgString(argString) {
  if (Array.isArray(argString)) {
    return argString.map((e) => typeof e !== "string" ? e + "" : e);
  }
  argString = argString.trim();
  let i = 0;
  let prevC = null;
  let c = null;
  let opening = null;
  const args = [];
  for (let ii = 0;ii < argString.length; ii++) {
    prevC = c;
    c = argString.charAt(ii);
    if (c === " " && !opening) {
      if (!(prevC === " ")) {
        i++;
      }
      continue;
    }
    if (c === opening) {
      opening = null;
    } else if ((c === "'" || c === '"') && !opening) {
      opening = c;
    }
    if (!args[i])
      args[i] = "";
    args[i] += c;
  }
  return args;
}

// node_modules/yargs-parser/build/lib/yargs-parser-types.js
var DefaultValuesForTypeKey;
(function(DefaultValuesForTypeKey2) {
  DefaultValuesForTypeKey2["BOOLEAN"] = "boolean";
  DefaultValuesForTypeKey2["STRING"] = "string";
  DefaultValuesForTypeKey2["NUMBER"] = "number";
  DefaultValuesForTypeKey2["ARRAY"] = "array";
})(DefaultValuesForTypeKey || (DefaultValuesForTypeKey = {}));

// node_modules/yargs-parser/build/lib/yargs-parser.js
var mixin2;

class YargsParser {
  constructor(_mixin) {
    mixin2 = _mixin;
  }
  parse(argsInput, options) {
    const opts = Object.assign({
      alias: undefined,
      array: undefined,
      boolean: undefined,
      config: undefined,
      configObjects: undefined,
      configuration: undefined,
      coerce: undefined,
      count: undefined,
      default: undefined,
      envPrefix: undefined,
      narg: undefined,
      normalize: undefined,
      string: undefined,
      number: undefined,
      __: undefined,
      key: undefined
    }, options);
    const args = tokenizeArgString(argsInput);
    const inputIsString = typeof argsInput === "string";
    const aliases = combineAliases(Object.assign(Object.create(null), opts.alias));
    const configuration = Object.assign({
      "boolean-negation": true,
      "camel-case-expansion": true,
      "combine-arrays": false,
      "dot-notation": true,
      "duplicate-arguments-array": true,
      "flatten-duplicate-arrays": true,
      "greedy-arrays": true,
      "halt-at-non-option": false,
      "nargs-eats-options": false,
      "negation-prefix": "no-",
      "parse-numbers": true,
      "parse-positional-numbers": true,
      "populate--": false,
      "set-placeholder-key": false,
      "short-option-groups": true,
      "strip-aliased": false,
      "strip-dashed": false,
      "unknown-options-as-args": false
    }, opts.configuration);
    const defaults = Object.assign(Object.create(null), opts.default);
    const configObjects = opts.configObjects || [];
    const envPrefix = opts.envPrefix;
    const notFlagsOption = configuration["populate--"];
    const notFlagsArgv = notFlagsOption ? "--" : "_";
    const newAliases = Object.create(null);
    const defaulted = Object.create(null);
    const __ = opts.__ || mixin2.format;
    const flags = {
      aliases: Object.create(null),
      arrays: Object.create(null),
      bools: Object.create(null),
      strings: Object.create(null),
      numbers: Object.create(null),
      counts: Object.create(null),
      normalize: Object.create(null),
      configs: Object.create(null),
      nargs: Object.create(null),
      coercions: Object.create(null),
      keys: []
    };
    const negative = /^-([0-9]+(\.[0-9]+)?|\.[0-9]+)$/;
    const negatedBoolean = new RegExp("^--" + configuration["negation-prefix"] + "(.+)");
    [].concat(opts.array || []).filter(Boolean).forEach(function(opt) {
      const key = typeof opt === "object" ? opt.key : opt;
      const assignment = Object.keys(opt).map(function(key2) {
        const arrayFlagKeys = {
          boolean: "bools",
          string: "strings",
          number: "numbers"
        };
        return arrayFlagKeys[key2];
      }).filter(Boolean).pop();
      if (assignment) {
        flags[assignment][key] = true;
      }
      flags.arrays[key] = true;
      flags.keys.push(key);
    });
    [].concat(opts.boolean || []).filter(Boolean).forEach(function(key) {
      flags.bools[key] = true;
      flags.keys.push(key);
    });
    [].concat(opts.string || []).filter(Boolean).forEach(function(key) {
      flags.strings[key] = true;
      flags.keys.push(key);
    });
    [].concat(opts.number || []).filter(Boolean).forEach(function(key) {
      flags.numbers[key] = true;
      flags.keys.push(key);
    });
    [].concat(opts.count || []).filter(Boolean).forEach(function(key) {
      flags.counts[key] = true;
      flags.keys.push(key);
    });
    [].concat(opts.normalize || []).filter(Boolean).forEach(function(key) {
      flags.normalize[key] = true;
      flags.keys.push(key);
    });
    if (typeof opts.narg === "object") {
      Object.entries(opts.narg).forEach(([key, value]) => {
        if (typeof value === "number") {
          flags.nargs[key] = value;
          flags.keys.push(key);
        }
      });
    }
    if (typeof opts.coerce === "object") {
      Object.entries(opts.coerce).forEach(([key, value]) => {
        if (typeof value === "function") {
          flags.coercions[key] = value;
          flags.keys.push(key);
        }
      });
    }
    if (typeof opts.config !== "undefined") {
      if (Array.isArray(opts.config) || typeof opts.config === "string") {
        [].concat(opts.config).filter(Boolean).forEach(function(key) {
          flags.configs[key] = true;
        });
      } else if (typeof opts.config === "object") {
        Object.entries(opts.config).forEach(([key, value]) => {
          if (typeof value === "boolean" || typeof value === "function") {
            flags.configs[key] = value;
          }
        });
      }
    }
    extendAliases(opts.key, aliases, opts.default, flags.arrays);
    Object.keys(defaults).forEach(function(key) {
      (flags.aliases[key] || []).forEach(function(alias) {
        defaults[alias] = defaults[key];
      });
    });
    let error = null;
    checkConfiguration();
    let notFlags = [];
    const argv = Object.assign(Object.create(null), { _: [] });
    const argvReturn = {};
    for (let i = 0;i < args.length; i++) {
      const arg = args[i];
      const truncatedArg = arg.replace(/^-{3,}/, "---");
      let broken;
      let key;
      let letters;
      let m;
      let next;
      let value;
      if (arg !== "--" && /^-/.test(arg) && isUnknownOptionAsArg(arg)) {
        pushPositional(arg);
      } else if (truncatedArg.match(/^---+(=|$)/)) {
        pushPositional(arg);
        continue;
      } else if (arg.match(/^--.+=/) || !configuration["short-option-groups"] && arg.match(/^-.+=/)) {
        m = arg.match(/^--?([^=]+)=([\s\S]*)$/);
        if (m !== null && Array.isArray(m) && m.length >= 3) {
          if (checkAllAliases(m[1], flags.arrays)) {
            i = eatArray(i, m[1], args, m[2]);
          } else if (checkAllAliases(m[1], flags.nargs) !== false) {
            i = eatNargs(i, m[1], args, m[2]);
          } else {
            setArg(m[1], m[2], true);
          }
        }
      } else if (arg.match(negatedBoolean) && configuration["boolean-negation"]) {
        m = arg.match(negatedBoolean);
        if (m !== null && Array.isArray(m) && m.length >= 2) {
          key = m[1];
          setArg(key, checkAllAliases(key, flags.arrays) ? [false] : false);
        }
      } else if (arg.match(/^--.+/) || !configuration["short-option-groups"] && arg.match(/^-[^-]+/)) {
        m = arg.match(/^--?(.+)/);
        if (m !== null && Array.isArray(m) && m.length >= 2) {
          key = m[1];
          if (checkAllAliases(key, flags.arrays)) {
            i = eatArray(i, key, args);
          } else if (checkAllAliases(key, flags.nargs) !== false) {
            i = eatNargs(i, key, args);
          } else {
            next = args[i + 1];
            if (next !== undefined && (!next.match(/^-/) || next.match(negative)) && !checkAllAliases(key, flags.bools) && !checkAllAliases(key, flags.counts)) {
              setArg(key, next);
              i++;
            } else if (/^(true|false)$/.test(next)) {
              setArg(key, next);
              i++;
            } else {
              setArg(key, defaultValue(key));
            }
          }
        }
      } else if (arg.match(/^-.\..+=/)) {
        m = arg.match(/^-([^=]+)=([\s\S]*)$/);
        if (m !== null && Array.isArray(m) && m.length >= 3) {
          setArg(m[1], m[2]);
        }
      } else if (arg.match(/^-.\..+/) && !arg.match(negative)) {
        next = args[i + 1];
        m = arg.match(/^-(.\..+)/);
        if (m !== null && Array.isArray(m) && m.length >= 2) {
          key = m[1];
          if (next !== undefined && !next.match(/^-/) && !checkAllAliases(key, flags.bools) && !checkAllAliases(key, flags.counts)) {
            setArg(key, next);
            i++;
          } else {
            setArg(key, defaultValue(key));
          }
        }
      } else if (arg.match(/^-[^-]+/) && !arg.match(negative)) {
        letters = arg.slice(1, -1).split("");
        broken = false;
        for (let j = 0;j < letters.length; j++) {
          next = arg.slice(j + 2);
          if (letters[j + 1] && letters[j + 1] === "=") {
            value = arg.slice(j + 3);
            key = letters[j];
            if (checkAllAliases(key, flags.arrays)) {
              i = eatArray(i, key, args, value);
            } else if (checkAllAliases(key, flags.nargs) !== false) {
              i = eatNargs(i, key, args, value);
            } else {
              setArg(key, value);
            }
            broken = true;
            break;
          }
          if (next === "-") {
            setArg(letters[j], next);
            continue;
          }
          if (/[A-Za-z]/.test(letters[j]) && /^-?\d+(\.\d*)?(e-?\d+)?$/.test(next) && checkAllAliases(next, flags.bools) === false) {
            setArg(letters[j], next);
            broken = true;
            break;
          }
          if (letters[j + 1] && letters[j + 1].match(/\W/)) {
            setArg(letters[j], next);
            broken = true;
            break;
          } else {
            setArg(letters[j], defaultValue(letters[j]));
          }
        }
        key = arg.slice(-1)[0];
        if (!broken && key !== "-") {
          if (checkAllAliases(key, flags.arrays)) {
            i = eatArray(i, key, args);
          } else if (checkAllAliases(key, flags.nargs) !== false) {
            i = eatNargs(i, key, args);
          } else {
            next = args[i + 1];
            if (next !== undefined && (!/^(-|--)[^-]/.test(next) || next.match(negative)) && !checkAllAliases(key, flags.bools) && !checkAllAliases(key, flags.counts)) {
              setArg(key, next);
              i++;
            } else if (/^(true|false)$/.test(next)) {
              setArg(key, next);
              i++;
            } else {
              setArg(key, defaultValue(key));
            }
          }
        }
      } else if (arg.match(/^-[0-9]$/) && arg.match(negative) && checkAllAliases(arg.slice(1), flags.bools)) {
        key = arg.slice(1);
        setArg(key, defaultValue(key));
      } else if (arg === "--") {
        notFlags = args.slice(i + 1);
        break;
      } else if (configuration["halt-at-non-option"]) {
        notFlags = args.slice(i);
        break;
      } else {
        pushPositional(arg);
      }
    }
    applyEnvVars(argv, true);
    applyEnvVars(argv, false);
    setConfig(argv);
    setConfigObjects();
    applyDefaultsAndAliases(argv, flags.aliases, defaults, true);
    applyCoercions(argv);
    if (configuration["set-placeholder-key"])
      setPlaceholderKeys(argv);
    Object.keys(flags.counts).forEach(function(key) {
      if (!hasKey(argv, key.split(".")))
        setArg(key, 0);
    });
    if (notFlagsOption && notFlags.length)
      argv[notFlagsArgv] = [];
    notFlags.forEach(function(key) {
      argv[notFlagsArgv].push(key);
    });
    if (configuration["camel-case-expansion"] && configuration["strip-dashed"]) {
      Object.keys(argv).filter((key) => key !== "--" && key.includes("-")).forEach((key) => {
        delete argv[key];
      });
    }
    if (configuration["strip-aliased"]) {
      [].concat(...Object.keys(aliases).map((k) => aliases[k])).forEach((alias) => {
        if (configuration["camel-case-expansion"] && alias.includes("-")) {
          delete argv[alias.split(".").map((prop) => camelCase(prop)).join(".")];
        }
        delete argv[alias];
      });
    }
    function pushPositional(arg) {
      const maybeCoercedNumber = maybeCoerceNumber("_", arg);
      if (typeof maybeCoercedNumber === "string" || typeof maybeCoercedNumber === "number") {
        argv._.push(maybeCoercedNumber);
      }
    }
    function eatNargs(i, key, args2, argAfterEqualSign) {
      let ii;
      let toEat = checkAllAliases(key, flags.nargs);
      toEat = typeof toEat !== "number" || isNaN(toEat) ? 1 : toEat;
      if (toEat === 0) {
        if (!isUndefined(argAfterEqualSign)) {
          error = Error(__("Argument unexpected for: %s", key));
        }
        setArg(key, defaultValue(key));
        return i;
      }
      let available = isUndefined(argAfterEqualSign) ? 0 : 1;
      if (configuration["nargs-eats-options"]) {
        if (args2.length - (i + 1) + available < toEat) {
          error = Error(__("Not enough arguments following: %s", key));
        }
        available = toEat;
      } else {
        for (ii = i + 1;ii < args2.length; ii++) {
          if (!args2[ii].match(/^-[^0-9]/) || args2[ii].match(negative) || isUnknownOptionAsArg(args2[ii]))
            available++;
          else
            break;
        }
        if (available < toEat)
          error = Error(__("Not enough arguments following: %s", key));
      }
      let consumed = Math.min(available, toEat);
      if (!isUndefined(argAfterEqualSign) && consumed > 0) {
        setArg(key, argAfterEqualSign);
        consumed--;
      }
      for (ii = i + 1;ii < consumed + i + 1; ii++) {
        setArg(key, args2[ii]);
      }
      return i + consumed;
    }
    function eatArray(i, key, args2, argAfterEqualSign) {
      let argsToSet = [];
      let next = argAfterEqualSign || args2[i + 1];
      const nargsCount = checkAllAliases(key, flags.nargs);
      if (checkAllAliases(key, flags.bools) && !/^(true|false)$/.test(next)) {
        argsToSet.push(true);
      } else if (isUndefined(next) || isUndefined(argAfterEqualSign) && /^-/.test(next) && !negative.test(next) && !isUnknownOptionAsArg(next)) {
        if (defaults[key] !== undefined) {
          const defVal = defaults[key];
          argsToSet = Array.isArray(defVal) ? defVal : [defVal];
        }
      } else {
        if (!isUndefined(argAfterEqualSign)) {
          argsToSet.push(processValue(key, argAfterEqualSign, true));
        }
        for (let ii = i + 1;ii < args2.length; ii++) {
          if (!configuration["greedy-arrays"] && argsToSet.length > 0 || nargsCount && typeof nargsCount === "number" && argsToSet.length >= nargsCount)
            break;
          next = args2[ii];
          if (/^-/.test(next) && !negative.test(next) && !isUnknownOptionAsArg(next))
            break;
          i = ii;
          argsToSet.push(processValue(key, next, inputIsString));
        }
      }
      if (typeof nargsCount === "number" && (nargsCount && argsToSet.length < nargsCount || isNaN(nargsCount) && argsToSet.length === 0)) {
        error = Error(__("Not enough arguments following: %s", key));
      }
      setArg(key, argsToSet);
      return i;
    }
    function setArg(key, val, shouldStripQuotes = inputIsString) {
      if (/-/.test(key) && configuration["camel-case-expansion"]) {
        const alias = key.split(".").map(function(prop) {
          return camelCase(prop);
        }).join(".");
        addNewAlias(key, alias);
      }
      const value = processValue(key, val, shouldStripQuotes);
      const splitKey = key.split(".");
      setKey(argv, splitKey, value);
      if (flags.aliases[key]) {
        flags.aliases[key].forEach(function(x) {
          const keyProperties = x.split(".");
          setKey(argv, keyProperties, value);
        });
      }
      if (splitKey.length > 1 && configuration["dot-notation"]) {
        (flags.aliases[splitKey[0]] || []).forEach(function(x) {
          let keyProperties = x.split(".");
          const a = [].concat(splitKey);
          a.shift();
          keyProperties = keyProperties.concat(a);
          if (!(flags.aliases[key] || []).includes(keyProperties.join("."))) {
            setKey(argv, keyProperties, value);
          }
        });
      }
      if (checkAllAliases(key, flags.normalize) && !checkAllAliases(key, flags.arrays)) {
        const keys = [key].concat(flags.aliases[key] || []);
        keys.forEach(function(key2) {
          Object.defineProperty(argvReturn, key2, {
            enumerable: true,
            get() {
              return val;
            },
            set(value2) {
              val = typeof value2 === "string" ? mixin2.normalize(value2) : value2;
            }
          });
        });
      }
    }
    function addNewAlias(key, alias) {
      if (!(flags.aliases[key] && flags.aliases[key].length)) {
        flags.aliases[key] = [alias];
        newAliases[alias] = true;
      }
      if (!(flags.aliases[alias] && flags.aliases[alias].length)) {
        addNewAlias(alias, key);
      }
    }
    function processValue(key, val, shouldStripQuotes) {
      if (shouldStripQuotes) {
        val = stripQuotes(val);
      }
      if (checkAllAliases(key, flags.bools) || checkAllAliases(key, flags.counts)) {
        if (typeof val === "string")
          val = val === "true";
      }
      let value = Array.isArray(val) ? val.map(function(v) {
        return maybeCoerceNumber(key, v);
      }) : maybeCoerceNumber(key, val);
      if (checkAllAliases(key, flags.counts) && (isUndefined(value) || typeof value === "boolean")) {
        value = increment();
      }
      if (checkAllAliases(key, flags.normalize) && checkAllAliases(key, flags.arrays)) {
        if (Array.isArray(val))
          value = val.map((val2) => {
            return mixin2.normalize(val2);
          });
        else
          value = mixin2.normalize(val);
      }
      return value;
    }
    function maybeCoerceNumber(key, value) {
      if (!configuration["parse-positional-numbers"] && key === "_")
        return value;
      if (!checkAllAliases(key, flags.strings) && !checkAllAliases(key, flags.bools) && !Array.isArray(value)) {
        const shouldCoerceNumber = looksLikeNumber(value) && configuration["parse-numbers"] && Number.isSafeInteger(Math.floor(parseFloat(`${value}`)));
        if (shouldCoerceNumber || !isUndefined(value) && checkAllAliases(key, flags.numbers)) {
          value = Number(value);
        }
      }
      return value;
    }
    function setConfig(argv2) {
      const configLookup = Object.create(null);
      applyDefaultsAndAliases(configLookup, flags.aliases, defaults);
      Object.keys(flags.configs).forEach(function(configKey) {
        const configPath = argv2[configKey] || configLookup[configKey];
        if (configPath) {
          try {
            let config = null;
            const resolvedConfigPath = mixin2.resolve(mixin2.cwd(), configPath);
            const resolveConfig = flags.configs[configKey];
            if (typeof resolveConfig === "function") {
              try {
                config = resolveConfig(resolvedConfigPath);
              } catch (e) {
                config = e;
              }
              if (config instanceof Error) {
                error = config;
                return;
              }
            } else {
              config = mixin2.require(resolvedConfigPath);
            }
            setConfigObject(config);
          } catch (ex) {
            if (ex.name === "PermissionDenied")
              error = ex;
            else if (argv2[configKey])
              error = Error(__("Invalid JSON config file: %s", configPath));
          }
        }
      });
    }
    function setConfigObject(config, prev) {
      Object.keys(config).forEach(function(key) {
        const value = config[key];
        const fullKey = prev ? prev + "." + key : key;
        if (typeof value === "object" && value !== null && !Array.isArray(value) && configuration["dot-notation"]) {
          setConfigObject(value, fullKey);
        } else {
          if (!hasKey(argv, fullKey.split(".")) || checkAllAliases(fullKey, flags.arrays) && configuration["combine-arrays"]) {
            setArg(fullKey, value);
          }
        }
      });
    }
    function setConfigObjects() {
      if (typeof configObjects !== "undefined") {
        configObjects.forEach(function(configObject) {
          setConfigObject(configObject);
        });
      }
    }
    function applyEnvVars(argv2, configOnly) {
      if (typeof envPrefix === "undefined")
        return;
      const prefix = typeof envPrefix === "string" ? envPrefix : "";
      const env = mixin2.env();
      Object.keys(env).forEach(function(envVar) {
        if (prefix === "" || envVar.lastIndexOf(prefix, 0) === 0) {
          const keys = envVar.split("__").map(function(key, i) {
            if (i === 0) {
              key = key.substring(prefix.length);
            }
            return camelCase(key);
          });
          if ((configOnly && flags.configs[keys.join(".")] || !configOnly) && !hasKey(argv2, keys)) {
            setArg(keys.join("."), env[envVar]);
          }
        }
      });
    }
    function applyCoercions(argv2) {
      let coerce;
      const applied = new Set;
      Object.keys(argv2).forEach(function(key) {
        if (!applied.has(key)) {
          coerce = checkAllAliases(key, flags.coercions);
          if (typeof coerce === "function") {
            try {
              const value = maybeCoerceNumber(key, coerce(argv2[key]));
              [].concat(flags.aliases[key] || [], key).forEach((ali) => {
                applied.add(ali);
                argv2[ali] = value;
              });
            } catch (err) {
              error = err;
            }
          }
        }
      });
    }
    function setPlaceholderKeys(argv2) {
      flags.keys.forEach((key) => {
        if (~key.indexOf("."))
          return;
        if (typeof argv2[key] === "undefined")
          argv2[key] = undefined;
      });
      return argv2;
    }
    function applyDefaultsAndAliases(obj, aliases2, defaults2, canLog = false) {
      Object.keys(defaults2).forEach(function(key) {
        if (!hasKey(obj, key.split("."))) {
          setKey(obj, key.split("."), defaults2[key]);
          if (canLog)
            defaulted[key] = true;
          (aliases2[key] || []).forEach(function(x) {
            if (hasKey(obj, x.split(".")))
              return;
            setKey(obj, x.split("."), defaults2[key]);
          });
        }
      });
    }
    function hasKey(obj, keys) {
      let o = obj;
      if (!configuration["dot-notation"])
        keys = [keys.join(".")];
      keys.slice(0, -1).forEach(function(key2) {
        o = o[key2] || {};
      });
      const key = keys[keys.length - 1];
      if (typeof o !== "object")
        return false;
      else
        return key in o;
    }
    function setKey(obj, keys, value) {
      let o = obj;
      if (!configuration["dot-notation"])
        keys = [keys.join(".")];
      keys.slice(0, -1).forEach(function(key2) {
        key2 = sanitizeKey(key2);
        if (typeof o === "object" && o[key2] === undefined) {
          o[key2] = {};
        }
        if (typeof o[key2] !== "object" || Array.isArray(o[key2])) {
          if (Array.isArray(o[key2])) {
            o[key2].push({});
          } else {
            o[key2] = [o[key2], {}];
          }
          o = o[key2][o[key2].length - 1];
        } else {
          o = o[key2];
        }
      });
      const key = sanitizeKey(keys[keys.length - 1]);
      const isTypeArray = checkAllAliases(keys.join("."), flags.arrays);
      const isValueArray = Array.isArray(value);
      let duplicate = configuration["duplicate-arguments-array"];
      if (!duplicate && checkAllAliases(key, flags.nargs)) {
        duplicate = true;
        if (!isUndefined(o[key]) && flags.nargs[key] === 1 || Array.isArray(o[key]) && o[key].length === flags.nargs[key]) {
          o[key] = undefined;
        }
      }
      if (value === increment()) {
        o[key] = increment(o[key]);
      } else if (Array.isArray(o[key])) {
        if (duplicate && isTypeArray && isValueArray) {
          o[key] = configuration["flatten-duplicate-arrays"] ? o[key].concat(value) : (Array.isArray(o[key][0]) ? o[key] : [o[key]]).concat([value]);
        } else if (!duplicate && Boolean(isTypeArray) === Boolean(isValueArray)) {
          o[key] = value;
        } else {
          o[key] = o[key].concat([value]);
        }
      } else if (o[key] === undefined && isTypeArray) {
        o[key] = isValueArray ? value : [value];
      } else if (duplicate && !(o[key] === undefined || checkAllAliases(key, flags.counts) || checkAllAliases(key, flags.bools))) {
        o[key] = [o[key], value];
      } else {
        o[key] = value;
      }
    }
    function extendAliases(...args2) {
      args2.forEach(function(obj) {
        Object.keys(obj || {}).forEach(function(key) {
          if (flags.aliases[key])
            return;
          flags.aliases[key] = [].concat(aliases[key] || []);
          flags.aliases[key].concat(key).forEach(function(x) {
            if (/-/.test(x) && configuration["camel-case-expansion"]) {
              const c = camelCase(x);
              if (c !== key && flags.aliases[key].indexOf(c) === -1) {
                flags.aliases[key].push(c);
                newAliases[c] = true;
              }
            }
          });
          flags.aliases[key].concat(key).forEach(function(x) {
            if (x.length > 1 && /[A-Z]/.test(x) && configuration["camel-case-expansion"]) {
              const c = decamelize(x, "-");
              if (c !== key && flags.aliases[key].indexOf(c) === -1) {
                flags.aliases[key].push(c);
                newAliases[c] = true;
              }
            }
          });
          flags.aliases[key].forEach(function(x) {
            flags.aliases[x] = [key].concat(flags.aliases[key].filter(function(y) {
              return x !== y;
            }));
          });
        });
      });
    }
    function checkAllAliases(key, flag) {
      const toCheck = [].concat(flags.aliases[key] || [], key);
      const keys = Object.keys(flag);
      const setAlias = toCheck.find((key2) => keys.includes(key2));
      return setAlias ? flag[setAlias] : false;
    }
    function hasAnyFlag(key) {
      const flagsKeys = Object.keys(flags);
      const toCheck = [].concat(flagsKeys.map((k) => flags[k]));
      return toCheck.some(function(flag) {
        return Array.isArray(flag) ? flag.includes(key) : flag[key];
      });
    }
    function hasFlagsMatching(arg, ...patterns) {
      const toCheck = [].concat(...patterns);
      return toCheck.some(function(pattern) {
        const match = arg.match(pattern);
        return match && hasAnyFlag(match[1]);
      });
    }
    function hasAllShortFlags(arg) {
      if (arg.match(negative) || !arg.match(/^-[^-]+/)) {
        return false;
      }
      let hasAllFlags = true;
      let next;
      const letters = arg.slice(1).split("");
      for (let j = 0;j < letters.length; j++) {
        next = arg.slice(j + 2);
        if (!hasAnyFlag(letters[j])) {
          hasAllFlags = false;
          break;
        }
        if (letters[j + 1] && letters[j + 1] === "=" || next === "-" || /[A-Za-z]/.test(letters[j]) && /^-?\d+(\.\d*)?(e-?\d+)?$/.test(next) || letters[j + 1] && letters[j + 1].match(/\W/)) {
          break;
        }
      }
      return hasAllFlags;
    }
    function isUnknownOptionAsArg(arg) {
      return configuration["unknown-options-as-args"] && isUnknownOption(arg);
    }
    function isUnknownOption(arg) {
      arg = arg.replace(/^-{3,}/, "--");
      if (arg.match(negative)) {
        return false;
      }
      if (hasAllShortFlags(arg)) {
        return false;
      }
      const flagWithEquals = /^-+([^=]+?)=[\s\S]*$/;
      const normalFlag = /^-+([^=]+?)$/;
      const flagEndingInHyphen = /^-+([^=]+?)-$/;
      const flagEndingInDigits = /^-+([^=]+?\d+)$/;
      const flagEndingInNonWordCharacters = /^-+([^=]+?)\W+.*$/;
      return !hasFlagsMatching(arg, flagWithEquals, negatedBoolean, normalFlag, flagEndingInHyphen, flagEndingInDigits, flagEndingInNonWordCharacters);
    }
    function defaultValue(key) {
      if (!checkAllAliases(key, flags.bools) && !checkAllAliases(key, flags.counts) && `${key}` in defaults) {
        return defaults[key];
      } else {
        return defaultForType(guessType(key));
      }
    }
    function defaultForType(type) {
      const def = {
        [DefaultValuesForTypeKey.BOOLEAN]: true,
        [DefaultValuesForTypeKey.STRING]: "",
        [DefaultValuesForTypeKey.NUMBER]: undefined,
        [DefaultValuesForTypeKey.ARRAY]: []
      };
      return def[type];
    }
    function guessType(key) {
      let type = DefaultValuesForTypeKey.BOOLEAN;
      if (checkAllAliases(key, flags.strings))
        type = DefaultValuesForTypeKey.STRING;
      else if (checkAllAliases(key, flags.numbers))
        type = DefaultValuesForTypeKey.NUMBER;
      else if (checkAllAliases(key, flags.bools))
        type = DefaultValuesForTypeKey.BOOLEAN;
      else if (checkAllAliases(key, flags.arrays))
        type = DefaultValuesForTypeKey.ARRAY;
      return type;
    }
    function isUndefined(num) {
      return num === undefined;
    }
    function checkConfiguration() {
      Object.keys(flags.counts).find((key) => {
        if (checkAllAliases(key, flags.arrays)) {
          error = Error(__("Invalid configuration: %s, opts.count excludes opts.array.", key));
          return true;
        } else if (checkAllAliases(key, flags.nargs)) {
          error = Error(__("Invalid configuration: %s, opts.count excludes opts.narg.", key));
          return true;
        }
        return false;
      });
    }
    return {
      aliases: Object.assign({}, flags.aliases),
      argv: Object.assign(argvReturn, argv),
      configuration,
      defaulted: Object.assign({}, defaulted),
      error,
      newAliases: Object.assign({}, newAliases)
    };
  }
}
function combineAliases(aliases) {
  const aliasArrays = [];
  const combined = Object.create(null);
  let change = true;
  Object.keys(aliases).forEach(function(key) {
    aliasArrays.push([].concat(aliases[key], key));
  });
  while (change) {
    change = false;
    for (let i = 0;i < aliasArrays.length; i++) {
      for (let ii = i + 1;ii < aliasArrays.length; ii++) {
        const intersect = aliasArrays[i].filter(function(v) {
          return aliasArrays[ii].indexOf(v) !== -1;
        });
        if (intersect.length) {
          aliasArrays[i] = aliasArrays[i].concat(aliasArrays[ii]);
          aliasArrays.splice(ii, 1);
          change = true;
          break;
        }
      }
    }
  }
  aliasArrays.forEach(function(aliasArray) {
    aliasArray = aliasArray.filter(function(v, i, self) {
      return self.indexOf(v) === i;
    });
    const lastAlias = aliasArray.pop();
    if (lastAlias !== undefined && typeof lastAlias === "string") {
      combined[lastAlias] = aliasArray;
    }
  });
  return combined;
}
function increment(orig) {
  return orig !== undefined ? orig + 1 : 1;
}
function sanitizeKey(key) {
  if (key === "__proto__")
    return "___proto___";
  return key;
}
function stripQuotes(val) {
  return typeof val === "string" && (val[0] === "'" || val[0] === '"') && val[val.length - 1] === val[0] ? val.substring(1, val.length - 1) : val;
}

// node_modules/yargs-parser/build/lib/index.js
import { readFileSync } from "fs";
import { createRequire } from "module";
var _a;
var _b;
var _c;
var minNodeVersion = process && process.env && process.env.YARGS_MIN_NODE_VERSION ? Number(process.env.YARGS_MIN_NODE_VERSION) : 20;
var nodeVersion = (_b = (_a = process === null || process === undefined ? undefined : process.versions) === null || _a === undefined ? undefined : _a.node) !== null && _b !== undefined ? _b : (_c = process === null || process === undefined ? undefined : process.version) === null || _c === undefined ? undefined : _c.slice(1);
if (nodeVersion) {
  const major = Number(nodeVersion.match(/^([^.]+)/)[1]);
  if (major < minNodeVersion) {
    throw Error(`yargs parser supports a minimum Node.js version of ${minNodeVersion}. Read our version support policy: https://github.com/yargs/yargs-parser#supported-nodejs-versions`);
  }
}
var env = process ? process.env : {};
var require2 = createRequire ? createRequire(import.meta.url) : undefined;
var parser = new YargsParser({
  cwd: process.cwd,
  env: () => {
    return env;
  },
  format,
  normalize,
  resolve: resolve2,
  require: (path) => {
    if (typeof require2 !== "undefined") {
      return require2(path);
    } else if (path.match(/\.json$/)) {
      return JSON.parse(readFileSync(path, "utf8"));
    } else {
      throw Error("only .json config files are supported in ESM");
    }
  }
});
var yargsParser = function Parser(args, opts) {
  const result = parser.parse(args.slice(), opts);
  return result.argv;
};
yargsParser.detailed = function(args, opts) {
  return parser.parse(args.slice(), opts);
};
yargsParser.camelCase = camelCase;
yargsParser.decamelize = decamelize;
yargsParser.looksLikeNumber = looksLikeNumber;
var lib_default = yargsParser;

// node_modules/yargs/lib/platform-shims/esm.mjs
import { basename, dirname as dirname2, extname, relative, resolve as resolve4, join } from "path";

// node_modules/yargs/build/lib/utils/process-argv.js
function getProcessArgvBinIndex() {
  if (isBundledElectronApp())
    return 0;
  return 1;
}
function isBundledElectronApp() {
  return isElectronApp() && !process.defaultApp;
}
function isElectronApp() {
  return !!process.versions.electron;
}
function hideBin(argv) {
  return argv.slice(getProcessArgvBinIndex() + 1);
}
function getProcessArgvBin() {
  return process.argv[getProcessArgvBinIndex()];
}

// node_modules/y18n/build/lib/platform-shims/node.js
import { readFileSync as readFileSync2, statSync as statSync2, writeFile } from "fs";
import { format as format2 } from "util";
import { resolve as resolve3 } from "path";
var node_default = {
  fs: {
    readFileSync: readFileSync2,
    writeFile
  },
  format: format2,
  resolve: resolve3,
  exists: (file) => {
    try {
      return statSync2(file).isFile();
    } catch (err) {
      return false;
    }
  }
};

// node_modules/y18n/build/lib/index.js
var shim;

class Y18N {
  constructor(opts) {
    opts = opts || {};
    this.directory = opts.directory || "./locales";
    this.updateFiles = typeof opts.updateFiles === "boolean" ? opts.updateFiles : true;
    this.locale = opts.locale || "en";
    this.fallbackToLanguage = typeof opts.fallbackToLanguage === "boolean" ? opts.fallbackToLanguage : true;
    this.cache = Object.create(null);
    this.writeQueue = [];
  }
  __(...args) {
    if (typeof arguments[0] !== "string") {
      return this._taggedLiteral(arguments[0], ...arguments);
    }
    const str = args.shift();
    let cb = function() {};
    if (typeof args[args.length - 1] === "function")
      cb = args.pop();
    cb = cb || function() {};
    if (!this.cache[this.locale])
      this._readLocaleFile();
    if (!this.cache[this.locale][str] && this.updateFiles) {
      this.cache[this.locale][str] = str;
      this._enqueueWrite({
        directory: this.directory,
        locale: this.locale,
        cb
      });
    } else {
      cb();
    }
    return shim.format.apply(shim.format, [this.cache[this.locale][str] || str].concat(args));
  }
  __n() {
    const args = Array.prototype.slice.call(arguments);
    const singular = args.shift();
    const plural = args.shift();
    const quantity = args.shift();
    let cb = function() {};
    if (typeof args[args.length - 1] === "function")
      cb = args.pop();
    if (!this.cache[this.locale])
      this._readLocaleFile();
    let str = quantity === 1 ? singular : plural;
    if (this.cache[this.locale][singular]) {
      const entry = this.cache[this.locale][singular];
      str = entry[quantity === 1 ? "one" : "other"];
    }
    if (!this.cache[this.locale][singular] && this.updateFiles) {
      this.cache[this.locale][singular] = {
        one: singular,
        other: plural
      };
      this._enqueueWrite({
        directory: this.directory,
        locale: this.locale,
        cb
      });
    } else {
      cb();
    }
    const values = [str];
    if (~str.indexOf("%d"))
      values.push(quantity);
    return shim.format.apply(shim.format, values.concat(args));
  }
  setLocale(locale) {
    this.locale = locale;
  }
  getLocale() {
    return this.locale;
  }
  updateLocale(obj) {
    if (!this.cache[this.locale])
      this._readLocaleFile();
    for (const key in obj) {
      if (Object.prototype.hasOwnProperty.call(obj, key)) {
        this.cache[this.locale][key] = obj[key];
      }
    }
  }
  _taggedLiteral(parts, ...args) {
    let str = "";
    parts.forEach(function(part, i) {
      const arg = args[i + 1];
      str += part;
      if (typeof arg !== "undefined") {
        str += "%s";
      }
    });
    return this.__.apply(this, [str].concat([].slice.call(args, 1)));
  }
  _enqueueWrite(work) {
    this.writeQueue.push(work);
    if (this.writeQueue.length === 1)
      this._processWriteQueue();
  }
  _processWriteQueue() {
    const _this = this;
    const work = this.writeQueue[0];
    const directory = work.directory;
    const locale = work.locale;
    const cb = work.cb;
    const languageFile = this._resolveLocaleFile(directory, locale);
    const serializedLocale = JSON.stringify(this.cache[locale], null, 2);
    shim.fs.writeFile(languageFile, serializedLocale, "utf-8", function(err) {
      _this.writeQueue.shift();
      if (_this.writeQueue.length > 0)
        _this._processWriteQueue();
      cb(err);
    });
  }
  _readLocaleFile() {
    let localeLookup = {};
    const languageFile = this._resolveLocaleFile(this.directory, this.locale);
    try {
      if (shim.fs.readFileSync) {
        localeLookup = JSON.parse(shim.fs.readFileSync(languageFile, "utf-8"));
      }
    } catch (err) {
      if (err instanceof SyntaxError) {
        err.message = "syntax error in " + languageFile;
      }
      if (err.code === "ENOENT")
        localeLookup = {};
      else
        throw err;
    }
    this.cache[this.locale] = localeLookup;
  }
  _resolveLocaleFile(directory, locale) {
    let file = shim.resolve(directory, "./", locale + ".json");
    if (this.fallbackToLanguage && !this._fileExistsSync(file) && ~locale.lastIndexOf("_")) {
      const languageFile = shim.resolve(directory, "./", locale.split("_")[0] + ".json");
      if (this._fileExistsSync(languageFile))
        file = languageFile;
    }
    return file;
  }
  _fileExistsSync(file) {
    return shim.exists(file);
  }
}
function y18n(opts, _shim) {
  shim = _shim;
  const y18n2 = new Y18N(opts);
  return {
    __: y18n2.__.bind(y18n2),
    __n: y18n2.__n.bind(y18n2),
    setLocale: y18n2.setLocale.bind(y18n2),
    getLocale: y18n2.getLocale.bind(y18n2),
    updateLocale: y18n2.updateLocale.bind(y18n2),
    locale: y18n2.locale
  };
}

// node_modules/y18n/index.mjs
var y18n2 = (opts) => {
  return y18n(opts, node_default);
};
var y18n_default = y18n2;

// node_modules/yargs/lib/platform-shims/esm.mjs
var import_get_caller_file = __toESM(require_get_caller_file(), 1);
import { createRequire as createRequire2 } from "module";
import { readFileSync as readFileSync3, readdirSync as readdirSync2 } from "fs";
var __dirname2 = fileURLToPath(import.meta.url);
var mainFilename = __dirname2.substring(0, __dirname2.lastIndexOf("node_modules"));
var require3 = createRequire2(import.meta.url);
var esm_default = {
  assert: {
    notStrictEqual,
    strictEqual
  },
  cliui: ui,
  findUp: sync_default,
  getEnv: (key) => {
    return process.env[key];
  },
  inspect,
  getProcessArgvBin,
  mainFilename: mainFilename || process.cwd(),
  Parser: lib_default,
  path: {
    basename,
    dirname: dirname2,
    extname,
    relative,
    resolve: resolve4,
    join
  },
  process: {
    argv: () => process.argv,
    cwd: process.cwd,
    emitWarning: (warning, type) => process.emitWarning(warning, type),
    execPath: () => process.execPath,
    exit: (code) => {
      process.exit(code);
    },
    nextTick: process.nextTick,
    stdColumns: typeof process.stdout.columns !== "undefined" ? process.stdout.columns : null
  },
  readFileSync: readFileSync3,
  readdirSync: readdirSync2,
  require: require3,
  getCallerFile: () => {
    const callerFile = import_get_caller_file.default(3);
    return callerFile.match(/^file:\/\//) ? fileURLToPath(callerFile) : callerFile;
  },
  stringWidth,
  y18n: y18n_default({
    directory: resolve4(__dirname2, "../../../locales"),
    updateFiles: false
  })
};

// node_modules/yargs/build/lib/typings/common-types.js
function assertNotStrictEqual(actual, expected, shim2, message) {
  shim2.assert.notStrictEqual(actual, expected, message);
}
function assertSingleKey(actual, shim2) {
  shim2.assert.strictEqual(typeof actual, "string");
}
function objectKeys(object) {
  return Object.keys(object);
}

// node_modules/yargs/build/lib/utils/is-promise.js
function isPromise(maybePromise) {
  return !!maybePromise && !!maybePromise.then && typeof maybePromise.then === "function";
}

// node_modules/yargs/build/lib/yerror.js
class YError extends Error {
  constructor(msg) {
    super(msg || "yargs error");
    this.name = "YError";
    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, YError);
    }
  }
}

// node_modules/yargs/build/lib/parse-command.js
function parseCommand(cmd) {
  const extraSpacesStrippedCommand = cmd.replace(/\s{2,}/g, " ");
  const splitCommand = extraSpacesStrippedCommand.split(/\s+(?![^[]*]|[^<]*>)/);
  const bregex = /\.*[\][<>]/g;
  const firstCommand = splitCommand.shift();
  if (!firstCommand)
    throw new Error(`No command found in: ${cmd}`);
  const parsedCommand = {
    cmd: firstCommand.replace(bregex, ""),
    demanded: [],
    optional: []
  };
  splitCommand.forEach((cmd2, i) => {
    let variadic = false;
    cmd2 = cmd2.replace(/\s/g, "");
    if (/\.+[\]>]/.test(cmd2) && i === splitCommand.length - 1)
      variadic = true;
    if (/^\[/.test(cmd2)) {
      parsedCommand.optional.push({
        cmd: cmd2.replace(bregex, "").split("|"),
        variadic
      });
    } else {
      parsedCommand.demanded.push({
        cmd: cmd2.replace(bregex, "").split("|"),
        variadic
      });
    }
  });
  return parsedCommand;
}

// node_modules/yargs/build/lib/argsert.js
var positionName = ["first", "second", "third", "fourth", "fifth", "sixth"];
function argsert(arg1, arg2, arg3) {
  function parseArgs() {
    return typeof arg1 === "object" ? [{ demanded: [], optional: [] }, arg1, arg2] : [
      parseCommand(`cmd ${arg1}`),
      arg2,
      arg3
    ];
  }
  try {
    let position = 0;
    const [parsed, callerArguments, _length] = parseArgs();
    const args = [].slice.call(callerArguments);
    while (args.length && args[args.length - 1] === undefined)
      args.pop();
    const length = _length || args.length;
    if (length < parsed.demanded.length) {
      throw new YError(`Not enough arguments provided. Expected ${parsed.demanded.length} but received ${args.length}.`);
    }
    const totalCommands = parsed.demanded.length + parsed.optional.length;
    if (length > totalCommands) {
      throw new YError(`Too many arguments provided. Expected max ${totalCommands} but received ${length}.`);
    }
    parsed.demanded.forEach((demanded) => {
      const arg = args.shift();
      const observedType = guessType(arg);
      const matchingTypes = demanded.cmd.filter((type) => type === observedType || type === "*");
      if (matchingTypes.length === 0)
        argumentTypeError(observedType, demanded.cmd, position);
      position += 1;
    });
    parsed.optional.forEach((optional) => {
      if (args.length === 0)
        return;
      const arg = args.shift();
      const observedType = guessType(arg);
      const matchingTypes = optional.cmd.filter((type) => type === observedType || type === "*");
      if (matchingTypes.length === 0)
        argumentTypeError(observedType, optional.cmd, position);
      position += 1;
    });
  } catch (err) {
    console.warn(err.stack);
  }
}
function guessType(arg) {
  if (Array.isArray(arg)) {
    return "array";
  } else if (arg === null) {
    return "null";
  }
  return typeof arg;
}
function argumentTypeError(observedType, allowedTypes, position) {
  throw new YError(`Invalid ${positionName[position] || "manyith"} argument. Expected ${allowedTypes.join(" or ")} but received ${observedType}.`);
}

// node_modules/yargs/build/lib/middleware.js
class GlobalMiddleware {
  constructor(yargs) {
    this.globalMiddleware = [];
    this.frozens = [];
    this.yargs = yargs;
  }
  addMiddleware(callback, applyBeforeValidation, global = true, mutates = false) {
    argsert("<array|function> [boolean] [boolean] [boolean]", [callback, applyBeforeValidation, global], arguments.length);
    if (Array.isArray(callback)) {
      for (let i = 0;i < callback.length; i++) {
        if (typeof callback[i] !== "function") {
          throw Error("middleware must be a function");
        }
        const m = callback[i];
        m.applyBeforeValidation = applyBeforeValidation;
        m.global = global;
      }
      Array.prototype.push.apply(this.globalMiddleware, callback);
    } else if (typeof callback === "function") {
      const m = callback;
      m.applyBeforeValidation = applyBeforeValidation;
      m.global = global;
      m.mutates = mutates;
      this.globalMiddleware.push(callback);
    }
    return this.yargs;
  }
  addCoerceMiddleware(callback, option) {
    const aliases = this.yargs.getAliases();
    this.globalMiddleware = this.globalMiddleware.filter((m) => {
      const toCheck = [...aliases[option] || [], option];
      if (!m.option)
        return true;
      else
        return !toCheck.includes(m.option);
    });
    callback.option = option;
    return this.addMiddleware(callback, true, true, true);
  }
  getMiddleware() {
    return this.globalMiddleware;
  }
  freeze() {
    this.frozens.push([...this.globalMiddleware]);
  }
  unfreeze() {
    const frozen = this.frozens.pop();
    if (frozen !== undefined)
      this.globalMiddleware = frozen;
  }
  reset() {
    this.globalMiddleware = this.globalMiddleware.filter((m) => m.global);
  }
}
function commandMiddlewareFactory(commandMiddleware) {
  if (!commandMiddleware)
    return [];
  return commandMiddleware.map((middleware) => {
    middleware.applyBeforeValidation = false;
    return middleware;
  });
}
function applyMiddleware(argv, yargs, middlewares, beforeValidation) {
  return middlewares.reduce((acc, middleware) => {
    if (middleware.applyBeforeValidation !== beforeValidation) {
      return acc;
    }
    if (middleware.mutates) {
      if (middleware.applied)
        return acc;
      middleware.applied = true;
    }
    if (isPromise(acc)) {
      return acc.then((initialObj) => Promise.all([initialObj, middleware(initialObj, yargs)])).then(([initialObj, middlewareObj]) => Object.assign(initialObj, middlewareObj));
    } else {
      const result = middleware(acc, yargs);
      return isPromise(result) ? result.then((middlewareObj) => Object.assign(acc, middlewareObj)) : Object.assign(acc, result);
    }
  }, argv);
}

// node_modules/yargs/build/lib/utils/maybe-async-result.js
function maybeAsyncResult(getResult, resultHandler, errorHandler = (err) => {
  throw err;
}) {
  try {
    const result = isFunction(getResult) ? getResult() : getResult;
    return isPromise(result) ? result.then((result2) => resultHandler(result2)) : resultHandler(result);
  } catch (err) {
    return errorHandler(err);
  }
}
function isFunction(arg) {
  return typeof arg === "function";
}

// node_modules/yargs/build/lib/command.js
var DEFAULT_MARKER = /(^\*)|(^\$0)/;

class CommandInstance {
  constructor(usage, validation, globalMiddleware, shim2) {
    this.requireCache = new Set;
    this.handlers = {};
    this.aliasMap = {};
    this.frozens = [];
    this.shim = shim2;
    this.usage = usage;
    this.globalMiddleware = globalMiddleware;
    this.validation = validation;
  }
  addDirectory(dir, req, callerFile, opts) {
    opts = opts || {};
    this.requireCache.add(callerFile);
    const fullDirPath = this.shim.path.resolve(this.shim.path.dirname(callerFile), dir);
    const files = this.shim.readdirSync(fullDirPath, {
      recursive: opts.recurse ? true : false
    });
    if (!Array.isArray(opts.extensions))
      opts.extensions = ["js"];
    const visit = typeof opts.visit === "function" ? opts.visit : (o) => o;
    for (const fileb of files) {
      const file = fileb.toString();
      if (opts.exclude) {
        let exclude = false;
        if (typeof opts.exclude === "function") {
          exclude = opts.exclude(file);
        } else {
          exclude = opts.exclude.test(file);
        }
        if (exclude)
          continue;
      }
      if (opts.include) {
        let include = false;
        if (typeof opts.include === "function") {
          include = opts.include(file);
        } else {
          include = opts.include.test(file);
        }
        if (!include)
          continue;
      }
      let supportedExtension = false;
      for (const ext of opts.extensions) {
        if (file.endsWith(ext))
          supportedExtension = true;
      }
      if (supportedExtension) {
        const joined = this.shim.path.join(fullDirPath, file);
        const module = req(joined);
        const extendableModule = Object.create(null, Object.getOwnPropertyDescriptors({ ...module }));
        const visited = visit(extendableModule, joined, file);
        if (visited) {
          if (this.requireCache.has(joined))
            continue;
          else
            this.requireCache.add(joined);
          if (!extendableModule.command) {
            extendableModule.command = this.shim.path.basename(joined, this.shim.path.extname(joined));
          }
          this.addHandler(extendableModule);
        }
      }
    }
  }
  addHandler(cmd, description, builder, handler, commandMiddleware, deprecated) {
    let aliases = [];
    const middlewares = commandMiddlewareFactory(commandMiddleware);
    handler = handler || (() => {});
    if (Array.isArray(cmd)) {
      if (isCommandAndAliases(cmd)) {
        [cmd, ...aliases] = cmd;
      } else {
        for (const command of cmd) {
          this.addHandler(command);
        }
      }
    } else if (isCommandHandlerDefinition(cmd)) {
      let command = Array.isArray(cmd.command) || typeof cmd.command === "string" ? cmd.command : null;
      if (command === null) {
        throw new Error(`No command name given for module: ${this.shim.inspect(cmd)}`);
      }
      if (cmd.aliases)
        command = [].concat(command).concat(cmd.aliases);
      this.addHandler(command, this.extractDesc(cmd), cmd.builder, cmd.handler, cmd.middlewares, cmd.deprecated);
      return;
    } else if (isCommandBuilderDefinition(builder)) {
      this.addHandler([cmd].concat(aliases), description, builder.builder, builder.handler, builder.middlewares, builder.deprecated);
      return;
    }
    if (typeof cmd === "string") {
      const parsedCommand = parseCommand(cmd);
      aliases = aliases.map((alias) => parseCommand(alias).cmd);
      let isDefault = false;
      const parsedAliases = [parsedCommand.cmd].concat(aliases).filter((c) => {
        if (DEFAULT_MARKER.test(c)) {
          isDefault = true;
          return false;
        }
        return true;
      });
      if (parsedAliases.length === 0 && isDefault)
        parsedAliases.push("$0");
      if (isDefault) {
        parsedCommand.cmd = parsedAliases[0];
        aliases = parsedAliases.slice(1);
        cmd = cmd.replace(DEFAULT_MARKER, parsedCommand.cmd);
      }
      aliases.forEach((alias) => {
        this.aliasMap[alias] = parsedCommand.cmd;
      });
      if (description !== false) {
        this.usage.command(cmd, description, isDefault, aliases, deprecated);
      }
      this.handlers[parsedCommand.cmd] = {
        original: cmd,
        description,
        handler,
        builder: builder || {},
        middlewares,
        deprecated,
        demanded: parsedCommand.demanded,
        optional: parsedCommand.optional
      };
      if (isDefault)
        this.defaultCommand = this.handlers[parsedCommand.cmd];
    }
  }
  getCommandHandlers() {
    return this.handlers;
  }
  getCommands() {
    return Object.keys(this.handlers).concat(Object.keys(this.aliasMap));
  }
  hasDefaultCommand() {
    return !!this.defaultCommand;
  }
  runCommand(command, yargs, parsed, commandIndex, helpOnly, helpOrVersionSet) {
    const commandHandler = this.handlers[command] || this.handlers[this.aliasMap[command]] || this.defaultCommand;
    const currentContext = yargs.getInternalMethods().getContext();
    const parentCommands = currentContext.commands.slice();
    const isDefaultCommand = !command;
    if (command) {
      currentContext.commands.push(command);
      currentContext.fullCommands.push(commandHandler.original);
    }
    const builderResult = this.applyBuilderUpdateUsageAndParse(isDefaultCommand, commandHandler, yargs, parsed.aliases, parentCommands, commandIndex, helpOnly, helpOrVersionSet);
    return isPromise(builderResult) ? builderResult.then((result) => this.applyMiddlewareAndGetResult(isDefaultCommand, commandHandler, result.innerArgv, currentContext, helpOnly, result.aliases, yargs)) : this.applyMiddlewareAndGetResult(isDefaultCommand, commandHandler, builderResult.innerArgv, currentContext, helpOnly, builderResult.aliases, yargs);
  }
  applyBuilderUpdateUsageAndParse(isDefaultCommand, commandHandler, yargs, aliases, parentCommands, commandIndex, helpOnly, helpOrVersionSet) {
    const builder = commandHandler.builder;
    let innerYargs = yargs;
    if (isCommandBuilderCallback(builder)) {
      yargs.getInternalMethods().getUsageInstance().freeze();
      const builderOutput = builder(yargs.getInternalMethods().reset(aliases), helpOrVersionSet);
      if (isPromise(builderOutput)) {
        return builderOutput.then((output) => {
          innerYargs = isYargsInstance(output) ? output : yargs;
          return this.parseAndUpdateUsage(isDefaultCommand, commandHandler, innerYargs, parentCommands, commandIndex, helpOnly);
        });
      }
    } else if (isCommandBuilderOptionDefinitions(builder)) {
      yargs.getInternalMethods().getUsageInstance().freeze();
      innerYargs = yargs.getInternalMethods().reset(aliases);
      Object.keys(commandHandler.builder).forEach((key) => {
        innerYargs.option(key, builder[key]);
      });
    }
    return this.parseAndUpdateUsage(isDefaultCommand, commandHandler, innerYargs, parentCommands, commandIndex, helpOnly);
  }
  parseAndUpdateUsage(isDefaultCommand, commandHandler, innerYargs, parentCommands, commandIndex, helpOnly) {
    if (isDefaultCommand)
      innerYargs.getInternalMethods().getUsageInstance().unfreeze(true);
    if (this.shouldUpdateUsage(innerYargs)) {
      innerYargs.getInternalMethods().getUsageInstance().usage(this.usageFromParentCommandsCommandHandler(parentCommands, commandHandler), commandHandler.description);
    }
    const innerArgv = innerYargs.getInternalMethods().runYargsParserAndExecuteCommands(null, undefined, true, commandIndex, helpOnly);
    return isPromise(innerArgv) ? innerArgv.then((argv) => ({
      aliases: innerYargs.parsed.aliases,
      innerArgv: argv
    })) : {
      aliases: innerYargs.parsed.aliases,
      innerArgv
    };
  }
  shouldUpdateUsage(yargs) {
    return !yargs.getInternalMethods().getUsageInstance().getUsageDisabled() && yargs.getInternalMethods().getUsageInstance().getUsage().length === 0;
  }
  usageFromParentCommandsCommandHandler(parentCommands, commandHandler) {
    const c = DEFAULT_MARKER.test(commandHandler.original) ? commandHandler.original.replace(DEFAULT_MARKER, "").trim() : commandHandler.original;
    const pc = parentCommands.filter((c2) => {
      return !DEFAULT_MARKER.test(c2);
    });
    pc.push(c);
    return `$0 ${pc.join(" ")}`;
  }
  handleValidationAndGetResult(isDefaultCommand, commandHandler, innerArgv, currentContext, aliases, yargs, middlewares, positionalMap) {
    if (!yargs.getInternalMethods().getHasOutput()) {
      const validation = yargs.getInternalMethods().runValidation(aliases, positionalMap, yargs.parsed.error, isDefaultCommand);
      innerArgv = maybeAsyncResult(innerArgv, (result) => {
        validation(result);
        return result;
      });
    }
    if (commandHandler.handler && !yargs.getInternalMethods().getHasOutput()) {
      yargs.getInternalMethods().setHasOutput();
      const populateDoubleDash = !!yargs.getOptions().configuration["populate--"];
      yargs.getInternalMethods().postProcess(innerArgv, populateDoubleDash, false, false);
      innerArgv = applyMiddleware(innerArgv, yargs, middlewares, false);
      innerArgv = maybeAsyncResult(innerArgv, (result) => {
        const handlerResult = commandHandler.handler(result);
        return isPromise(handlerResult) ? handlerResult.then(() => result) : result;
      });
      if (!isDefaultCommand) {
        yargs.getInternalMethods().getUsageInstance().cacheHelpMessage();
      }
      if (isPromise(innerArgv) && !yargs.getInternalMethods().hasParseCallback()) {
        innerArgv.catch((error) => {
          try {
            yargs.getInternalMethods().getUsageInstance().fail(null, error);
          } catch (_err) {}
        });
      }
    }
    if (!isDefaultCommand) {
      currentContext.commands.pop();
      currentContext.fullCommands.pop();
    }
    return innerArgv;
  }
  applyMiddlewareAndGetResult(isDefaultCommand, commandHandler, innerArgv, currentContext, helpOnly, aliases, yargs) {
    let positionalMap = {};
    if (helpOnly)
      return innerArgv;
    if (!yargs.getInternalMethods().getHasOutput()) {
      positionalMap = this.populatePositionals(commandHandler, innerArgv, currentContext, yargs);
    }
    const middlewares = this.globalMiddleware.getMiddleware().slice(0).concat(commandHandler.middlewares);
    const maybePromiseArgv = applyMiddleware(innerArgv, yargs, middlewares, true);
    return isPromise(maybePromiseArgv) ? maybePromiseArgv.then((resolvedInnerArgv) => this.handleValidationAndGetResult(isDefaultCommand, commandHandler, resolvedInnerArgv, currentContext, aliases, yargs, middlewares, positionalMap)) : this.handleValidationAndGetResult(isDefaultCommand, commandHandler, maybePromiseArgv, currentContext, aliases, yargs, middlewares, positionalMap);
  }
  populatePositionals(commandHandler, argv, context, yargs) {
    argv._ = argv._.slice(context.commands.length);
    const demanded = commandHandler.demanded.slice(0);
    const optional = commandHandler.optional.slice(0);
    const positionalMap = {};
    this.validation.positionalCount(demanded.length, argv._.length);
    while (demanded.length) {
      const demand = demanded.shift();
      this.populatePositional(demand, argv, positionalMap);
    }
    while (optional.length) {
      const maybe = optional.shift();
      this.populatePositional(maybe, argv, positionalMap);
    }
    argv._ = context.commands.concat(argv._.map((a) => "" + a));
    this.postProcessPositionals(argv, positionalMap, this.cmdToParseOptions(commandHandler.original), yargs);
    return positionalMap;
  }
  populatePositional(positional, argv, positionalMap) {
    const cmd = positional.cmd[0];
    if (positional.variadic) {
      positionalMap[cmd] = argv._.splice(0).map(String);
    } else {
      if (argv._.length)
        positionalMap[cmd] = [String(argv._.shift())];
    }
  }
  cmdToParseOptions(cmdString) {
    const parseOptions = {
      array: [],
      default: {},
      alias: {},
      demand: {}
    };
    const parsed = parseCommand(cmdString);
    parsed.demanded.forEach((d) => {
      const [cmd, ...aliases] = d.cmd;
      if (d.variadic) {
        parseOptions.array.push(cmd);
        parseOptions.default[cmd] = [];
      }
      parseOptions.alias[cmd] = aliases;
      parseOptions.demand[cmd] = true;
    });
    parsed.optional.forEach((o) => {
      const [cmd, ...aliases] = o.cmd;
      if (o.variadic) {
        parseOptions.array.push(cmd);
        parseOptions.default[cmd] = [];
      }
      parseOptions.alias[cmd] = aliases;
    });
    return parseOptions;
  }
  postProcessPositionals(argv, positionalMap, parseOptions, yargs) {
    const options = Object.assign({}, yargs.getOptions());
    options.default = Object.assign(parseOptions.default, options.default);
    for (const key of Object.keys(parseOptions.alias)) {
      options.alias[key] = (options.alias[key] || []).concat(parseOptions.alias[key]);
    }
    options.array = options.array.concat(parseOptions.array);
    options.config = {};
    const unparsed = [];
    Object.keys(positionalMap).forEach((key) => {
      positionalMap[key].map((value) => {
        if (options.configuration["unknown-options-as-args"])
          options.key[key] = true;
        unparsed.push(`--${key}`);
        unparsed.push(value);
      });
    });
    if (!unparsed.length)
      return;
    const config = Object.assign({}, options.configuration, {
      "populate--": false
    });
    const parsed = this.shim.Parser.detailed(unparsed, Object.assign({}, options, {
      configuration: config
    }));
    if (parsed.error) {
      yargs.getInternalMethods().getUsageInstance().fail(parsed.error.message, parsed.error);
    } else {
      const positionalKeys = Object.keys(positionalMap);
      Object.keys(positionalMap).forEach((key) => {
        positionalKeys.push(...parsed.aliases[key]);
      });
      Object.keys(parsed.argv).forEach((key) => {
        if (positionalKeys.includes(key)) {
          if (!positionalMap[key])
            positionalMap[key] = parsed.argv[key];
          if (!this.isInConfigs(yargs, key) && !this.isDefaulted(yargs, key) && Object.prototype.hasOwnProperty.call(argv, key) && Object.prototype.hasOwnProperty.call(parsed.argv, key) && (Array.isArray(argv[key]) || Array.isArray(parsed.argv[key]))) {
            argv[key] = [].concat(argv[key], parsed.argv[key]);
          } else {
            argv[key] = parsed.argv[key];
          }
        }
      });
    }
  }
  isDefaulted(yargs, key) {
    const { default: defaults } = yargs.getOptions();
    return Object.prototype.hasOwnProperty.call(defaults, key) || Object.prototype.hasOwnProperty.call(defaults, this.shim.Parser.camelCase(key));
  }
  isInConfigs(yargs, key) {
    const { configObjects } = yargs.getOptions();
    return configObjects.some((c) => Object.prototype.hasOwnProperty.call(c, key)) || configObjects.some((c) => Object.prototype.hasOwnProperty.call(c, this.shim.Parser.camelCase(key)));
  }
  runDefaultBuilderOn(yargs) {
    if (!this.defaultCommand)
      return;
    if (this.shouldUpdateUsage(yargs)) {
      const commandString = DEFAULT_MARKER.test(this.defaultCommand.original) ? this.defaultCommand.original : this.defaultCommand.original.replace(/^[^[\]<>]*/, "$0 ");
      yargs.getInternalMethods().getUsageInstance().usage(commandString, this.defaultCommand.description);
    }
    const builder = this.defaultCommand.builder;
    if (isCommandBuilderCallback(builder)) {
      return builder(yargs, true);
    } else if (!isCommandBuilderDefinition(builder)) {
      Object.keys(builder).forEach((key) => {
        yargs.option(key, builder[key]);
      });
    }
    return;
  }
  extractDesc({ describe, description, desc }) {
    for (const test of [describe, description, desc]) {
      if (typeof test === "string" || test === false)
        return test;
      assertNotStrictEqual(test, true, this.shim);
    }
    return false;
  }
  freeze() {
    this.frozens.push({
      handlers: this.handlers,
      aliasMap: this.aliasMap,
      defaultCommand: this.defaultCommand
    });
  }
  unfreeze() {
    const frozen = this.frozens.pop();
    assertNotStrictEqual(frozen, undefined, this.shim);
    ({
      handlers: this.handlers,
      aliasMap: this.aliasMap,
      defaultCommand: this.defaultCommand
    } = frozen);
  }
  reset() {
    this.handlers = {};
    this.aliasMap = {};
    this.defaultCommand = undefined;
    this.requireCache = new Set;
    return this;
  }
}
function command(usage, validation, globalMiddleware, shim2) {
  return new CommandInstance(usage, validation, globalMiddleware, shim2);
}
function isCommandBuilderDefinition(builder) {
  return typeof builder === "object" && !!builder.builder && typeof builder.handler === "function";
}
function isCommandAndAliases(cmd) {
  return cmd.every((c) => typeof c === "string");
}
function isCommandBuilderCallback(builder) {
  return typeof builder === "function";
}
function isCommandBuilderOptionDefinitions(builder) {
  return typeof builder === "object";
}
function isCommandHandlerDefinition(cmd) {
  return typeof cmd === "object" && !Array.isArray(cmd);
}

// node_modules/yargs/build/lib/utils/obj-filter.js
function objFilter(original = {}, filter = () => true) {
  const obj = {};
  objectKeys(original).forEach((key) => {
    if (filter(key, original[key])) {
      obj[key] = original[key];
    }
  });
  return obj;
}

// node_modules/yargs/build/lib/utils/set-blocking.js
function setBlocking(blocking) {
  if (typeof process === "undefined")
    return;
  [process.stdout, process.stderr].forEach((_stream) => {
    const stream = _stream;
    if (stream._handle && stream.isTTY && typeof stream._handle.setBlocking === "function") {
      stream._handle.setBlocking(blocking);
    }
  });
}

// node_modules/yargs/build/lib/usage.js
function isBoolean(fail) {
  return typeof fail === "boolean";
}
function usage(yargs, shim2) {
  const __ = shim2.y18n.__;
  const self = {};
  const fails = [];
  self.failFn = function failFn(f) {
    fails.push(f);
  };
  let failMessage = null;
  let globalFailMessage = null;
  let showHelpOnFail = true;
  self.showHelpOnFail = function showHelpOnFailFn(arg1 = true, arg2) {
    const [enabled, message] = typeof arg1 === "string" ? [true, arg1] : [arg1, arg2];
    if (yargs.getInternalMethods().isGlobalContext()) {
      globalFailMessage = message;
    }
    failMessage = message;
    showHelpOnFail = enabled;
    return self;
  };
  let failureOutput = false;
  self.fail = function fail(msg, err) {
    const logger = yargs.getInternalMethods().getLoggerInstance();
    if (fails.length) {
      for (let i = fails.length - 1;i >= 0; --i) {
        const fail2 = fails[i];
        if (isBoolean(fail2)) {
          if (err)
            throw err;
          else if (msg)
            throw Error(msg);
        } else {
          fail2(msg, err, self);
        }
      }
    } else {
      if (yargs.getExitProcess())
        setBlocking(true);
      if (!failureOutput) {
        failureOutput = true;
        if (showHelpOnFail) {
          yargs.showHelp("error");
          logger.error();
        }
        if (msg || err)
          logger.error(msg || err);
        const globalOrCommandFailMessage = failMessage || globalFailMessage;
        if (globalOrCommandFailMessage) {
          if (msg || err)
            logger.error("");
          logger.error(globalOrCommandFailMessage);
        }
      }
      err = err || new YError(msg);
      if (yargs.getExitProcess()) {
        return yargs.exit(1);
      } else if (yargs.getInternalMethods().hasParseCallback()) {
        return yargs.exit(1, err);
      } else {
        throw err;
      }
    }
  };
  let usages = [];
  let usageDisabled = false;
  self.usage = (msg, description) => {
    if (msg === null) {
      usageDisabled = true;
      usages = [];
      return self;
    }
    usageDisabled = false;
    usages.push([msg, description || ""]);
    return self;
  };
  self.getUsage = () => {
    return usages;
  };
  self.getUsageDisabled = () => {
    return usageDisabled;
  };
  self.getPositionalGroupName = () => {
    return __("Positionals:");
  };
  let examples = [];
  self.example = (cmd, description) => {
    examples.push([cmd, description || ""]);
  };
  let commands = [];
  self.command = function command2(cmd, description, isDefault, aliases, deprecated = false) {
    if (isDefault) {
      commands = commands.map((cmdArray) => {
        cmdArray[2] = false;
        return cmdArray;
      });
    }
    commands.push([cmd, description || "", isDefault, aliases, deprecated]);
  };
  self.getCommands = () => commands;
  let descriptions = {};
  self.describe = function describe(keyOrKeys, desc) {
    if (Array.isArray(keyOrKeys)) {
      keyOrKeys.forEach((k) => {
        self.describe(k, desc);
      });
    } else if (typeof keyOrKeys === "object") {
      Object.keys(keyOrKeys).forEach((k) => {
        self.describe(k, keyOrKeys[k]);
      });
    } else {
      descriptions[keyOrKeys] = desc;
    }
  };
  self.getDescriptions = () => descriptions;
  let epilogs = [];
  self.epilog = (msg) => {
    epilogs.push(msg);
  };
  let wrapSet = false;
  let wrap;
  self.wrap = (cols) => {
    wrapSet = true;
    wrap = cols;
  };
  self.getWrap = () => {
    if (shim2.getEnv("YARGS_DISABLE_WRAP")) {
      return null;
    }
    if (!wrapSet) {
      wrap = windowWidth();
      wrapSet = true;
    }
    return wrap;
  };
  const deferY18nLookupPrefix = "__yargsString__:";
  self.deferY18nLookup = (str) => deferY18nLookupPrefix + str;
  self.help = function help() {
    if (cachedHelpMessage)
      return cachedHelpMessage;
    normalizeAliases();
    const base$0 = yargs.customScriptName ? yargs.$0 : shim2.path.basename(yargs.$0);
    const demandedOptions = yargs.getDemandedOptions();
    const demandedCommands = yargs.getDemandedCommands();
    const deprecatedOptions = yargs.getDeprecatedOptions();
    const groups = yargs.getGroups();
    const options = yargs.getOptions();
    let keys = [];
    keys = keys.concat(Object.keys(descriptions));
    keys = keys.concat(Object.keys(demandedOptions));
    keys = keys.concat(Object.keys(demandedCommands));
    keys = keys.concat(Object.keys(options.default));
    keys = keys.filter(filterHiddenOptions);
    keys = Object.keys(keys.reduce((acc, key) => {
      if (key !== "_")
        acc[key] = true;
      return acc;
    }, {}));
    const theWrap = self.getWrap();
    const ui2 = shim2.cliui({
      width: theWrap,
      wrap: !!theWrap
    });
    if (!usageDisabled) {
      if (usages.length) {
        usages.forEach((usage2) => {
          ui2.div({ text: `${usage2[0].replace(/\$0/g, base$0)}` });
          if (usage2[1]) {
            ui2.div({ text: `${usage2[1]}`, padding: [1, 0, 0, 0] });
          }
        });
        ui2.div();
      } else if (commands.length) {
        let u = null;
        if (demandedCommands._) {
          u = `${base$0} <${__("command")}>
`;
        } else {
          u = `${base$0} [${__("command")}]
`;
        }
        ui2.div(`${u}`);
      }
    }
    if (commands.length > 1 || commands.length === 1 && !commands[0][2]) {
      ui2.div(__("Commands:"));
      const context = yargs.getInternalMethods().getContext();
      const parentCommands = context.commands.length ? `${context.commands.join(" ")} ` : "";
      if (yargs.getInternalMethods().getParserConfiguration()["sort-commands"] === true) {
        commands = commands.sort((a, b) => a[0].localeCompare(b[0]));
      }
      const prefix = base$0 ? `${base$0} ` : "";
      commands.forEach((command2) => {
        const commandString = `${prefix}${parentCommands}${command2[0].replace(/^\$0 ?/, "")}`;
        ui2.span({
          text: commandString,
          padding: [0, 2, 0, 2],
          width: maxWidth(commands, theWrap, `${base$0}${parentCommands}`) + 4
        }, { text: command2[1] });
        const hints = [];
        if (command2[2])
          hints.push(`[${__("default")}]`);
        if (command2[3] && command2[3].length) {
          hints.push(`[${__("aliases:")} ${command2[3].join(", ")}]`);
        }
        if (command2[4]) {
          if (typeof command2[4] === "string") {
            hints.push(`[${__("deprecated: %s", command2[4])}]`);
          } else {
            hints.push(`[${__("deprecated")}]`);
          }
        }
        if (hints.length) {
          ui2.div({
            text: hints.join(" "),
            padding: [0, 0, 0, 2],
            align: "right"
          });
        } else {
          ui2.div();
        }
      });
      ui2.div();
    }
    const aliasKeys = (Object.keys(options.alias) || []).concat(Object.keys(yargs.parsed.newAliases) || []);
    keys = keys.filter((key) => !yargs.parsed.newAliases[key] && aliasKeys.every((alias) => (options.alias[alias] || []).indexOf(key) === -1));
    const defaultGroup = __("Options:");
    if (!groups[defaultGroup])
      groups[defaultGroup] = [];
    addUngroupedKeys(keys, options.alias, groups, defaultGroup);
    const isLongSwitch = (sw) => /^--/.test(getText(sw));
    const displayedGroups = Object.keys(groups).filter((groupName) => groups[groupName].length > 0).map((groupName) => {
      const normalizedKeys = groups[groupName].filter(filterHiddenOptions).map((key) => {
        if (aliasKeys.includes(key))
          return key;
        for (let i = 0, aliasKey;(aliasKey = aliasKeys[i]) !== undefined; i++) {
          if ((options.alias[aliasKey] || []).includes(key))
            return aliasKey;
        }
        return key;
      });
      return { groupName, normalizedKeys };
    }).filter(({ normalizedKeys }) => normalizedKeys.length > 0).map(({ groupName, normalizedKeys }) => {
      const switches = normalizedKeys.reduce((acc, key) => {
        acc[key] = [key].concat(options.alias[key] || []).map((sw) => {
          if (groupName === self.getPositionalGroupName())
            return sw;
          else {
            return (/^[0-9]$/.test(sw) ? options.boolean.includes(key) ? "-" : "--" : sw.length > 1 ? "--" : "-") + sw;
          }
        }).sort((sw1, sw2) => isLongSwitch(sw1) === isLongSwitch(sw2) ? 0 : isLongSwitch(sw1) ? 1 : -1).join(", ");
        return acc;
      }, {});
      return { groupName, normalizedKeys, switches };
    });
    const shortSwitchesUsed = displayedGroups.filter(({ groupName }) => groupName !== self.getPositionalGroupName()).some(({ normalizedKeys, switches }) => !normalizedKeys.every((key) => isLongSwitch(switches[key])));
    if (shortSwitchesUsed) {
      displayedGroups.filter(({ groupName }) => groupName !== self.getPositionalGroupName()).forEach(({ normalizedKeys, switches }) => {
        normalizedKeys.forEach((key) => {
          if (isLongSwitch(switches[key])) {
            switches[key] = addIndentation(switches[key], "-x, ".length);
          }
        });
      });
    }
    displayedGroups.forEach(({ groupName, normalizedKeys, switches }) => {
      ui2.div(groupName);
      normalizedKeys.forEach((key) => {
        const kswitch = switches[key];
        let desc = descriptions[key] || "";
        let type = null;
        if (desc.includes(deferY18nLookupPrefix))
          desc = __(desc.substring(deferY18nLookupPrefix.length));
        if (options.boolean.includes(key))
          type = `[${__("boolean")}]`;
        if (options.count.includes(key))
          type = `[${__("count")}]`;
        if (options.string.includes(key))
          type = `[${__("string")}]`;
        if (options.normalize.includes(key))
          type = `[${__("string")}]`;
        if (options.array.includes(key))
          type = `[${__("array")}]`;
        if (options.number.includes(key))
          type = `[${__("number")}]`;
        const deprecatedExtra = (deprecated) => typeof deprecated === "string" ? `[${__("deprecated: %s", deprecated)}]` : `[${__("deprecated")}]`;
        const extra = [
          key in deprecatedOptions ? deprecatedExtra(deprecatedOptions[key]) : null,
          type,
          key in demandedOptions ? `[${__("required")}]` : null,
          options.choices && options.choices[key] ? `[${__("choices:")} ${self.stringifiedValues(options.choices[key])}]` : null,
          defaultString(options.default[key], options.defaultDescription[key])
        ].filter(Boolean).join(" ");
        ui2.span({
          text: getText(kswitch),
          padding: [0, 2, 0, 2 + getIndentation(kswitch)],
          width: maxWidth(switches, theWrap) + 4
        }, desc);
        const shouldHideOptionExtras = yargs.getInternalMethods().getUsageConfiguration()["hide-types"] === true;
        if (extra && !shouldHideOptionExtras)
          ui2.div({ text: extra, padding: [0, 0, 0, 2], align: "right" });
        else
          ui2.div();
      });
      ui2.div();
    });
    if (examples.length) {
      ui2.div(__("Examples:"));
      examples.forEach((example) => {
        example[0] = example[0].replace(/\$0/g, base$0);
      });
      examples.forEach((example) => {
        if (example[1] === "") {
          ui2.div({
            text: example[0],
            padding: [0, 2, 0, 2]
          });
        } else {
          ui2.div({
            text: example[0],
            padding: [0, 2, 0, 2],
            width: maxWidth(examples, theWrap) + 4
          }, {
            text: example[1]
          });
        }
      });
      ui2.div();
    }
    if (epilogs.length > 0) {
      const e = epilogs.map((epilog) => epilog.replace(/\$0/g, base$0)).join(`
`);
      ui2.div(`${e}
`);
    }
    return ui2.toString().replace(/\s*$/, "");
  };
  function maxWidth(table, theWrap, modifier) {
    let width = 0;
    if (!Array.isArray(table)) {
      table = Object.values(table).map((v) => [v]);
    }
    table.forEach((v) => {
      width = Math.max(shim2.stringWidth(modifier ? `${modifier} ${getText(v[0])}` : getText(v[0])) + getIndentation(v[0]), width);
    });
    if (theWrap)
      width = Math.min(width, parseInt((theWrap * 0.5).toString(), 10));
    return width;
  }
  function normalizeAliases() {
    const demandedOptions = yargs.getDemandedOptions();
    const options = yargs.getOptions();
    (Object.keys(options.alias) || []).forEach((key) => {
      options.alias[key].forEach((alias) => {
        if (descriptions[alias])
          self.describe(key, descriptions[alias]);
        if (alias in demandedOptions)
          yargs.demandOption(key, demandedOptions[alias]);
        if (options.boolean.includes(alias))
          yargs.boolean(key);
        if (options.count.includes(alias))
          yargs.count(key);
        if (options.string.includes(alias))
          yargs.string(key);
        if (options.normalize.includes(alias))
          yargs.normalize(key);
        if (options.array.includes(alias))
          yargs.array(key);
        if (options.number.includes(alias))
          yargs.number(key);
      });
    });
  }
  let cachedHelpMessage;
  self.cacheHelpMessage = function() {
    cachedHelpMessage = this.help();
  };
  self.clearCachedHelpMessage = function() {
    cachedHelpMessage = undefined;
  };
  self.hasCachedHelpMessage = function() {
    return !!cachedHelpMessage;
  };
  function addUngroupedKeys(keys, aliases, groups, defaultGroup) {
    let groupedKeys = [];
    let toCheck = null;
    Object.keys(groups).forEach((group) => {
      groupedKeys = groupedKeys.concat(groups[group]);
    });
    keys.forEach((key) => {
      toCheck = [key].concat(aliases[key]);
      if (!toCheck.some((k) => groupedKeys.indexOf(k) !== -1)) {
        groups[defaultGroup].push(key);
      }
    });
    return groupedKeys;
  }
  function filterHiddenOptions(key) {
    return yargs.getOptions().hiddenOptions.indexOf(key) < 0 || yargs.parsed.argv[yargs.getOptions().showHiddenOpt];
  }
  self.showHelp = (level) => {
    const logger = yargs.getInternalMethods().getLoggerInstance();
    if (!level)
      level = "error";
    const emit = typeof level === "function" ? level : logger[level];
    emit(self.help());
  };
  self.functionDescription = (fn) => {
    const description = fn.name ? shim2.Parser.decamelize(fn.name, "-") : __("generated-value");
    return ["(", description, ")"].join("");
  };
  self.stringifiedValues = function stringifiedValues(values, separator) {
    let string = "";
    const sep = separator || ", ";
    const array = [].concat(values);
    if (!values || !array.length)
      return string;
    array.forEach((value) => {
      if (string.length)
        string += sep;
      string += JSON.stringify(value);
    });
    return string;
  };
  function defaultString(value, defaultDescription) {
    let string = `[${__("default:")} `;
    if (value === undefined && !defaultDescription)
      return null;
    if (defaultDescription) {
      string += defaultDescription;
    } else {
      switch (typeof value) {
        case "string":
          string += `"${value}"`;
          break;
        case "object":
          string += JSON.stringify(value);
          break;
        default:
          string += value;
      }
    }
    return `${string}]`;
  }
  function windowWidth() {
    const maxWidth2 = 80;
    if (shim2.process.stdColumns) {
      return Math.min(maxWidth2, shim2.process.stdColumns);
    } else {
      return maxWidth2;
    }
  }
  let version = null;
  self.version = (ver) => {
    version = ver;
  };
  self.showVersion = (level) => {
    const logger = yargs.getInternalMethods().getLoggerInstance();
    if (!level)
      level = "error";
    const emit = typeof level === "function" ? level : logger[level];
    emit(version);
  };
  self.reset = function reset(localLookup) {
    failMessage = null;
    failureOutput = false;
    usages = [];
    usageDisabled = false;
    epilogs = [];
    examples = [];
    commands = [];
    descriptions = objFilter(descriptions, (k) => !localLookup[k]);
    return self;
  };
  const frozens = [];
  self.freeze = function freeze() {
    frozens.push({
      failMessage,
      failureOutput,
      usages,
      usageDisabled,
      epilogs,
      examples,
      commands,
      descriptions
    });
  };
  self.unfreeze = function unfreeze(defaultCommand = false) {
    const frozen = frozens.pop();
    if (!frozen)
      return;
    if (defaultCommand) {
      descriptions = { ...frozen.descriptions, ...descriptions };
      commands = [...frozen.commands, ...commands];
      usages = [...frozen.usages, ...usages];
      examples = [...frozen.examples, ...examples];
      epilogs = [...frozen.epilogs, ...epilogs];
    } else {
      ({
        failMessage,
        failureOutput,
        usages,
        usageDisabled,
        epilogs,
        examples,
        commands,
        descriptions
      } = frozen);
    }
  };
  return self;
}
function isIndentedText(text) {
  return typeof text === "object";
}
function addIndentation(text, indent) {
  return isIndentedText(text) ? { text: text.text, indentation: text.indentation + indent } : { text, indentation: indent };
}
function getIndentation(text) {
  return isIndentedText(text) ? text.indentation : 0;
}
function getText(text) {
  return isIndentedText(text) ? text.text : text;
}

// node_modules/yargs/build/lib/completion-templates.js
var completionShTemplate = `###-begin-{{app_name}}-completions-###
#
# yargs command completion script
#
# Installation: {{app_path}} {{completion_command}} >> ~/.bashrc
#    or {{app_path}} {{completion_command}} >> ~/.bash_profile on OSX.
#
_{{app_name}}_yargs_completions()
{
    local cur_word args type_list

    cur_word="\${COMP_WORDS[COMP_CWORD]}"
    args=("\${COMP_WORDS[@]}")

    # ask yargs to generate completions.
    # see https://stackoverflow.com/a/40944195/7080036 for the spaces-handling awk
    mapfile -t type_list < <({{app_path}} --get-yargs-completions "\${args[@]}")
    mapfile -t COMPREPLY < <(compgen -W "$( printf '%q ' "\${type_list[@]}" )" -- "\${cur_word}" |
        awk '/ / { print "\\""$0"\\"" } /^[^ ]+$/ { print $0 }')

    # if no match was found, fall back to filename completion
    if [ \${#COMPREPLY[@]} -eq 0 ]; then
      COMPREPLY=()
    fi

    return 0
}
complete -o bashdefault -o default -F _{{app_name}}_yargs_completions {{app_name}}
###-end-{{app_name}}-completions-###
`;
var completionZshTemplate = `#compdef {{app_name}}
###-begin-{{app_name}}-completions-###
#
# yargs command completion script
#
# Installation: {{app_path}} {{completion_command}} >> ~/.zshrc
#    or {{app_path}} {{completion_command}} >> ~/.zprofile on OSX.
#
_{{app_name}}_yargs_completions()
{
  local reply
  local si=$IFS
  IFS=$'
' reply=($(COMP_CWORD="$((CURRENT-1))" COMP_LINE="$BUFFER" COMP_POINT="$CURSOR" {{app_path}} --get-yargs-completions "\${words[@]}"))
  IFS=$si
  if [[ \${#reply} -gt 0 ]]; then
    _describe 'values' reply
  else
    _default
  fi
}
if [[ "'\${zsh_eval_context[-1]}" == "loadautofunc" ]]; then
  _{{app_name}}_yargs_completions "$@"
else
  compdef _{{app_name}}_yargs_completions {{app_name}}
fi
###-end-{{app_name}}-completions-###
`;

// node_modules/yargs/build/lib/completion.js
class Completion {
  constructor(yargs, usage2, command2, shim2) {
    var _a2, _b2, _c2;
    this.yargs = yargs;
    this.usage = usage2;
    this.command = command2;
    this.shim = shim2;
    this.completionKey = "get-yargs-completions";
    this.aliases = null;
    this.customCompletionFunction = null;
    this.indexAfterLastReset = 0;
    this.zshShell = (_c2 = ((_a2 = this.shim.getEnv("SHELL")) === null || _a2 === undefined ? undefined : _a2.includes("zsh")) || ((_b2 = this.shim.getEnv("ZSH_NAME")) === null || _b2 === undefined ? undefined : _b2.includes("zsh"))) !== null && _c2 !== undefined ? _c2 : false;
  }
  defaultCompletion(args, argv, current, done) {
    const handlers = this.command.getCommandHandlers();
    for (let i = 0, ii = args.length;i < ii; ++i) {
      if (handlers[args[i]] && handlers[args[i]].builder) {
        const builder = handlers[args[i]].builder;
        if (isCommandBuilderCallback(builder)) {
          this.indexAfterLastReset = i + 1;
          const y = this.yargs.getInternalMethods().reset();
          builder(y, true);
          return y.argv;
        }
      }
    }
    const completions = [];
    this.commandCompletions(completions, args, current);
    this.optionCompletions(completions, args, argv, current);
    this.choicesFromOptionsCompletions(completions, args, argv, current);
    this.choicesFromPositionalsCompletions(completions, args, argv, current);
    done(null, completions);
  }
  commandCompletions(completions, args, current) {
    const parentCommands = this.yargs.getInternalMethods().getContext().commands;
    if (!current.match(/^-/) && parentCommands[parentCommands.length - 1] !== current && !this.previousArgHasChoices(args)) {
      this.usage.getCommands().forEach((usageCommand) => {
        const commandName = parseCommand(usageCommand[0]).cmd;
        if (args.indexOf(commandName) === -1) {
          if (!this.zshShell) {
            completions.push(commandName);
          } else {
            const desc = usageCommand[1] || "";
            completions.push(commandName.replace(/:/g, "\\:") + ":" + desc);
          }
        }
      });
    }
  }
  optionCompletions(completions, args, argv, current) {
    if ((current.match(/^-/) || current === "" && completions.length === 0) && !this.previousArgHasChoices(args)) {
      const options = this.yargs.getOptions();
      const positionalKeys = this.yargs.getGroups()[this.usage.getPositionalGroupName()] || [];
      Object.keys(options.key).forEach((key) => {
        const negable = !!options.configuration["boolean-negation"] && options.boolean.includes(key);
        const isPositionalKey = positionalKeys.includes(key);
        if (!isPositionalKey && !options.hiddenOptions.includes(key) && !this.argsContainKey(args, key, negable)) {
          this.completeOptionKey(key, completions, current, negable && !!options.default[key]);
        }
      });
    }
  }
  choicesFromOptionsCompletions(completions, args, argv, current) {
    if (this.previousArgHasChoices(args)) {
      const choices = this.getPreviousArgChoices(args);
      if (choices && choices.length > 0) {
        completions.push(...choices.map((c) => c.replace(/:/g, "\\:")));
      }
    }
  }
  choicesFromPositionalsCompletions(completions, args, argv, current) {
    if (current === "" && completions.length > 0 && this.previousArgHasChoices(args)) {
      return;
    }
    const positionalKeys = this.yargs.getGroups()[this.usage.getPositionalGroupName()] || [];
    const offset = Math.max(this.indexAfterLastReset, this.yargs.getInternalMethods().getContext().commands.length + 1);
    const positionalKey = positionalKeys[argv._.length - offset - 1];
    if (!positionalKey) {
      return;
    }
    const choices = this.yargs.getOptions().choices[positionalKey] || [];
    for (const choice of choices) {
      if (choice.startsWith(current)) {
        completions.push(choice.replace(/:/g, "\\:"));
      }
    }
  }
  getPreviousArgChoices(args) {
    if (args.length < 1)
      return;
    let previousArg = args[args.length - 1];
    let filter = "";
    if (!previousArg.startsWith("-") && args.length > 1) {
      filter = previousArg;
      previousArg = args[args.length - 2];
    }
    if (!previousArg.startsWith("-"))
      return;
    const previousArgKey = previousArg.replace(/^-+/, "");
    const options = this.yargs.getOptions();
    const possibleAliases = [
      previousArgKey,
      ...this.yargs.getAliases()[previousArgKey] || []
    ];
    let choices;
    for (const possibleAlias of possibleAliases) {
      if (Object.prototype.hasOwnProperty.call(options.key, possibleAlias) && Array.isArray(options.choices[possibleAlias])) {
        choices = options.choices[possibleAlias];
        break;
      }
    }
    if (choices) {
      return choices.filter((choice) => !filter || choice.startsWith(filter));
    }
  }
  previousArgHasChoices(args) {
    const choices = this.getPreviousArgChoices(args);
    return choices !== undefined && choices.length > 0;
  }
  argsContainKey(args, key, negable) {
    const argsContains = (s) => args.indexOf((/^[^0-9]$/.test(s) ? "-" : "--") + s) !== -1;
    if (argsContains(key))
      return true;
    if (negable && argsContains(`no-${key}`))
      return true;
    if (this.aliases) {
      for (const alias of this.aliases[key]) {
        if (argsContains(alias))
          return true;
      }
    }
    return false;
  }
  completeOptionKey(key, completions, current, negable) {
    var _a2, _b2, _c2, _d;
    let keyWithDesc = key;
    if (this.zshShell) {
      const descs = this.usage.getDescriptions();
      const aliasKey = (_b2 = (_a2 = this === null || this === undefined ? undefined : this.aliases) === null || _a2 === undefined ? undefined : _a2[key]) === null || _b2 === undefined ? undefined : _b2.find((alias) => {
        const desc2 = descs[alias];
        return typeof desc2 === "string" && desc2.length > 0;
      });
      const descFromAlias = aliasKey ? descs[aliasKey] : undefined;
      const desc = (_d = (_c2 = descs[key]) !== null && _c2 !== undefined ? _c2 : descFromAlias) !== null && _d !== undefined ? _d : "";
      keyWithDesc = `${key.replace(/:/g, "\\:")}:${desc.replace("__yargsString__:", "").replace(/(\r\n|\n|\r)/gm, " ")}`;
    }
    const startsByTwoDashes = (s) => /^--/.test(s);
    const isShortOption = (s) => /^[^0-9]$/.test(s);
    const dashes = !startsByTwoDashes(current) && isShortOption(key) ? "-" : "--";
    completions.push(dashes + keyWithDesc);
    if (negable) {
      completions.push(dashes + "no-" + keyWithDesc);
    }
  }
  customCompletion(args, argv, current, done) {
    assertNotStrictEqual(this.customCompletionFunction, null, this.shim);
    if (isSyncCompletionFunction(this.customCompletionFunction)) {
      const result = this.customCompletionFunction(current, argv);
      if (isPromise(result)) {
        return result.then((list) => {
          this.shim.process.nextTick(() => {
            done(null, list);
          });
        }).catch((err) => {
          this.shim.process.nextTick(() => {
            done(err, undefined);
          });
        });
      }
      return done(null, result);
    } else if (isFallbackCompletionFunction(this.customCompletionFunction)) {
      return this.customCompletionFunction(current, argv, (onCompleted = done) => this.defaultCompletion(args, argv, current, onCompleted), (completions) => {
        done(null, completions);
      });
    } else {
      return this.customCompletionFunction(current, argv, (completions) => {
        done(null, completions);
      });
    }
  }
  getCompletion(args, done) {
    const current = args.length ? args[args.length - 1] : "";
    const argv = this.yargs.parse(args, true);
    const completionFunction = this.customCompletionFunction ? (argv2) => this.customCompletion(args, argv2, current, done) : (argv2) => this.defaultCompletion(args, argv2, current, done);
    return isPromise(argv) ? argv.then(completionFunction) : completionFunction(argv);
  }
  generateCompletionScript($0, cmd) {
    let script = this.zshShell ? completionZshTemplate : completionShTemplate;
    const name = this.shim.path.basename($0);
    if ($0.match(/\.js$/))
      $0 = `./${$0}`;
    script = script.replace(/{{app_name}}/g, name);
    script = script.replace(/{{completion_command}}/g, cmd);
    return script.replace(/{{app_path}}/g, $0);
  }
  registerFunction(fn) {
    this.customCompletionFunction = fn;
  }
  setParsed(parsed) {
    this.aliases = parsed.aliases;
  }
}
function completion(yargs, usage2, command2, shim2) {
  return new Completion(yargs, usage2, command2, shim2);
}
function isSyncCompletionFunction(completionFunction) {
  return completionFunction.length < 3;
}
function isFallbackCompletionFunction(completionFunction) {
  return completionFunction.length > 3;
}

// node_modules/yargs/build/lib/utils/levenshtein.js
function levenshtein(a, b) {
  if (a.length === 0)
    return b.length;
  if (b.length === 0)
    return a.length;
  const matrix = [];
  let i;
  for (i = 0;i <= b.length; i++) {
    matrix[i] = [i];
  }
  let j;
  for (j = 0;j <= a.length; j++) {
    matrix[0][j] = j;
  }
  for (i = 1;i <= b.length; i++) {
    for (j = 1;j <= a.length; j++) {
      if (b.charAt(i - 1) === a.charAt(j - 1)) {
        matrix[i][j] = matrix[i - 1][j - 1];
      } else {
        if (i > 1 && j > 1 && b.charAt(i - 2) === a.charAt(j - 1) && b.charAt(i - 1) === a.charAt(j - 2)) {
          matrix[i][j] = matrix[i - 2][j - 2] + 1;
        } else {
          matrix[i][j] = Math.min(matrix[i - 1][j - 1] + 1, Math.min(matrix[i][j - 1] + 1, matrix[i - 1][j] + 1));
        }
      }
    }
  }
  return matrix[b.length][a.length];
}

// node_modules/yargs/build/lib/validation.js
var specialKeys = ["$0", "--", "_"];
function validation(yargs, usage2, shim2) {
  const __ = shim2.y18n.__;
  const __n = shim2.y18n.__n;
  const self = {};
  self.nonOptionCount = function nonOptionCount(argv) {
    const demandedCommands = yargs.getDemandedCommands();
    const positionalCount = argv._.length + (argv["--"] ? argv["--"].length : 0);
    const _s = positionalCount - yargs.getInternalMethods().getContext().commands.length;
    if (demandedCommands._ && (_s < demandedCommands._.min || _s > demandedCommands._.max)) {
      if (_s < demandedCommands._.min) {
        if (demandedCommands._.minMsg !== undefined) {
          usage2.fail(demandedCommands._.minMsg ? demandedCommands._.minMsg.replace(/\$0/g, _s.toString()).replace(/\$1/, demandedCommands._.min.toString()) : null);
        } else {
          usage2.fail(__n("Not enough non-option arguments: got %s, need at least %s", "Not enough non-option arguments: got %s, need at least %s", _s, _s.toString(), demandedCommands._.min.toString()));
        }
      } else if (_s > demandedCommands._.max) {
        if (demandedCommands._.maxMsg !== undefined) {
          usage2.fail(demandedCommands._.maxMsg ? demandedCommands._.maxMsg.replace(/\$0/g, _s.toString()).replace(/\$1/, demandedCommands._.max.toString()) : null);
        } else {
          usage2.fail(__n("Too many non-option arguments: got %s, maximum of %s", "Too many non-option arguments: got %s, maximum of %s", _s, _s.toString(), demandedCommands._.max.toString()));
        }
      }
    }
  };
  self.positionalCount = function positionalCount(required, observed) {
    if (observed < required) {
      usage2.fail(__n("Not enough non-option arguments: got %s, need at least %s", "Not enough non-option arguments: got %s, need at least %s", observed, observed + "", required + ""));
    }
  };
  self.requiredArguments = function requiredArguments(argv, demandedOptions) {
    let missing = null;
    for (const key of Object.keys(demandedOptions)) {
      if (!Object.prototype.hasOwnProperty.call(argv, key) || typeof argv[key] === "undefined") {
        missing = missing || {};
        missing[key] = demandedOptions[key];
      }
    }
    if (missing) {
      const customMsgs = [];
      for (const key of Object.keys(missing)) {
        const msg = missing[key];
        if (msg && customMsgs.indexOf(msg) < 0) {
          customMsgs.push(msg);
        }
      }
      const customMsg = customMsgs.length ? `
${customMsgs.join(`
`)}` : "";
      usage2.fail(__n("Missing required argument: %s", "Missing required arguments: %s", Object.keys(missing).length, Object.keys(missing).join(", ") + customMsg));
    }
  };
  self.unknownArguments = function unknownArguments(argv, aliases, positionalMap, isDefaultCommand, checkPositionals = true) {
    var _a2;
    const commandKeys = yargs.getInternalMethods().getCommandInstance().getCommands();
    const unknown = [];
    const currentContext = yargs.getInternalMethods().getContext();
    Object.keys(argv).forEach((key) => {
      if (!specialKeys.includes(key) && !Object.prototype.hasOwnProperty.call(positionalMap, key) && !Object.prototype.hasOwnProperty.call(yargs.getInternalMethods().getParseContext(), key) && !self.isValidAndSomeAliasIsNotNew(key, aliases)) {
        unknown.push(key);
      }
    });
    if (checkPositionals && (currentContext.commands.length > 0 || commandKeys.length > 0 || isDefaultCommand)) {
      argv._.slice(currentContext.commands.length).forEach((key) => {
        if (!commandKeys.includes("" + key)) {
          unknown.push("" + key);
        }
      });
    }
    if (checkPositionals) {
      const demandedCommands = yargs.getDemandedCommands();
      const maxNonOptDemanded = ((_a2 = demandedCommands._) === null || _a2 === undefined ? undefined : _a2.max) || 0;
      const expected = currentContext.commands.length + maxNonOptDemanded;
      if (expected < argv._.length) {
        argv._.slice(expected).forEach((key) => {
          key = String(key);
          if (!currentContext.commands.includes(key) && !unknown.includes(key)) {
            unknown.push(key);
          }
        });
      }
    }
    if (unknown.length) {
      usage2.fail(__n("Unknown argument: %s", "Unknown arguments: %s", unknown.length, unknown.map((s) => s.trim() ? s : `"${s}"`).join(", ")));
    }
  };
  self.unknownCommands = function unknownCommands(argv) {
    const commandKeys = yargs.getInternalMethods().getCommandInstance().getCommands();
    const unknown = [];
    const currentContext = yargs.getInternalMethods().getContext();
    if (currentContext.commands.length > 0 || commandKeys.length > 0) {
      argv._.slice(currentContext.commands.length).forEach((key) => {
        if (!commandKeys.includes("" + key)) {
          unknown.push("" + key);
        }
      });
    }
    if (unknown.length > 0) {
      usage2.fail(__n("Unknown command: %s", "Unknown commands: %s", unknown.length, unknown.join(", ")));
      return true;
    } else {
      return false;
    }
  };
  self.isValidAndSomeAliasIsNotNew = function isValidAndSomeAliasIsNotNew(key, aliases) {
    if (!Object.prototype.hasOwnProperty.call(aliases, key)) {
      return false;
    }
    const newAliases = yargs.parsed.newAliases;
    return [key, ...aliases[key]].some((a) => !Object.prototype.hasOwnProperty.call(newAliases, a) || !newAliases[key]);
  };
  self.limitedChoices = function limitedChoices(argv) {
    const options = yargs.getOptions();
    const invalid = {};
    if (!Object.keys(options.choices).length)
      return;
    Object.keys(argv).forEach((key) => {
      if (specialKeys.indexOf(key) === -1 && Object.prototype.hasOwnProperty.call(options.choices, key)) {
        [].concat(argv[key]).forEach((value) => {
          if (options.choices[key].indexOf(value) === -1 && value !== undefined) {
            invalid[key] = (invalid[key] || []).concat(value);
          }
        });
      }
    });
    const invalidKeys = Object.keys(invalid);
    if (!invalidKeys.length)
      return;
    let msg = __("Invalid values:");
    invalidKeys.forEach((key) => {
      msg += `
  ${__("Argument: %s, Given: %s, Choices: %s", key, usage2.stringifiedValues(invalid[key]), usage2.stringifiedValues(options.choices[key]))}`;
    });
    usage2.fail(msg);
  };
  let implied = {};
  self.implies = function implies(key, value) {
    argsert("<string|object> [array|number|string]", [key, value], arguments.length);
    if (typeof key === "object") {
      Object.keys(key).forEach((k) => {
        self.implies(k, key[k]);
      });
    } else {
      yargs.global(key);
      if (!implied[key]) {
        implied[key] = [];
      }
      if (Array.isArray(value)) {
        value.forEach((i) => self.implies(key, i));
      } else {
        assertNotStrictEqual(value, undefined, shim2);
        implied[key].push(value);
      }
    }
  };
  self.getImplied = function getImplied() {
    return implied;
  };
  function keyExists(argv, val) {
    const num = Number(val);
    val = isNaN(num) ? val : num;
    if (typeof val === "number") {
      val = argv._.length >= val;
    } else if (val.match(/^--no-.+/)) {
      val = val.match(/^--no-(.+)/)[1];
      val = !Object.prototype.hasOwnProperty.call(argv, val);
    } else {
      val = Object.prototype.hasOwnProperty.call(argv, val);
    }
    return val;
  }
  self.implications = function implications(argv) {
    const implyFail = [];
    Object.keys(implied).forEach((key) => {
      const origKey = key;
      (implied[key] || []).forEach((value) => {
        let key2 = origKey;
        const origValue = value;
        key2 = keyExists(argv, key2);
        value = keyExists(argv, value);
        if (key2 && !value) {
          implyFail.push(` ${origKey} -> ${origValue}`);
        }
      });
    });
    if (implyFail.length) {
      let msg = `${__("Implications failed:")}
`;
      implyFail.forEach((value) => {
        msg += value;
      });
      usage2.fail(msg);
    }
  };
  let conflicting = {};
  self.conflicts = function conflicts(key, value) {
    argsert("<string|object> [array|string]", [key, value], arguments.length);
    if (typeof key === "object") {
      Object.keys(key).forEach((k) => {
        self.conflicts(k, key[k]);
      });
    } else {
      yargs.global(key);
      if (!conflicting[key]) {
        conflicting[key] = [];
      }
      if (Array.isArray(value)) {
        value.forEach((i) => self.conflicts(key, i));
      } else {
        conflicting[key].push(value);
      }
    }
  };
  self.getConflicting = () => conflicting;
  self.conflicting = function conflictingFn(argv) {
    Object.keys(argv).forEach((key) => {
      if (conflicting[key]) {
        conflicting[key].forEach((value) => {
          if (value && argv[key] !== undefined && argv[value] !== undefined) {
            usage2.fail(__("Arguments %s and %s are mutually exclusive", key, value));
          }
        });
      }
    });
    if (yargs.getInternalMethods().getParserConfiguration()["strip-dashed"]) {
      Object.keys(conflicting).forEach((key) => {
        conflicting[key].forEach((value) => {
          if (value && argv[shim2.Parser.camelCase(key)] !== undefined && argv[shim2.Parser.camelCase(value)] !== undefined) {
            usage2.fail(__("Arguments %s and %s are mutually exclusive", key, value));
          }
        });
      });
    }
  };
  self.recommendCommands = function recommendCommands(cmd, potentialCommands) {
    const threshold = 3;
    potentialCommands = potentialCommands.sort((a, b) => b.length - a.length);
    let recommended = null;
    let bestDistance = Infinity;
    for (let i = 0, candidate;(candidate = potentialCommands[i]) !== undefined; i++) {
      const d = levenshtein(cmd, candidate);
      if (d <= threshold && d < bestDistance) {
        bestDistance = d;
        recommended = candidate;
      }
    }
    if (recommended)
      usage2.fail(__("Did you mean %s?", recommended));
  };
  self.reset = function reset(localLookup) {
    implied = objFilter(implied, (k) => !localLookup[k]);
    conflicting = objFilter(conflicting, (k) => !localLookup[k]);
    return self;
  };
  const frozens = [];
  self.freeze = function freeze() {
    frozens.push({
      implied,
      conflicting
    });
  };
  self.unfreeze = function unfreeze() {
    const frozen = frozens.pop();
    assertNotStrictEqual(frozen, undefined, shim2);
    ({ implied, conflicting } = frozen);
  };
  return self;
}

// node_modules/yargs/build/lib/utils/apply-extends.js
var previouslyVisitedConfigs = [];
var shim2;
function applyExtends(config, cwd, mergeExtends, _shim) {
  shim2 = _shim;
  let defaultConfig = {};
  if (Object.prototype.hasOwnProperty.call(config, "extends")) {
    if (typeof config.extends !== "string")
      return defaultConfig;
    const isPath = /\.json|\..*rc$/.test(config.extends);
    let pathToDefault = null;
    if (!isPath) {
      try {
        pathToDefault = import.meta.resolve(config.extends);
      } catch (_err) {
        return config;
      }
    } else {
      pathToDefault = getPathToDefaultConfig(cwd, config.extends);
    }
    checkForCircularExtends(pathToDefault);
    previouslyVisitedConfigs.push(pathToDefault);
    defaultConfig = isPath ? JSON.parse(shim2.readFileSync(pathToDefault, "utf8")) : _shim.require(config.extends);
    delete config.extends;
    defaultConfig = applyExtends(defaultConfig, shim2.path.dirname(pathToDefault), mergeExtends, shim2);
  }
  previouslyVisitedConfigs = [];
  return mergeExtends ? mergeDeep(defaultConfig, config) : Object.assign({}, defaultConfig, config);
}
function checkForCircularExtends(cfgPath) {
  if (previouslyVisitedConfigs.indexOf(cfgPath) > -1) {
    throw new YError(`Circular extended configurations: '${cfgPath}'.`);
  }
}
function getPathToDefaultConfig(cwd, pathToExtend) {
  return shim2.path.resolve(cwd, pathToExtend);
}
function mergeDeep(config1, config2) {
  const target = {};
  function isObject(obj) {
    return obj && typeof obj === "object" && !Array.isArray(obj);
  }
  Object.assign(target, config1);
  for (const key of Object.keys(config2)) {
    if (isObject(config2[key]) && isObject(target[key])) {
      target[key] = mergeDeep(config1[key], config2[key]);
    } else {
      target[key] = config2[key];
    }
  }
  return target;
}

// node_modules/yargs/build/lib/yargs-factory.js
var __classPrivateFieldSet = function(receiver, state, value, kind, f) {
  if (kind === "m")
    throw new TypeError("Private method is not writable");
  if (kind === "a" && !f)
    throw new TypeError("Private accessor was defined without a setter");
  if (typeof state === "function" ? receiver !== state || !f : !state.has(receiver))
    throw new TypeError("Cannot write private member to an object whose class did not declare it");
  return kind === "a" ? f.call(receiver, value) : f ? f.value = value : state.set(receiver, value), value;
};
var __classPrivateFieldGet = function(receiver, state, kind, f) {
  if (kind === "a" && !f)
    throw new TypeError("Private accessor was defined without a getter");
  if (typeof state === "function" ? receiver !== state || !f : !state.has(receiver))
    throw new TypeError("Cannot read private member from an object whose class did not declare it");
  return kind === "m" ? f : kind === "a" ? f.call(receiver) : f ? f.value : state.get(receiver);
};
var _YargsInstance_command;
var _YargsInstance_cwd;
var _YargsInstance_context;
var _YargsInstance_completion;
var _YargsInstance_completionCommand;
var _YargsInstance_defaultShowHiddenOpt;
var _YargsInstance_exitError;
var _YargsInstance_detectLocale;
var _YargsInstance_emittedWarnings;
var _YargsInstance_exitProcess;
var _YargsInstance_frozens;
var _YargsInstance_globalMiddleware;
var _YargsInstance_groups;
var _YargsInstance_hasOutput;
var _YargsInstance_helpOpt;
var _YargsInstance_isGlobalContext;
var _YargsInstance_logger;
var _YargsInstance_output;
var _YargsInstance_options;
var _YargsInstance_parentRequire;
var _YargsInstance_parserConfig;
var _YargsInstance_parseFn;
var _YargsInstance_parseContext;
var _YargsInstance_pkgs;
var _YargsInstance_preservedGroups;
var _YargsInstance_processArgs;
var _YargsInstance_recommendCommands;
var _YargsInstance_shim;
var _YargsInstance_strict;
var _YargsInstance_strictCommands;
var _YargsInstance_strictOptions;
var _YargsInstance_usage;
var _YargsInstance_usageConfig;
var _YargsInstance_versionOpt;
var _YargsInstance_validation;
function YargsFactory(_shim) {
  return (processArgs = [], cwd = _shim.process.cwd(), parentRequire) => {
    const yargs = new YargsInstance(processArgs, cwd, parentRequire, _shim);
    Object.defineProperty(yargs, "argv", {
      get: () => {
        return yargs.parse();
      },
      enumerable: true
    });
    yargs.help();
    yargs.version();
    return yargs;
  };
}
var kCopyDoubleDash = Symbol("copyDoubleDash");
var kCreateLogger = Symbol("copyDoubleDash");
var kDeleteFromParserHintObject = Symbol("deleteFromParserHintObject");
var kEmitWarning = Symbol("emitWarning");
var kFreeze = Symbol("freeze");
var kGetDollarZero = Symbol("getDollarZero");
var kGetParserConfiguration = Symbol("getParserConfiguration");
var kGetUsageConfiguration = Symbol("getUsageConfiguration");
var kGuessLocale = Symbol("guessLocale");
var kGuessVersion = Symbol("guessVersion");
var kParsePositionalNumbers = Symbol("parsePositionalNumbers");
var kPkgUp = Symbol("pkgUp");
var kPopulateParserHintArray = Symbol("populateParserHintArray");
var kPopulateParserHintSingleValueDictionary = Symbol("populateParserHintSingleValueDictionary");
var kPopulateParserHintArrayDictionary = Symbol("populateParserHintArrayDictionary");
var kPopulateParserHintDictionary = Symbol("populateParserHintDictionary");
var kSanitizeKey = Symbol("sanitizeKey");
var kSetKey = Symbol("setKey");
var kUnfreeze = Symbol("unfreeze");
var kValidateAsync = Symbol("validateAsync");
var kGetCommandInstance = Symbol("getCommandInstance");
var kGetContext = Symbol("getContext");
var kGetHasOutput = Symbol("getHasOutput");
var kGetLoggerInstance = Symbol("getLoggerInstance");
var kGetParseContext = Symbol("getParseContext");
var kGetUsageInstance = Symbol("getUsageInstance");
var kGetValidationInstance = Symbol("getValidationInstance");
var kHasParseCallback = Symbol("hasParseCallback");
var kIsGlobalContext = Symbol("isGlobalContext");
var kPostProcess = Symbol("postProcess");
var kRebase = Symbol("rebase");
var kReset = Symbol("reset");
var kRunYargsParserAndExecuteCommands = Symbol("runYargsParserAndExecuteCommands");
var kRunValidation = Symbol("runValidation");
var kSetHasOutput = Symbol("setHasOutput");
var kTrackManuallySetKeys = Symbol("kTrackManuallySetKeys");
var DEFAULT_LOCALE = "en_US";

class YargsInstance {
  constructor(processArgs = [], cwd, parentRequire, shim3) {
    this.customScriptName = false;
    this.parsed = false;
    _YargsInstance_command.set(this, undefined);
    _YargsInstance_cwd.set(this, undefined);
    _YargsInstance_context.set(this, { commands: [], fullCommands: [] });
    _YargsInstance_completion.set(this, null);
    _YargsInstance_completionCommand.set(this, null);
    _YargsInstance_defaultShowHiddenOpt.set(this, "show-hidden");
    _YargsInstance_exitError.set(this, null);
    _YargsInstance_detectLocale.set(this, true);
    _YargsInstance_emittedWarnings.set(this, {});
    _YargsInstance_exitProcess.set(this, true);
    _YargsInstance_frozens.set(this, []);
    _YargsInstance_globalMiddleware.set(this, undefined);
    _YargsInstance_groups.set(this, {});
    _YargsInstance_hasOutput.set(this, false);
    _YargsInstance_helpOpt.set(this, null);
    _YargsInstance_isGlobalContext.set(this, true);
    _YargsInstance_logger.set(this, undefined);
    _YargsInstance_output.set(this, "");
    _YargsInstance_options.set(this, undefined);
    _YargsInstance_parentRequire.set(this, undefined);
    _YargsInstance_parserConfig.set(this, {});
    _YargsInstance_parseFn.set(this, null);
    _YargsInstance_parseContext.set(this, null);
    _YargsInstance_pkgs.set(this, {});
    _YargsInstance_preservedGroups.set(this, {});
    _YargsInstance_processArgs.set(this, undefined);
    _YargsInstance_recommendCommands.set(this, false);
    _YargsInstance_shim.set(this, undefined);
    _YargsInstance_strict.set(this, false);
    _YargsInstance_strictCommands.set(this, false);
    _YargsInstance_strictOptions.set(this, false);
    _YargsInstance_usage.set(this, undefined);
    _YargsInstance_usageConfig.set(this, {});
    _YargsInstance_versionOpt.set(this, null);
    _YargsInstance_validation.set(this, undefined);
    __classPrivateFieldSet(this, _YargsInstance_shim, shim3, "f");
    __classPrivateFieldSet(this, _YargsInstance_processArgs, processArgs, "f");
    __classPrivateFieldSet(this, _YargsInstance_cwd, cwd, "f");
    __classPrivateFieldSet(this, _YargsInstance_parentRequire, parentRequire, "f");
    __classPrivateFieldSet(this, _YargsInstance_globalMiddleware, new GlobalMiddleware(this), "f");
    this.$0 = this[kGetDollarZero]();
    this[kReset]();
    __classPrivateFieldSet(this, _YargsInstance_command, __classPrivateFieldGet(this, _YargsInstance_command, "f"), "f");
    __classPrivateFieldSet(this, _YargsInstance_usage, __classPrivateFieldGet(this, _YargsInstance_usage, "f"), "f");
    __classPrivateFieldSet(this, _YargsInstance_validation, __classPrivateFieldGet(this, _YargsInstance_validation, "f"), "f");
    __classPrivateFieldSet(this, _YargsInstance_options, __classPrivateFieldGet(this, _YargsInstance_options, "f"), "f");
    __classPrivateFieldGet(this, _YargsInstance_options, "f").showHiddenOpt = __classPrivateFieldGet(this, _YargsInstance_defaultShowHiddenOpt, "f");
    __classPrivateFieldSet(this, _YargsInstance_logger, this[kCreateLogger](), "f");
    __classPrivateFieldGet(this, _YargsInstance_shim, "f").y18n.setLocale(DEFAULT_LOCALE);
  }
  addHelpOpt(opt, msg) {
    const defaultHelpOpt = "help";
    argsert("[string|boolean] [string]", [opt, msg], arguments.length);
    if (__classPrivateFieldGet(this, _YargsInstance_helpOpt, "f")) {
      this[kDeleteFromParserHintObject](__classPrivateFieldGet(this, _YargsInstance_helpOpt, "f"));
      __classPrivateFieldSet(this, _YargsInstance_helpOpt, null, "f");
    }
    if (opt === false && msg === undefined)
      return this;
    __classPrivateFieldSet(this, _YargsInstance_helpOpt, typeof opt === "string" ? opt : defaultHelpOpt, "f");
    this.boolean(__classPrivateFieldGet(this, _YargsInstance_helpOpt, "f"));
    this.describe(__classPrivateFieldGet(this, _YargsInstance_helpOpt, "f"), msg || __classPrivateFieldGet(this, _YargsInstance_usage, "f").deferY18nLookup("Show help"));
    return this;
  }
  help(opt, msg) {
    return this.addHelpOpt(opt, msg);
  }
  addShowHiddenOpt(opt, msg) {
    argsert("[string|boolean] [string]", [opt, msg], arguments.length);
    if (opt === false && msg === undefined)
      return this;
    const showHiddenOpt = typeof opt === "string" ? opt : __classPrivateFieldGet(this, _YargsInstance_defaultShowHiddenOpt, "f");
    this.boolean(showHiddenOpt);
    this.describe(showHiddenOpt, msg || __classPrivateFieldGet(this, _YargsInstance_usage, "f").deferY18nLookup("Show hidden options"));
    __classPrivateFieldGet(this, _YargsInstance_options, "f").showHiddenOpt = showHiddenOpt;
    return this;
  }
  showHidden(opt, msg) {
    return this.addShowHiddenOpt(opt, msg);
  }
  alias(key, value) {
    argsert("<object|string|array> [string|array]", [key, value], arguments.length);
    this[kPopulateParserHintArrayDictionary](this.alias.bind(this), "alias", key, value);
    return this;
  }
  array(keys) {
    argsert("<array|string>", [keys], arguments.length);
    this[kPopulateParserHintArray]("array", keys);
    this[kTrackManuallySetKeys](keys);
    return this;
  }
  boolean(keys) {
    argsert("<array|string>", [keys], arguments.length);
    this[kPopulateParserHintArray]("boolean", keys);
    this[kTrackManuallySetKeys](keys);
    return this;
  }
  check(f, global) {
    argsert("<function> [boolean]", [f, global], arguments.length);
    this.middleware((argv, _yargs) => {
      return maybeAsyncResult(() => {
        return f(argv, _yargs.getOptions());
      }, (result) => {
        if (!result) {
          __classPrivateFieldGet(this, _YargsInstance_usage, "f").fail(__classPrivateFieldGet(this, _YargsInstance_shim, "f").y18n.__("Argument check failed: %s", f.toString()));
        } else if (typeof result === "string" || result instanceof Error) {
          __classPrivateFieldGet(this, _YargsInstance_usage, "f").fail(result.toString(), result);
        }
        return argv;
      }, (err) => {
        __classPrivateFieldGet(this, _YargsInstance_usage, "f").fail(err.message ? err.message : err.toString(), err);
        return argv;
      });
    }, false, global);
    return this;
  }
  choices(key, value) {
    argsert("<object|string|array> [string|array]", [key, value], arguments.length);
    this[kPopulateParserHintArrayDictionary](this.choices.bind(this), "choices", key, value);
    return this;
  }
  coerce(keys, value) {
    argsert("<object|string|array> [function]", [keys, value], arguments.length);
    if (Array.isArray(keys)) {
      if (!value) {
        throw new YError("coerce callback must be provided");
      }
      for (const key of keys) {
        this.coerce(key, value);
      }
      return this;
    } else if (typeof keys === "object") {
      for (const key of Object.keys(keys)) {
        this.coerce(key, keys[key]);
      }
      return this;
    }
    if (!value) {
      throw new YError("coerce callback must be provided");
    }
    const coerceKey = keys;
    __classPrivateFieldGet(this, _YargsInstance_options, "f").key[coerceKey] = true;
    __classPrivateFieldGet(this, _YargsInstance_globalMiddleware, "f").addCoerceMiddleware((argv, yargs) => {
      var _a2;
      const coerceKeyAliases = (_a2 = yargs.getAliases()[coerceKey]) !== null && _a2 !== undefined ? _a2 : [];
      const argvKeys = [coerceKey, ...coerceKeyAliases].filter((key) => Object.prototype.hasOwnProperty.call(argv, key));
      if (argvKeys.length === 0) {
        return argv;
      }
      return maybeAsyncResult(() => {
        return value(argv[argvKeys[0]]);
      }, (result) => {
        argvKeys.forEach((key) => {
          argv[key] = result;
        });
        return argv;
      }, (err) => {
        throw new YError(err.message);
      });
    }, coerceKey);
    return this;
  }
  conflicts(key1, key2) {
    argsert("<string|object> [string|array]", [key1, key2], arguments.length);
    __classPrivateFieldGet(this, _YargsInstance_validation, "f").conflicts(key1, key2);
    return this;
  }
  config(key = "config", msg, parseFn) {
    argsert("[object|string] [string|function] [function]", [key, msg, parseFn], arguments.length);
    if (typeof key === "object" && !Array.isArray(key)) {
      key = applyExtends(key, __classPrivateFieldGet(this, _YargsInstance_cwd, "f"), this[kGetParserConfiguration]()["deep-merge-config"] || false, __classPrivateFieldGet(this, _YargsInstance_shim, "f"));
      __classPrivateFieldGet(this, _YargsInstance_options, "f").configObjects = (__classPrivateFieldGet(this, _YargsInstance_options, "f").configObjects || []).concat(key);
      return this;
    }
    if (typeof msg === "function") {
      parseFn = msg;
      msg = undefined;
    }
    this.describe(key, msg || __classPrivateFieldGet(this, _YargsInstance_usage, "f").deferY18nLookup("Path to JSON config file"));
    (Array.isArray(key) ? key : [key]).forEach((k) => {
      __classPrivateFieldGet(this, _YargsInstance_options, "f").config[k] = parseFn || true;
    });
    return this;
  }
  completion(cmd, desc, fn) {
    argsert("[string] [string|boolean|function] [function]", [cmd, desc, fn], arguments.length);
    if (typeof desc === "function") {
      fn = desc;
      desc = undefined;
    }
    __classPrivateFieldSet(this, _YargsInstance_completionCommand, cmd || __classPrivateFieldGet(this, _YargsInstance_completionCommand, "f") || "completion", "f");
    if (!desc && desc !== false) {
      desc = "generate completion script";
    }
    this.command(__classPrivateFieldGet(this, _YargsInstance_completionCommand, "f"), desc);
    if (fn)
      __classPrivateFieldGet(this, _YargsInstance_completion, "f").registerFunction(fn);
    return this;
  }
  command(cmd, description, builder, handler, middlewares, deprecated) {
    argsert("<string|array|object> [string|boolean] [function|object] [function] [array] [boolean|string]", [cmd, description, builder, handler, middlewares, deprecated], arguments.length);
    __classPrivateFieldGet(this, _YargsInstance_command, "f").addHandler(cmd, description, builder, handler, middlewares, deprecated);
    return this;
  }
  commands(cmd, description, builder, handler, middlewares, deprecated) {
    return this.command(cmd, description, builder, handler, middlewares, deprecated);
  }
  commandDir(dir, opts) {
    argsert("<string> [object]", [dir, opts], arguments.length);
    const req = __classPrivateFieldGet(this, _YargsInstance_parentRequire, "f") || __classPrivateFieldGet(this, _YargsInstance_shim, "f").require;
    __classPrivateFieldGet(this, _YargsInstance_command, "f").addDirectory(dir, req, __classPrivateFieldGet(this, _YargsInstance_shim, "f").getCallerFile(), opts);
    return this;
  }
  count(keys) {
    argsert("<array|string>", [keys], arguments.length);
    this[kPopulateParserHintArray]("count", keys);
    this[kTrackManuallySetKeys](keys);
    return this;
  }
  default(key, value, defaultDescription) {
    argsert("<object|string|array> [*] [string]", [key, value, defaultDescription], arguments.length);
    if (defaultDescription) {
      assertSingleKey(key, __classPrivateFieldGet(this, _YargsInstance_shim, "f"));
      __classPrivateFieldGet(this, _YargsInstance_options, "f").defaultDescription[key] = defaultDescription;
    }
    if (typeof value === "function") {
      assertSingleKey(key, __classPrivateFieldGet(this, _YargsInstance_shim, "f"));
      if (!__classPrivateFieldGet(this, _YargsInstance_options, "f").defaultDescription[key])
        __classPrivateFieldGet(this, _YargsInstance_options, "f").defaultDescription[key] = __classPrivateFieldGet(this, _YargsInstance_usage, "f").functionDescription(value);
      value = value.call();
    }
    this[kPopulateParserHintSingleValueDictionary](this.default.bind(this), "default", key, value);
    return this;
  }
  defaults(key, value, defaultDescription) {
    return this.default(key, value, defaultDescription);
  }
  demandCommand(min = 1, max, minMsg, maxMsg) {
    argsert("[number] [number|string] [string|null|undefined] [string|null|undefined]", [min, max, minMsg, maxMsg], arguments.length);
    if (typeof max !== "number") {
      minMsg = max;
      max = Infinity;
    }
    this.global("_", false);
    __classPrivateFieldGet(this, _YargsInstance_options, "f").demandedCommands._ = {
      min,
      max,
      minMsg,
      maxMsg
    };
    return this;
  }
  demand(keys, max, msg) {
    if (Array.isArray(max)) {
      max.forEach((key) => {
        assertNotStrictEqual(msg, true, __classPrivateFieldGet(this, _YargsInstance_shim, "f"));
        this.demandOption(key, msg);
      });
      max = Infinity;
    } else if (typeof max !== "number") {
      msg = max;
      max = Infinity;
    }
    if (typeof keys === "number") {
      assertNotStrictEqual(msg, true, __classPrivateFieldGet(this, _YargsInstance_shim, "f"));
      this.demandCommand(keys, max, msg, msg);
    } else if (Array.isArray(keys)) {
      keys.forEach((key) => {
        assertNotStrictEqual(msg, true, __classPrivateFieldGet(this, _YargsInstance_shim, "f"));
        this.demandOption(key, msg);
      });
    } else {
      if (typeof msg === "string") {
        this.demandOption(keys, msg);
      } else if (msg === true || typeof msg === "undefined") {
        this.demandOption(keys);
      }
    }
    return this;
  }
  demandOption(keys, msg) {
    argsert("<object|string|array> [string]", [keys, msg], arguments.length);
    this[kPopulateParserHintSingleValueDictionary](this.demandOption.bind(this), "demandedOptions", keys, msg);
    return this;
  }
  deprecateOption(option, message) {
    argsert("<string> [string|boolean]", [option, message], arguments.length);
    __classPrivateFieldGet(this, _YargsInstance_options, "f").deprecatedOptions[option] = message;
    return this;
  }
  describe(keys, description) {
    argsert("<object|string|array> [string]", [keys, description], arguments.length);
    this[kSetKey](keys, true);
    __classPrivateFieldGet(this, _YargsInstance_usage, "f").describe(keys, description);
    return this;
  }
  detectLocale(detect) {
    argsert("<boolean>", [detect], arguments.length);
    __classPrivateFieldSet(this, _YargsInstance_detectLocale, detect, "f");
    return this;
  }
  env(prefix) {
    argsert("[string|boolean]", [prefix], arguments.length);
    if (prefix === false)
      delete __classPrivateFieldGet(this, _YargsInstance_options, "f").envPrefix;
    else
      __classPrivateFieldGet(this, _YargsInstance_options, "f").envPrefix = prefix || "";
    return this;
  }
  epilogue(msg) {
    argsert("<string>", [msg], arguments.length);
    __classPrivateFieldGet(this, _YargsInstance_usage, "f").epilog(msg);
    return this;
  }
  epilog(msg) {
    return this.epilogue(msg);
  }
  example(cmd, description) {
    argsert("<string|array> [string]", [cmd, description], arguments.length);
    if (Array.isArray(cmd)) {
      cmd.forEach((exampleParams) => this.example(...exampleParams));
    } else {
      __classPrivateFieldGet(this, _YargsInstance_usage, "f").example(cmd, description);
    }
    return this;
  }
  exit(code, err) {
    __classPrivateFieldSet(this, _YargsInstance_hasOutput, true, "f");
    __classPrivateFieldSet(this, _YargsInstance_exitError, err, "f");
    if (__classPrivateFieldGet(this, _YargsInstance_exitProcess, "f"))
      __classPrivateFieldGet(this, _YargsInstance_shim, "f").process.exit(code);
  }
  exitProcess(enabled = true) {
    argsert("[boolean]", [enabled], arguments.length);
    __classPrivateFieldSet(this, _YargsInstance_exitProcess, enabled, "f");
    return this;
  }
  fail(f) {
    argsert("<function|boolean>", [f], arguments.length);
    if (typeof f === "boolean" && f !== false) {
      throw new YError("Invalid first argument. Expected function or boolean 'false'");
    }
    __classPrivateFieldGet(this, _YargsInstance_usage, "f").failFn(f);
    return this;
  }
  getAliases() {
    return this.parsed ? this.parsed.aliases : {};
  }
  async getCompletion(args, done) {
    argsert("<array> [function]", [args, done], arguments.length);
    if (!done) {
      return new Promise((resolve5, reject) => {
        __classPrivateFieldGet(this, _YargsInstance_completion, "f").getCompletion(args, (err, completions) => {
          if (err)
            reject(err);
          else
            resolve5(completions);
        });
      });
    } else {
      return __classPrivateFieldGet(this, _YargsInstance_completion, "f").getCompletion(args, done);
    }
  }
  getDemandedOptions() {
    argsert([], 0);
    return __classPrivateFieldGet(this, _YargsInstance_options, "f").demandedOptions;
  }
  getDemandedCommands() {
    argsert([], 0);
    return __classPrivateFieldGet(this, _YargsInstance_options, "f").demandedCommands;
  }
  getDeprecatedOptions() {
    argsert([], 0);
    return __classPrivateFieldGet(this, _YargsInstance_options, "f").deprecatedOptions;
  }
  getDetectLocale() {
    return __classPrivateFieldGet(this, _YargsInstance_detectLocale, "f");
  }
  getExitProcess() {
    return __classPrivateFieldGet(this, _YargsInstance_exitProcess, "f");
  }
  getGroups() {
    return Object.assign({}, __classPrivateFieldGet(this, _YargsInstance_groups, "f"), __classPrivateFieldGet(this, _YargsInstance_preservedGroups, "f"));
  }
  getHelp() {
    __classPrivateFieldSet(this, _YargsInstance_hasOutput, true, "f");
    if (!__classPrivateFieldGet(this, _YargsInstance_usage, "f").hasCachedHelpMessage()) {
      if (!this.parsed) {
        const parse = this[kRunYargsParserAndExecuteCommands](__classPrivateFieldGet(this, _YargsInstance_processArgs, "f"), undefined, undefined, 0, true);
        if (isPromise(parse)) {
          return parse.then(() => {
            return __classPrivateFieldGet(this, _YargsInstance_usage, "f").help();
          });
        }
      }
      const builderResponse = __classPrivateFieldGet(this, _YargsInstance_command, "f").runDefaultBuilderOn(this);
      if (isPromise(builderResponse)) {
        return builderResponse.then(() => {
          return __classPrivateFieldGet(this, _YargsInstance_usage, "f").help();
        });
      }
    }
    return Promise.resolve(__classPrivateFieldGet(this, _YargsInstance_usage, "f").help());
  }
  getOptions() {
    return __classPrivateFieldGet(this, _YargsInstance_options, "f");
  }
  getStrict() {
    return __classPrivateFieldGet(this, _YargsInstance_strict, "f");
  }
  getStrictCommands() {
    return __classPrivateFieldGet(this, _YargsInstance_strictCommands, "f");
  }
  getStrictOptions() {
    return __classPrivateFieldGet(this, _YargsInstance_strictOptions, "f");
  }
  global(globals, global) {
    argsert("<string|array> [boolean]", [globals, global], arguments.length);
    globals = [].concat(globals);
    if (global !== false) {
      __classPrivateFieldGet(this, _YargsInstance_options, "f").local = __classPrivateFieldGet(this, _YargsInstance_options, "f").local.filter((l) => globals.indexOf(l) === -1);
    } else {
      globals.forEach((g) => {
        if (!__classPrivateFieldGet(this, _YargsInstance_options, "f").local.includes(g))
          __classPrivateFieldGet(this, _YargsInstance_options, "f").local.push(g);
      });
    }
    return this;
  }
  group(opts, groupName) {
    argsert("<string|array> <string>", [opts, groupName], arguments.length);
    const existing = __classPrivateFieldGet(this, _YargsInstance_preservedGroups, "f")[groupName] || __classPrivateFieldGet(this, _YargsInstance_groups, "f")[groupName];
    if (__classPrivateFieldGet(this, _YargsInstance_preservedGroups, "f")[groupName]) {
      delete __classPrivateFieldGet(this, _YargsInstance_preservedGroups, "f")[groupName];
    }
    const seen = {};
    __classPrivateFieldGet(this, _YargsInstance_groups, "f")[groupName] = (existing || []).concat(opts).filter((key) => {
      if (seen[key])
        return false;
      return seen[key] = true;
    });
    return this;
  }
  hide(key) {
    argsert("<string>", [key], arguments.length);
    __classPrivateFieldGet(this, _YargsInstance_options, "f").hiddenOptions.push(key);
    return this;
  }
  implies(key, value) {
    argsert("<string|object> [number|string|array]", [key, value], arguments.length);
    __classPrivateFieldGet(this, _YargsInstance_validation, "f").implies(key, value);
    return this;
  }
  locale(locale) {
    argsert("[string]", [locale], arguments.length);
    if (locale === undefined) {
      this[kGuessLocale]();
      return __classPrivateFieldGet(this, _YargsInstance_shim, "f").y18n.getLocale();
    }
    __classPrivateFieldSet(this, _YargsInstance_detectLocale, false, "f");
    __classPrivateFieldGet(this, _YargsInstance_shim, "f").y18n.setLocale(locale);
    return this;
  }
  middleware(callback, applyBeforeValidation, global) {
    return __classPrivateFieldGet(this, _YargsInstance_globalMiddleware, "f").addMiddleware(callback, !!applyBeforeValidation, global);
  }
  nargs(key, value) {
    argsert("<string|object|array> [number]", [key, value], arguments.length);
    this[kPopulateParserHintSingleValueDictionary](this.nargs.bind(this), "narg", key, value);
    return this;
  }
  normalize(keys) {
    argsert("<array|string>", [keys], arguments.length);
    this[kPopulateParserHintArray]("normalize", keys);
    return this;
  }
  number(keys) {
    argsert("<array|string>", [keys], arguments.length);
    this[kPopulateParserHintArray]("number", keys);
    this[kTrackManuallySetKeys](keys);
    return this;
  }
  option(key, opt) {
    argsert("<string|object> [object]", [key, opt], arguments.length);
    if (typeof key === "object") {
      Object.keys(key).forEach((k) => {
        this.options(k, key[k]);
      });
    } else {
      if (typeof opt !== "object") {
        opt = {};
      }
      this[kTrackManuallySetKeys](key);
      if (__classPrivateFieldGet(this, _YargsInstance_versionOpt, "f") && (key === "version" || (opt === null || opt === undefined ? undefined : opt.alias) === "version")) {
        this[kEmitWarning]([
          '"version" is a reserved word.',
          "Please do one of the following:",
          '- Disable version with `yargs.version(false)` if using "version" as an option',
          "- Use the built-in `yargs.version` method instead (if applicable)",
          "- Use a different option key",
          "https://yargs.js.org/docs/#api-reference-version"
        ].join(`
`), undefined, "versionWarning");
      }
      __classPrivateFieldGet(this, _YargsInstance_options, "f").key[key] = true;
      if (opt.alias)
        this.alias(key, opt.alias);
      const deprecate = opt.deprecate || opt.deprecated;
      if (deprecate) {
        this.deprecateOption(key, deprecate);
      }
      const demand = opt.demand || opt.required || opt.require;
      if (demand) {
        this.demand(key, demand);
      }
      if (opt.demandOption) {
        this.demandOption(key, typeof opt.demandOption === "string" ? opt.demandOption : undefined);
      }
      if (opt.conflicts) {
        this.conflicts(key, opt.conflicts);
      }
      if ("default" in opt) {
        this.default(key, opt.default);
      }
      if (opt.implies !== undefined) {
        this.implies(key, opt.implies);
      }
      if (opt.nargs !== undefined) {
        this.nargs(key, opt.nargs);
      }
      if (opt.config) {
        this.config(key, opt.configParser);
      }
      if (opt.normalize) {
        this.normalize(key);
      }
      if (opt.choices) {
        this.choices(key, opt.choices);
      }
      if (opt.coerce) {
        this.coerce(key, opt.coerce);
      }
      if (opt.group) {
        this.group(key, opt.group);
      }
      if (opt.boolean || opt.type === "boolean") {
        this.boolean(key);
        if (opt.alias)
          this.boolean(opt.alias);
      }
      if (opt.array || opt.type === "array") {
        this.array(key);
        if (opt.alias)
          this.array(opt.alias);
      }
      if (opt.number || opt.type === "number") {
        this.number(key);
        if (opt.alias)
          this.number(opt.alias);
      }
      if (opt.string || opt.type === "string") {
        this.string(key);
        if (opt.alias)
          this.string(opt.alias);
      }
      if (opt.count || opt.type === "count") {
        this.count(key);
      }
      if (typeof opt.global === "boolean") {
        this.global(key, opt.global);
      }
      if (opt.defaultDescription) {
        __classPrivateFieldGet(this, _YargsInstance_options, "f").defaultDescription[key] = opt.defaultDescription;
      }
      if (opt.skipValidation) {
        this.skipValidation(key);
      }
      const desc = opt.describe || opt.description || opt.desc;
      const descriptions = __classPrivateFieldGet(this, _YargsInstance_usage, "f").getDescriptions();
      if (!Object.prototype.hasOwnProperty.call(descriptions, key) || typeof desc === "string") {
        this.describe(key, desc);
      }
      if (opt.hidden) {
        this.hide(key);
      }
      if (opt.requiresArg) {
        this.requiresArg(key);
      }
    }
    return this;
  }
  options(key, opt) {
    return this.option(key, opt);
  }
  parse(args, shortCircuit, _parseFn) {
    argsert("[string|array] [function|boolean|object] [function]", [args, shortCircuit, _parseFn], arguments.length);
    this[kFreeze]();
    if (typeof args === "undefined") {
      args = __classPrivateFieldGet(this, _YargsInstance_processArgs, "f");
    }
    if (typeof shortCircuit === "object") {
      __classPrivateFieldSet(this, _YargsInstance_parseContext, shortCircuit, "f");
      shortCircuit = _parseFn;
    }
    if (typeof shortCircuit === "function") {
      __classPrivateFieldSet(this, _YargsInstance_parseFn, shortCircuit, "f");
      shortCircuit = false;
    }
    if (!shortCircuit)
      __classPrivateFieldSet(this, _YargsInstance_processArgs, args, "f");
    if (__classPrivateFieldGet(this, _YargsInstance_parseFn, "f"))
      __classPrivateFieldSet(this, _YargsInstance_exitProcess, false, "f");
    const parsed = this[kRunYargsParserAndExecuteCommands](args, !!shortCircuit);
    const tmpParsed = this.parsed;
    __classPrivateFieldGet(this, _YargsInstance_completion, "f").setParsed(this.parsed);
    if (isPromise(parsed)) {
      return parsed.then((argv) => {
        if (__classPrivateFieldGet(this, _YargsInstance_parseFn, "f"))
          __classPrivateFieldGet(this, _YargsInstance_parseFn, "f").call(this, __classPrivateFieldGet(this, _YargsInstance_exitError, "f"), argv, __classPrivateFieldGet(this, _YargsInstance_output, "f"));
        return argv;
      }).catch((err) => {
        if (__classPrivateFieldGet(this, _YargsInstance_parseFn, "f")) {
          __classPrivateFieldGet(this, _YargsInstance_parseFn, "f")(err, this.parsed.argv, __classPrivateFieldGet(this, _YargsInstance_output, "f"));
        }
        throw err;
      }).finally(() => {
        this[kUnfreeze]();
        this.parsed = tmpParsed;
      });
    } else {
      if (__classPrivateFieldGet(this, _YargsInstance_parseFn, "f"))
        __classPrivateFieldGet(this, _YargsInstance_parseFn, "f").call(this, __classPrivateFieldGet(this, _YargsInstance_exitError, "f"), parsed, __classPrivateFieldGet(this, _YargsInstance_output, "f"));
      this[kUnfreeze]();
      this.parsed = tmpParsed;
    }
    return parsed;
  }
  parseAsync(args, shortCircuit, _parseFn) {
    const maybePromise = this.parse(args, shortCircuit, _parseFn);
    return !isPromise(maybePromise) ? Promise.resolve(maybePromise) : maybePromise;
  }
  parseSync(args, shortCircuit, _parseFn) {
    const maybePromise = this.parse(args, shortCircuit, _parseFn);
    if (isPromise(maybePromise)) {
      throw new YError(".parseSync() must not be used with asynchronous builders, handlers, or middleware");
    }
    return maybePromise;
  }
  parserConfiguration(config) {
    argsert("<object>", [config], arguments.length);
    __classPrivateFieldSet(this, _YargsInstance_parserConfig, config, "f");
    return this;
  }
  pkgConf(key, rootPath) {
    argsert("<string> [string]", [key, rootPath], arguments.length);
    let conf = null;
    const obj = this[kPkgUp](rootPath || __classPrivateFieldGet(this, _YargsInstance_cwd, "f"));
    if (obj[key] && typeof obj[key] === "object") {
      conf = applyExtends(obj[key], rootPath || __classPrivateFieldGet(this, _YargsInstance_cwd, "f"), this[kGetParserConfiguration]()["deep-merge-config"] || false, __classPrivateFieldGet(this, _YargsInstance_shim, "f"));
      __classPrivateFieldGet(this, _YargsInstance_options, "f").configObjects = (__classPrivateFieldGet(this, _YargsInstance_options, "f").configObjects || []).concat(conf);
    }
    return this;
  }
  positional(key, opts) {
    argsert("<string> <object>", [key, opts], arguments.length);
    const supportedOpts = [
      "default",
      "defaultDescription",
      "implies",
      "normalize",
      "choices",
      "conflicts",
      "coerce",
      "type",
      "describe",
      "desc",
      "description",
      "alias"
    ];
    opts = objFilter(opts, (k, v) => {
      if (k === "type" && !["string", "number", "boolean"].includes(v))
        return false;
      return supportedOpts.includes(k);
    });
    const fullCommand = __classPrivateFieldGet(this, _YargsInstance_context, "f").fullCommands[__classPrivateFieldGet(this, _YargsInstance_context, "f").fullCommands.length - 1];
    const parseOptions = fullCommand ? __classPrivateFieldGet(this, _YargsInstance_command, "f").cmdToParseOptions(fullCommand) : {
      array: [],
      alias: {},
      default: {},
      demand: {}
    };
    objectKeys(parseOptions).forEach((pk) => {
      const parseOption = parseOptions[pk];
      if (Array.isArray(parseOption)) {
        if (parseOption.indexOf(key) !== -1)
          opts[pk] = true;
      } else {
        if (parseOption[key] && !(pk in opts))
          opts[pk] = parseOption[key];
      }
    });
    this.group(key, __classPrivateFieldGet(this, _YargsInstance_usage, "f").getPositionalGroupName());
    return this.option(key, opts);
  }
  recommendCommands(recommend = true) {
    argsert("[boolean]", [recommend], arguments.length);
    __classPrivateFieldSet(this, _YargsInstance_recommendCommands, recommend, "f");
    return this;
  }
  required(keys, max, msg) {
    return this.demand(keys, max, msg);
  }
  require(keys, max, msg) {
    return this.demand(keys, max, msg);
  }
  requiresArg(keys) {
    argsert("<array|string|object> [number]", [keys], arguments.length);
    if (typeof keys === "string" && __classPrivateFieldGet(this, _YargsInstance_options, "f").narg[keys]) {
      return this;
    } else {
      this[kPopulateParserHintSingleValueDictionary](this.requiresArg.bind(this), "narg", keys, NaN);
    }
    return this;
  }
  showCompletionScript($0, cmd) {
    argsert("[string] [string]", [$0, cmd], arguments.length);
    $0 = $0 || this.$0;
    __classPrivateFieldGet(this, _YargsInstance_logger, "f").log(__classPrivateFieldGet(this, _YargsInstance_completion, "f").generateCompletionScript($0, cmd || __classPrivateFieldGet(this, _YargsInstance_completionCommand, "f") || "completion"));
    return this;
  }
  showHelp(level) {
    argsert("[string|function]", [level], arguments.length);
    __classPrivateFieldSet(this, _YargsInstance_hasOutput, true, "f");
    if (!__classPrivateFieldGet(this, _YargsInstance_usage, "f").hasCachedHelpMessage()) {
      if (!this.parsed) {
        const parse = this[kRunYargsParserAndExecuteCommands](__classPrivateFieldGet(this, _YargsInstance_processArgs, "f"), undefined, undefined, 0, true);
        if (isPromise(parse)) {
          parse.then(() => {
            __classPrivateFieldGet(this, _YargsInstance_usage, "f").showHelp(level);
          });
          return this;
        }
      }
      const builderResponse = __classPrivateFieldGet(this, _YargsInstance_command, "f").runDefaultBuilderOn(this);
      if (isPromise(builderResponse)) {
        builderResponse.then(() => {
          __classPrivateFieldGet(this, _YargsInstance_usage, "f").showHelp(level);
        });
        return this;
      }
    }
    __classPrivateFieldGet(this, _YargsInstance_usage, "f").showHelp(level);
    return this;
  }
  scriptName(scriptName) {
    this.customScriptName = true;
    this.$0 = scriptName;
    return this;
  }
  showHelpOnFail(enabled, message) {
    argsert("[boolean|string] [string]", [enabled, message], arguments.length);
    __classPrivateFieldGet(this, _YargsInstance_usage, "f").showHelpOnFail(enabled, message);
    return this;
  }
  showVersion(level) {
    argsert("[string|function]", [level], arguments.length);
    __classPrivateFieldGet(this, _YargsInstance_usage, "f").showVersion(level);
    return this;
  }
  skipValidation(keys) {
    argsert("<array|string>", [keys], arguments.length);
    this[kPopulateParserHintArray]("skipValidation", keys);
    return this;
  }
  strict(enabled) {
    argsert("[boolean]", [enabled], arguments.length);
    __classPrivateFieldSet(this, _YargsInstance_strict, enabled !== false, "f");
    return this;
  }
  strictCommands(enabled) {
    argsert("[boolean]", [enabled], arguments.length);
    __classPrivateFieldSet(this, _YargsInstance_strictCommands, enabled !== false, "f");
    return this;
  }
  strictOptions(enabled) {
    argsert("[boolean]", [enabled], arguments.length);
    __classPrivateFieldSet(this, _YargsInstance_strictOptions, enabled !== false, "f");
    return this;
  }
  string(keys) {
    argsert("<array|string>", [keys], arguments.length);
    this[kPopulateParserHintArray]("string", keys);
    this[kTrackManuallySetKeys](keys);
    return this;
  }
  terminalWidth() {
    argsert([], 0);
    return __classPrivateFieldGet(this, _YargsInstance_shim, "f").process.stdColumns;
  }
  updateLocale(obj) {
    return this.updateStrings(obj);
  }
  updateStrings(obj) {
    argsert("<object>", [obj], arguments.length);
    __classPrivateFieldSet(this, _YargsInstance_detectLocale, false, "f");
    __classPrivateFieldGet(this, _YargsInstance_shim, "f").y18n.updateLocale(obj);
    return this;
  }
  usage(msg, description, builder, handler) {
    argsert("<string|null|undefined> [string|boolean] [function|object] [function]", [msg, description, builder, handler], arguments.length);
    if (description !== undefined) {
      assertNotStrictEqual(msg, null, __classPrivateFieldGet(this, _YargsInstance_shim, "f"));
      if ((msg || "").match(/^\$0( |$)/)) {
        return this.command(msg, description, builder, handler);
      } else {
        throw new YError(".usage() description must start with $0 if being used as alias for .command()");
      }
    } else {
      __classPrivateFieldGet(this, _YargsInstance_usage, "f").usage(msg);
      return this;
    }
  }
  usageConfiguration(config) {
    argsert("<object>", [config], arguments.length);
    __classPrivateFieldSet(this, _YargsInstance_usageConfig, config, "f");
    return this;
  }
  version(opt, msg, ver) {
    const defaultVersionOpt = "version";
    argsert("[boolean|string] [string] [string]", [opt, msg, ver], arguments.length);
    if (__classPrivateFieldGet(this, _YargsInstance_versionOpt, "f")) {
      this[kDeleteFromParserHintObject](__classPrivateFieldGet(this, _YargsInstance_versionOpt, "f"));
      __classPrivateFieldGet(this, _YargsInstance_usage, "f").version(undefined);
      __classPrivateFieldSet(this, _YargsInstance_versionOpt, null, "f");
    }
    if (arguments.length === 0) {
      ver = this[kGuessVersion]();
      opt = defaultVersionOpt;
    } else if (arguments.length === 1) {
      if (opt === false) {
        return this;
      }
      ver = opt;
      opt = defaultVersionOpt;
    } else if (arguments.length === 2) {
      ver = msg;
      msg = undefined;
    }
    __classPrivateFieldSet(this, _YargsInstance_versionOpt, typeof opt === "string" ? opt : defaultVersionOpt, "f");
    msg = msg || __classPrivateFieldGet(this, _YargsInstance_usage, "f").deferY18nLookup("Show version number");
    __classPrivateFieldGet(this, _YargsInstance_usage, "f").version(ver || undefined);
    this.boolean(__classPrivateFieldGet(this, _YargsInstance_versionOpt, "f"));
    this.describe(__classPrivateFieldGet(this, _YargsInstance_versionOpt, "f"), msg);
    return this;
  }
  wrap(cols) {
    argsert("<number|null|undefined>", [cols], arguments.length);
    __classPrivateFieldGet(this, _YargsInstance_usage, "f").wrap(cols);
    return this;
  }
  [(_YargsInstance_command = new WeakMap, _YargsInstance_cwd = new WeakMap, _YargsInstance_context = new WeakMap, _YargsInstance_completion = new WeakMap, _YargsInstance_completionCommand = new WeakMap, _YargsInstance_defaultShowHiddenOpt = new WeakMap, _YargsInstance_exitError = new WeakMap, _YargsInstance_detectLocale = new WeakMap, _YargsInstance_emittedWarnings = new WeakMap, _YargsInstance_exitProcess = new WeakMap, _YargsInstance_frozens = new WeakMap, _YargsInstance_globalMiddleware = new WeakMap, _YargsInstance_groups = new WeakMap, _YargsInstance_hasOutput = new WeakMap, _YargsInstance_helpOpt = new WeakMap, _YargsInstance_isGlobalContext = new WeakMap, _YargsInstance_logger = new WeakMap, _YargsInstance_output = new WeakMap, _YargsInstance_options = new WeakMap, _YargsInstance_parentRequire = new WeakMap, _YargsInstance_parserConfig = new WeakMap, _YargsInstance_parseFn = new WeakMap, _YargsInstance_parseContext = new WeakMap, _YargsInstance_pkgs = new WeakMap, _YargsInstance_preservedGroups = new WeakMap, _YargsInstance_processArgs = new WeakMap, _YargsInstance_recommendCommands = new WeakMap, _YargsInstance_shim = new WeakMap, _YargsInstance_strict = new WeakMap, _YargsInstance_strictCommands = new WeakMap, _YargsInstance_strictOptions = new WeakMap, _YargsInstance_usage = new WeakMap, _YargsInstance_usageConfig = new WeakMap, _YargsInstance_versionOpt = new WeakMap, _YargsInstance_validation = new WeakMap, kCopyDoubleDash)](argv) {
    if (!argv._ || !argv["--"])
      return argv;
    argv._.push.apply(argv._, argv["--"]);
    try {
      delete argv["--"];
    } catch (_err) {}
    return argv;
  }
  [kCreateLogger]() {
    return {
      log: (...args) => {
        if (!this[kHasParseCallback]())
          console.log(...args);
        __classPrivateFieldSet(this, _YargsInstance_hasOutput, true, "f");
        if (__classPrivateFieldGet(this, _YargsInstance_output, "f").length)
          __classPrivateFieldSet(this, _YargsInstance_output, __classPrivateFieldGet(this, _YargsInstance_output, "f") + `
`, "f");
        __classPrivateFieldSet(this, _YargsInstance_output, __classPrivateFieldGet(this, _YargsInstance_output, "f") + args.join(" "), "f");
      },
      error: (...args) => {
        if (!this[kHasParseCallback]())
          console.error(...args);
        __classPrivateFieldSet(this, _YargsInstance_hasOutput, true, "f");
        if (__classPrivateFieldGet(this, _YargsInstance_output, "f").length)
          __classPrivateFieldSet(this, _YargsInstance_output, __classPrivateFieldGet(this, _YargsInstance_output, "f") + `
`, "f");
        __classPrivateFieldSet(this, _YargsInstance_output, __classPrivateFieldGet(this, _YargsInstance_output, "f") + args.join(" "), "f");
      }
    };
  }
  [kDeleteFromParserHintObject](optionKey) {
    objectKeys(__classPrivateFieldGet(this, _YargsInstance_options, "f")).forEach((hintKey) => {
      if (((key) => key === "configObjects")(hintKey))
        return;
      const hint = __classPrivateFieldGet(this, _YargsInstance_options, "f")[hintKey];
      if (Array.isArray(hint)) {
        if (hint.includes(optionKey))
          hint.splice(hint.indexOf(optionKey), 1);
      } else if (typeof hint === "object") {
        delete hint[optionKey];
      }
    });
    delete __classPrivateFieldGet(this, _YargsInstance_usage, "f").getDescriptions()[optionKey];
  }
  [kEmitWarning](warning, type, deduplicationId) {
    if (!__classPrivateFieldGet(this, _YargsInstance_emittedWarnings, "f")[deduplicationId]) {
      __classPrivateFieldGet(this, _YargsInstance_shim, "f").process.emitWarning(warning, type);
      __classPrivateFieldGet(this, _YargsInstance_emittedWarnings, "f")[deduplicationId] = true;
    }
  }
  [kFreeze]() {
    __classPrivateFieldGet(this, _YargsInstance_frozens, "f").push({
      options: __classPrivateFieldGet(this, _YargsInstance_options, "f"),
      configObjects: __classPrivateFieldGet(this, _YargsInstance_options, "f").configObjects.slice(0),
      exitProcess: __classPrivateFieldGet(this, _YargsInstance_exitProcess, "f"),
      groups: __classPrivateFieldGet(this, _YargsInstance_groups, "f"),
      strict: __classPrivateFieldGet(this, _YargsInstance_strict, "f"),
      strictCommands: __classPrivateFieldGet(this, _YargsInstance_strictCommands, "f"),
      strictOptions: __classPrivateFieldGet(this, _YargsInstance_strictOptions, "f"),
      completionCommand: __classPrivateFieldGet(this, _YargsInstance_completionCommand, "f"),
      output: __classPrivateFieldGet(this, _YargsInstance_output, "f"),
      exitError: __classPrivateFieldGet(this, _YargsInstance_exitError, "f"),
      hasOutput: __classPrivateFieldGet(this, _YargsInstance_hasOutput, "f"),
      parsed: this.parsed,
      parseFn: __classPrivateFieldGet(this, _YargsInstance_parseFn, "f"),
      parseContext: __classPrivateFieldGet(this, _YargsInstance_parseContext, "f")
    });
    __classPrivateFieldGet(this, _YargsInstance_usage, "f").freeze();
    __classPrivateFieldGet(this, _YargsInstance_validation, "f").freeze();
    __classPrivateFieldGet(this, _YargsInstance_command, "f").freeze();
    __classPrivateFieldGet(this, _YargsInstance_globalMiddleware, "f").freeze();
  }
  [kGetDollarZero]() {
    let $0 = "";
    let default$0;
    if (/\b(node|iojs|electron)(\.exe)?$/.test(__classPrivateFieldGet(this, _YargsInstance_shim, "f").process.argv()[0])) {
      default$0 = __classPrivateFieldGet(this, _YargsInstance_shim, "f").process.argv().slice(1, 2);
    } else {
      default$0 = __classPrivateFieldGet(this, _YargsInstance_shim, "f").process.argv().slice(0, 1);
    }
    $0 = default$0.map((x) => {
      const b = this[kRebase](__classPrivateFieldGet(this, _YargsInstance_cwd, "f"), x);
      return x.match(/^(\/|([a-zA-Z]:)?\\)/) && b.length < x.length ? b : x;
    }).join(" ").trim();
    if (__classPrivateFieldGet(this, _YargsInstance_shim, "f").getEnv("_") && __classPrivateFieldGet(this, _YargsInstance_shim, "f").getProcessArgvBin() === __classPrivateFieldGet(this, _YargsInstance_shim, "f").getEnv("_")) {
      $0 = __classPrivateFieldGet(this, _YargsInstance_shim, "f").getEnv("_").replace(`${__classPrivateFieldGet(this, _YargsInstance_shim, "f").path.dirname(__classPrivateFieldGet(this, _YargsInstance_shim, "f").process.execPath())}/`, "");
    }
    return $0;
  }
  [kGetParserConfiguration]() {
    return __classPrivateFieldGet(this, _YargsInstance_parserConfig, "f");
  }
  [kGetUsageConfiguration]() {
    return __classPrivateFieldGet(this, _YargsInstance_usageConfig, "f");
  }
  [kGuessLocale]() {
    if (!__classPrivateFieldGet(this, _YargsInstance_detectLocale, "f"))
      return;
    const locale = __classPrivateFieldGet(this, _YargsInstance_shim, "f").getEnv("LC_ALL") || __classPrivateFieldGet(this, _YargsInstance_shim, "f").getEnv("LC_MESSAGES") || __classPrivateFieldGet(this, _YargsInstance_shim, "f").getEnv("LANG") || __classPrivateFieldGet(this, _YargsInstance_shim, "f").getEnv("LANGUAGE") || "en_US";
    this.locale(locale.replace(/[.:].*/, ""));
  }
  [kGuessVersion]() {
    const obj = this[kPkgUp]();
    return obj.version || "unknown";
  }
  [kParsePositionalNumbers](argv) {
    const args = argv["--"] ? argv["--"] : argv._;
    for (let i = 0, arg;(arg = args[i]) !== undefined; i++) {
      if (__classPrivateFieldGet(this, _YargsInstance_shim, "f").Parser.looksLikeNumber(arg) && Number.isSafeInteger(Math.floor(parseFloat(`${arg}`)))) {
        args[i] = Number(arg);
      }
    }
    return argv;
  }
  [kPkgUp](rootPath) {
    const npath = rootPath || "*";
    if (__classPrivateFieldGet(this, _YargsInstance_pkgs, "f")[npath])
      return __classPrivateFieldGet(this, _YargsInstance_pkgs, "f")[npath];
    let obj = {};
    try {
      let startDir = rootPath || __classPrivateFieldGet(this, _YargsInstance_shim, "f").mainFilename;
      if (__classPrivateFieldGet(this, _YargsInstance_shim, "f").path.extname(startDir)) {
        startDir = __classPrivateFieldGet(this, _YargsInstance_shim, "f").path.dirname(startDir);
      }
      const pkgJsonPath = __classPrivateFieldGet(this, _YargsInstance_shim, "f").findUp(startDir, (dir, names) => {
        if (names.includes("package.json")) {
          return "package.json";
        } else {
          return;
        }
      });
      assertNotStrictEqual(pkgJsonPath, undefined, __classPrivateFieldGet(this, _YargsInstance_shim, "f"));
      obj = JSON.parse(__classPrivateFieldGet(this, _YargsInstance_shim, "f").readFileSync(pkgJsonPath, "utf8"));
    } catch (_noop) {}
    __classPrivateFieldGet(this, _YargsInstance_pkgs, "f")[npath] = obj || {};
    return __classPrivateFieldGet(this, _YargsInstance_pkgs, "f")[npath];
  }
  [kPopulateParserHintArray](type, keys) {
    keys = [].concat(keys);
    keys.forEach((key) => {
      key = this[kSanitizeKey](key);
      __classPrivateFieldGet(this, _YargsInstance_options, "f")[type].push(key);
    });
  }
  [kPopulateParserHintSingleValueDictionary](builder, type, key, value) {
    this[kPopulateParserHintDictionary](builder, type, key, value, (type2, key2, value2) => {
      __classPrivateFieldGet(this, _YargsInstance_options, "f")[type2][key2] = value2;
    });
  }
  [kPopulateParserHintArrayDictionary](builder, type, key, value) {
    this[kPopulateParserHintDictionary](builder, type, key, value, (type2, key2, value2) => {
      __classPrivateFieldGet(this, _YargsInstance_options, "f")[type2][key2] = (__classPrivateFieldGet(this, _YargsInstance_options, "f")[type2][key2] || []).concat(value2);
    });
  }
  [kPopulateParserHintDictionary](builder, type, key, value, singleKeyHandler) {
    if (Array.isArray(key)) {
      key.forEach((k) => {
        builder(k, value);
      });
    } else if (((key2) => typeof key2 === "object")(key)) {
      for (const k of objectKeys(key)) {
        builder(k, key[k]);
      }
    } else {
      singleKeyHandler(type, this[kSanitizeKey](key), value);
    }
  }
  [kSanitizeKey](key) {
    if (key === "__proto__")
      return "___proto___";
    return key;
  }
  [kSetKey](key, set) {
    this[kPopulateParserHintSingleValueDictionary](this[kSetKey].bind(this), "key", key, set);
    return this;
  }
  [kUnfreeze]() {
    var _a2, _b2, _c2, _d, _e, _f, _g, _h, _j, _k, _l, _m;
    const frozen = __classPrivateFieldGet(this, _YargsInstance_frozens, "f").pop();
    assertNotStrictEqual(frozen, undefined, __classPrivateFieldGet(this, _YargsInstance_shim, "f"));
    let configObjects;
    _a2 = this, _b2 = this, _c2 = this, _d = this, _e = this, _f = this, _g = this, _h = this, _j = this, _k = this, _l = this, _m = this, {
      options: { set value(_o) {
        __classPrivateFieldSet(_a2, _YargsInstance_options, _o, "f");
      } }.value,
      configObjects,
      exitProcess: { set value(_o) {
        __classPrivateFieldSet(_b2, _YargsInstance_exitProcess, _o, "f");
      } }.value,
      groups: { set value(_o) {
        __classPrivateFieldSet(_c2, _YargsInstance_groups, _o, "f");
      } }.value,
      output: { set value(_o) {
        __classPrivateFieldSet(_d, _YargsInstance_output, _o, "f");
      } }.value,
      exitError: { set value(_o) {
        __classPrivateFieldSet(_e, _YargsInstance_exitError, _o, "f");
      } }.value,
      hasOutput: { set value(_o) {
        __classPrivateFieldSet(_f, _YargsInstance_hasOutput, _o, "f");
      } }.value,
      parsed: this.parsed,
      strict: { set value(_o) {
        __classPrivateFieldSet(_g, _YargsInstance_strict, _o, "f");
      } }.value,
      strictCommands: { set value(_o) {
        __classPrivateFieldSet(_h, _YargsInstance_strictCommands, _o, "f");
      } }.value,
      strictOptions: { set value(_o) {
        __classPrivateFieldSet(_j, _YargsInstance_strictOptions, _o, "f");
      } }.value,
      completionCommand: { set value(_o) {
        __classPrivateFieldSet(_k, _YargsInstance_completionCommand, _o, "f");
      } }.value,
      parseFn: { set value(_o) {
        __classPrivateFieldSet(_l, _YargsInstance_parseFn, _o, "f");
      } }.value,
      parseContext: { set value(_o) {
        __classPrivateFieldSet(_m, _YargsInstance_parseContext, _o, "f");
      } }.value
    } = frozen;
    __classPrivateFieldGet(this, _YargsInstance_options, "f").configObjects = configObjects;
    __classPrivateFieldGet(this, _YargsInstance_usage, "f").unfreeze();
    __classPrivateFieldGet(this, _YargsInstance_validation, "f").unfreeze();
    __classPrivateFieldGet(this, _YargsInstance_command, "f").unfreeze();
    __classPrivateFieldGet(this, _YargsInstance_globalMiddleware, "f").unfreeze();
  }
  [kValidateAsync](validation2, argv) {
    return maybeAsyncResult(argv, (result) => {
      validation2(result);
      return result;
    });
  }
  getInternalMethods() {
    return {
      getCommandInstance: this[kGetCommandInstance].bind(this),
      getContext: this[kGetContext].bind(this),
      getHasOutput: this[kGetHasOutput].bind(this),
      getLoggerInstance: this[kGetLoggerInstance].bind(this),
      getParseContext: this[kGetParseContext].bind(this),
      getParserConfiguration: this[kGetParserConfiguration].bind(this),
      getUsageConfiguration: this[kGetUsageConfiguration].bind(this),
      getUsageInstance: this[kGetUsageInstance].bind(this),
      getValidationInstance: this[kGetValidationInstance].bind(this),
      hasParseCallback: this[kHasParseCallback].bind(this),
      isGlobalContext: this[kIsGlobalContext].bind(this),
      postProcess: this[kPostProcess].bind(this),
      reset: this[kReset].bind(this),
      runValidation: this[kRunValidation].bind(this),
      runYargsParserAndExecuteCommands: this[kRunYargsParserAndExecuteCommands].bind(this),
      setHasOutput: this[kSetHasOutput].bind(this)
    };
  }
  [kGetCommandInstance]() {
    return __classPrivateFieldGet(this, _YargsInstance_command, "f");
  }
  [kGetContext]() {
    return __classPrivateFieldGet(this, _YargsInstance_context, "f");
  }
  [kGetHasOutput]() {
    return __classPrivateFieldGet(this, _YargsInstance_hasOutput, "f");
  }
  [kGetLoggerInstance]() {
    return __classPrivateFieldGet(this, _YargsInstance_logger, "f");
  }
  [kGetParseContext]() {
    return __classPrivateFieldGet(this, _YargsInstance_parseContext, "f") || {};
  }
  [kGetUsageInstance]() {
    return __classPrivateFieldGet(this, _YargsInstance_usage, "f");
  }
  [kGetValidationInstance]() {
    return __classPrivateFieldGet(this, _YargsInstance_validation, "f");
  }
  [kHasParseCallback]() {
    return !!__classPrivateFieldGet(this, _YargsInstance_parseFn, "f");
  }
  [kIsGlobalContext]() {
    return __classPrivateFieldGet(this, _YargsInstance_isGlobalContext, "f");
  }
  [kPostProcess](argv, populateDoubleDash, calledFromCommand, runGlobalMiddleware) {
    if (calledFromCommand)
      return argv;
    if (isPromise(argv))
      return argv;
    if (!populateDoubleDash) {
      argv = this[kCopyDoubleDash](argv);
    }
    const parsePositionalNumbers = this[kGetParserConfiguration]()["parse-positional-numbers"] || this[kGetParserConfiguration]()["parse-positional-numbers"] === undefined;
    if (parsePositionalNumbers) {
      argv = this[kParsePositionalNumbers](argv);
    }
    if (runGlobalMiddleware) {
      argv = applyMiddleware(argv, this, __classPrivateFieldGet(this, _YargsInstance_globalMiddleware, "f").getMiddleware(), false);
    }
    return argv;
  }
  [kReset](aliases = {}) {
    __classPrivateFieldSet(this, _YargsInstance_options, __classPrivateFieldGet(this, _YargsInstance_options, "f") || {}, "f");
    const tmpOptions = {};
    tmpOptions.local = __classPrivateFieldGet(this, _YargsInstance_options, "f").local || [];
    tmpOptions.configObjects = __classPrivateFieldGet(this, _YargsInstance_options, "f").configObjects || [];
    const localLookup = {};
    tmpOptions.local.forEach((l) => {
      localLookup[l] = true;
      (aliases[l] || []).forEach((a) => {
        localLookup[a] = true;
      });
    });
    Object.assign(__classPrivateFieldGet(this, _YargsInstance_preservedGroups, "f"), Object.keys(__classPrivateFieldGet(this, _YargsInstance_groups, "f")).reduce((acc, groupName) => {
      const keys = __classPrivateFieldGet(this, _YargsInstance_groups, "f")[groupName].filter((key) => !(key in localLookup));
      if (keys.length > 0) {
        acc[groupName] = keys;
      }
      return acc;
    }, {}));
    __classPrivateFieldSet(this, _YargsInstance_groups, {}, "f");
    const arrayOptions = [
      "array",
      "boolean",
      "string",
      "skipValidation",
      "count",
      "normalize",
      "number",
      "hiddenOptions"
    ];
    const objectOptions = [
      "narg",
      "key",
      "alias",
      "default",
      "defaultDescription",
      "config",
      "choices",
      "demandedOptions",
      "demandedCommands",
      "deprecatedOptions"
    ];
    arrayOptions.forEach((k) => {
      tmpOptions[k] = (__classPrivateFieldGet(this, _YargsInstance_options, "f")[k] || []).filter((k2) => !localLookup[k2]);
    });
    objectOptions.forEach((k) => {
      tmpOptions[k] = objFilter(__classPrivateFieldGet(this, _YargsInstance_options, "f")[k], (k2) => !localLookup[k2]);
    });
    tmpOptions.envPrefix = __classPrivateFieldGet(this, _YargsInstance_options, "f").envPrefix;
    __classPrivateFieldSet(this, _YargsInstance_options, tmpOptions, "f");
    __classPrivateFieldSet(this, _YargsInstance_usage, __classPrivateFieldGet(this, _YargsInstance_usage, "f") ? __classPrivateFieldGet(this, _YargsInstance_usage, "f").reset(localLookup) : usage(this, __classPrivateFieldGet(this, _YargsInstance_shim, "f")), "f");
    __classPrivateFieldSet(this, _YargsInstance_validation, __classPrivateFieldGet(this, _YargsInstance_validation, "f") ? __classPrivateFieldGet(this, _YargsInstance_validation, "f").reset(localLookup) : validation(this, __classPrivateFieldGet(this, _YargsInstance_usage, "f"), __classPrivateFieldGet(this, _YargsInstance_shim, "f")), "f");
    __classPrivateFieldSet(this, _YargsInstance_command, __classPrivateFieldGet(this, _YargsInstance_command, "f") ? __classPrivateFieldGet(this, _YargsInstance_command, "f").reset() : command(__classPrivateFieldGet(this, _YargsInstance_usage, "f"), __classPrivateFieldGet(this, _YargsInstance_validation, "f"), __classPrivateFieldGet(this, _YargsInstance_globalMiddleware, "f"), __classPrivateFieldGet(this, _YargsInstance_shim, "f")), "f");
    if (!__classPrivateFieldGet(this, _YargsInstance_completion, "f"))
      __classPrivateFieldSet(this, _YargsInstance_completion, completion(this, __classPrivateFieldGet(this, _YargsInstance_usage, "f"), __classPrivateFieldGet(this, _YargsInstance_command, "f"), __classPrivateFieldGet(this, _YargsInstance_shim, "f")), "f");
    __classPrivateFieldGet(this, _YargsInstance_globalMiddleware, "f").reset();
    __classPrivateFieldSet(this, _YargsInstance_completionCommand, null, "f");
    __classPrivateFieldSet(this, _YargsInstance_output, "", "f");
    __classPrivateFieldSet(this, _YargsInstance_exitError, null, "f");
    __classPrivateFieldSet(this, _YargsInstance_hasOutput, false, "f");
    this.parsed = false;
    return this;
  }
  [kRebase](base, dir) {
    return __classPrivateFieldGet(this, _YargsInstance_shim, "f").path.relative(base, dir);
  }
  [kRunYargsParserAndExecuteCommands](args, shortCircuit, calledFromCommand, commandIndex = 0, helpOnly = false) {
    var _a2, _b2, _c2, _d;
    let skipValidation = !!calledFromCommand || helpOnly;
    args = args || __classPrivateFieldGet(this, _YargsInstance_processArgs, "f");
    __classPrivateFieldGet(this, _YargsInstance_options, "f").__ = __classPrivateFieldGet(this, _YargsInstance_shim, "f").y18n.__;
    __classPrivateFieldGet(this, _YargsInstance_options, "f").configuration = this[kGetParserConfiguration]();
    const populateDoubleDash = !!__classPrivateFieldGet(this, _YargsInstance_options, "f").configuration["populate--"];
    const config = Object.assign({}, __classPrivateFieldGet(this, _YargsInstance_options, "f").configuration, {
      "populate--": true
    });
    const parsed = __classPrivateFieldGet(this, _YargsInstance_shim, "f").Parser.detailed(args, Object.assign({}, __classPrivateFieldGet(this, _YargsInstance_options, "f"), {
      configuration: { "parse-positional-numbers": false, ...config }
    }));
    const argv = Object.assign(parsed.argv, __classPrivateFieldGet(this, _YargsInstance_parseContext, "f"));
    let argvPromise = undefined;
    const aliases = parsed.aliases;
    let helpOptSet = false;
    let versionOptSet = false;
    Object.keys(argv).forEach((key) => {
      if (key === __classPrivateFieldGet(this, _YargsInstance_helpOpt, "f") && argv[key]) {
        helpOptSet = true;
      } else if (key === __classPrivateFieldGet(this, _YargsInstance_versionOpt, "f") && argv[key]) {
        versionOptSet = true;
      }
    });
    argv.$0 = this.$0;
    this.parsed = parsed;
    if (commandIndex === 0) {
      __classPrivateFieldGet(this, _YargsInstance_usage, "f").clearCachedHelpMessage();
    }
    try {
      this[kGuessLocale]();
      if (shortCircuit) {
        return this[kPostProcess](argv, populateDoubleDash, !!calledFromCommand, false);
      }
      if (__classPrivateFieldGet(this, _YargsInstance_helpOpt, "f")) {
        const helpCmds = [__classPrivateFieldGet(this, _YargsInstance_helpOpt, "f")].concat(aliases[__classPrivateFieldGet(this, _YargsInstance_helpOpt, "f")] || []).filter((k) => k.length > 1);
        if (helpCmds.includes("" + argv._[argv._.length - 1])) {
          argv._.pop();
          helpOptSet = true;
        }
      }
      __classPrivateFieldSet(this, _YargsInstance_isGlobalContext, false, "f");
      const handlerKeys = __classPrivateFieldGet(this, _YargsInstance_command, "f").getCommands();
      const requestCompletions = ((_a2 = __classPrivateFieldGet(this, _YargsInstance_completion, "f")) === null || _a2 === undefined ? undefined : _a2.completionKey) ? [
        (_b2 = __classPrivateFieldGet(this, _YargsInstance_completion, "f")) === null || _b2 === undefined ? undefined : _b2.completionKey,
        ...(_d = this.getAliases()[(_c2 = __classPrivateFieldGet(this, _YargsInstance_completion, "f")) === null || _c2 === undefined ? undefined : _c2.completionKey]) !== null && _d !== undefined ? _d : []
      ].some((key) => Object.prototype.hasOwnProperty.call(argv, key)) : false;
      const skipRecommendation = helpOptSet || requestCompletions || helpOnly;
      if (argv._.length) {
        if (handlerKeys.length) {
          let firstUnknownCommand;
          for (let i = commandIndex || 0, cmd;argv._[i] !== undefined; i++) {
            cmd = String(argv._[i]);
            if (handlerKeys.includes(cmd) && cmd !== __classPrivateFieldGet(this, _YargsInstance_completionCommand, "f")) {
              const innerArgv = __classPrivateFieldGet(this, _YargsInstance_command, "f").runCommand(cmd, this, parsed, i + 1, helpOnly, helpOptSet || versionOptSet || helpOnly);
              return this[kPostProcess](innerArgv, populateDoubleDash, !!calledFromCommand, false);
            } else if (!firstUnknownCommand && cmd !== __classPrivateFieldGet(this, _YargsInstance_completionCommand, "f")) {
              firstUnknownCommand = cmd;
              break;
            }
          }
          if (!__classPrivateFieldGet(this, _YargsInstance_command, "f").hasDefaultCommand() && __classPrivateFieldGet(this, _YargsInstance_recommendCommands, "f") && firstUnknownCommand && !skipRecommendation) {
            __classPrivateFieldGet(this, _YargsInstance_validation, "f").recommendCommands(firstUnknownCommand, handlerKeys);
          }
        }
        if (__classPrivateFieldGet(this, _YargsInstance_completionCommand, "f") && argv._.includes(__classPrivateFieldGet(this, _YargsInstance_completionCommand, "f")) && !requestCompletions) {
          if (__classPrivateFieldGet(this, _YargsInstance_exitProcess, "f"))
            setBlocking(true);
          this.showCompletionScript();
          this.exit(0);
        }
      }
      if (__classPrivateFieldGet(this, _YargsInstance_command, "f").hasDefaultCommand() && !skipRecommendation) {
        const innerArgv = __classPrivateFieldGet(this, _YargsInstance_command, "f").runCommand(null, this, parsed, 0, helpOnly, helpOptSet || versionOptSet || helpOnly);
        return this[kPostProcess](innerArgv, populateDoubleDash, !!calledFromCommand, false);
      }
      if (requestCompletions) {
        if (__classPrivateFieldGet(this, _YargsInstance_exitProcess, "f"))
          setBlocking(true);
        args = [].concat(args);
        const completionArgs = args.slice(args.indexOf(`--${__classPrivateFieldGet(this, _YargsInstance_completion, "f").completionKey}`) + 1);
        __classPrivateFieldGet(this, _YargsInstance_completion, "f").getCompletion(completionArgs, (err, completions) => {
          if (err)
            throw new YError(err.message);
          (completions || []).forEach((completion2) => {
            __classPrivateFieldGet(this, _YargsInstance_logger, "f").log(completion2);
          });
          this.exit(0);
        });
        return this[kPostProcess](argv, !populateDoubleDash, !!calledFromCommand, false);
      }
      if (!__classPrivateFieldGet(this, _YargsInstance_hasOutput, "f")) {
        if (helpOptSet) {
          if (__classPrivateFieldGet(this, _YargsInstance_exitProcess, "f"))
            setBlocking(true);
          skipValidation = true;
          this.showHelp((message) => {
            __classPrivateFieldGet(this, _YargsInstance_logger, "f").log(message);
            this.exit(0);
          });
        } else if (versionOptSet) {
          if (__classPrivateFieldGet(this, _YargsInstance_exitProcess, "f"))
            setBlocking(true);
          skipValidation = true;
          __classPrivateFieldGet(this, _YargsInstance_usage, "f").showVersion("log");
          this.exit(0);
        }
      }
      if (!skipValidation && __classPrivateFieldGet(this, _YargsInstance_options, "f").skipValidation.length > 0) {
        skipValidation = Object.keys(argv).some((key) => __classPrivateFieldGet(this, _YargsInstance_options, "f").skipValidation.indexOf(key) >= 0 && argv[key] === true);
      }
      if (!skipValidation) {
        if (parsed.error)
          throw new YError(parsed.error.message);
        if (!requestCompletions) {
          const validation2 = this[kRunValidation](aliases, {}, parsed.error);
          if (!calledFromCommand) {
            argvPromise = applyMiddleware(argv, this, __classPrivateFieldGet(this, _YargsInstance_globalMiddleware, "f").getMiddleware(), true);
          }
          argvPromise = this[kValidateAsync](validation2, argvPromise !== null && argvPromise !== undefined ? argvPromise : argv);
          if (isPromise(argvPromise) && !calledFromCommand) {
            argvPromise = argvPromise.then(() => {
              return applyMiddleware(argv, this, __classPrivateFieldGet(this, _YargsInstance_globalMiddleware, "f").getMiddleware(), false);
            });
          }
        }
      }
    } catch (err) {
      if (err instanceof YError)
        __classPrivateFieldGet(this, _YargsInstance_usage, "f").fail(err.message, err);
      else
        throw err;
    }
    return this[kPostProcess](argvPromise !== null && argvPromise !== undefined ? argvPromise : argv, populateDoubleDash, !!calledFromCommand, true);
  }
  [kRunValidation](aliases, positionalMap, parseErrors, isDefaultCommand) {
    const demandedOptions = { ...this.getDemandedOptions() };
    return (argv) => {
      if (parseErrors)
        throw new YError(parseErrors.message);
      __classPrivateFieldGet(this, _YargsInstance_validation, "f").nonOptionCount(argv);
      __classPrivateFieldGet(this, _YargsInstance_validation, "f").requiredArguments(argv, demandedOptions);
      let failedStrictCommands = false;
      if (__classPrivateFieldGet(this, _YargsInstance_strictCommands, "f")) {
        failedStrictCommands = __classPrivateFieldGet(this, _YargsInstance_validation, "f").unknownCommands(argv);
      }
      if (__classPrivateFieldGet(this, _YargsInstance_strict, "f") && !failedStrictCommands) {
        __classPrivateFieldGet(this, _YargsInstance_validation, "f").unknownArguments(argv, aliases, positionalMap, !!isDefaultCommand);
      } else if (__classPrivateFieldGet(this, _YargsInstance_strictOptions, "f")) {
        __classPrivateFieldGet(this, _YargsInstance_validation, "f").unknownArguments(argv, aliases, {}, false, false);
      }
      __classPrivateFieldGet(this, _YargsInstance_validation, "f").limitedChoices(argv);
      __classPrivateFieldGet(this, _YargsInstance_validation, "f").implications(argv);
      __classPrivateFieldGet(this, _YargsInstance_validation, "f").conflicting(argv);
    };
  }
  [kSetHasOutput]() {
    __classPrivateFieldSet(this, _YargsInstance_hasOutput, true, "f");
  }
  [kTrackManuallySetKeys](keys) {
    if (typeof keys === "string") {
      __classPrivateFieldGet(this, _YargsInstance_options, "f").key[keys] = true;
    } else {
      for (const k of keys) {
        __classPrivateFieldGet(this, _YargsInstance_options, "f").key[k] = true;
      }
    }
  }
}
function isYargsInstance(y) {
  return !!y && typeof y.getInternalMethods === "function";
}

// node_modules/yargs/index.mjs
var Yargs = YargsFactory(esm_default);
var yargs_default = Yargs;

// src/dev.ts
import path6 from "path";
import process6 from "process";
import { existsSync as existsSync3 } from "fs";
import { createInterface } from "readline";
import { mkdir as mkdir5 } from "fs/promises";

// src/common.ts
import { execSync } from "child_process";
import path from "path";
import { existsSync, statSync as statSync3 } from "fs";
import { mkdir } from "fs/promises";
import process2 from "process";
var sleep = (ms) => Bun.sleep(ms);
var _nativeDir = null;
var resolveNativeDir = () => {
  if (_nativeDir)
    return _nativeDir;
  const cliSrcDir = import.meta.dir;
  const cliRoot = path.dirname(cliSrcDir);
  const repoRoot = path.resolve(cliRoot, "../..");
  if (existsSync(path.join(repoRoot, "src")) && existsSync(path.join(repoRoot, "vendor"))) {
    _nativeDir = repoRoot;
    return _nativeDir;
  }
  const bundled = path.join(cliRoot, "native");
  if (existsSync(path.join(bundled, "src")) && existsSync(path.join(bundled, "vendor"))) {
    _nativeDir = bundled;
    return _nativeDir;
  }
  throw new Error(`[zapp] Cannot find native framework code. Expected either:
` + `  - ${repoRoot}/src  (monorepo development)
` + `  - ${bundled}/src  (bundled with CLI)
`);
};
var nativeIncludeArgs = () => {
  const nd = resolveNativeDir();
  const args = [];
  args.push("-I", path.join(nd, "src"));
  args.push("-I", path.join(nd, "vendor", "quickjs-ng"));
  if (process2.platform === "win32") {
    args.push("-I", path.join(nd, "vendor", "webview2", "include"));
  }
  return args;
};
var ensureQjsLib = async (root, mode = "release") => {
  const nd = resolveNativeDir();
  const qjsVendor = path.join(nd, "vendor", "quickjs-ng");
  const qjsBuildDir = path.join(root, ".zapp", "qjs", mode);
  await mkdir(qjsBuildDir, { recursive: true });
  const libPath = path.join(qjsBuildDir, "libqjs.a");
  const sourceFiles = ["quickjs.c", "quickjs-libc.c", "dtoa.c", "libregexp.c", "libunicode.c"];
  const libExists = existsSync(libPath);
  let needsRebuild = !libExists;
  if (libExists) {
    const libMtime = statSync3(libPath).mtimeMs;
    for (const src of sourceFiles) {
      const srcPath = path.join(qjsVendor, src);
      if (existsSync(srcPath) && statSync3(srcPath).mtimeMs > libMtime) {
        needsRebuild = true;
        break;
      }
    }
  }
  if (!needsRebuild)
    return libPath;
  process2.stdout.write(`[zapp] compiling QuickJS (${mode})...
`);
  const cc = process2.platform === "win32" ? "gcc" : "cc";
  const cflags = [];
  if (mode === "release") {
    cflags.push("-Oz", "-flto", "-c", `-I${qjsVendor}`);
  } else {
    cflags.push("-O2", "-c", `-I${qjsVendor}`);
  }
  if (process2.platform === "win32") {
    cflags.push("-DUNICODE", "-D_UNICODE");
  }
  const objectFiles = [];
  for (const src of sourceFiles) {
    const srcPath = path.join(qjsVendor, src);
    const objPath = path.join(qjsBuildDir, src.replace(".c", ".o"));
    objectFiles.push(objPath);
    await runCmd(cc, [...cflags, srcPath, "-o", objPath]);
  }
  const ar = "ar";
  await runCmd(ar, ["rcs", libPath, ...objectFiles]);
  return libPath;
};
var cachedExec = null;
var preferredJsTool = () => {
  if (cachedExec)
    return cachedExec;
  if (Bun.which("bun")) {
    cachedExec = "bun";
    return cachedExec;
  }
  cachedExec = "npm";
  return cachedExec;
};
var runCmd = async (command2, args, options = {}) => {
  const { $ } = globalThis.Bun;
  const env2 = { ...process2.env, ...options.env ?? {} };
  const cwd = options.cwd ?? process2.cwd();
  if (command2 === "zc") {
    console.error(`[debug] zc ${args.join(" ")}`);
    await $`zc ${args}`.cwd(cwd).env(env2);
    return;
  }
  if (command2 === "bun") {
    await $`bun ${args}`.cwd(cwd).env(env2);
  } else {
    const cmdPath = Bun.which(command2) || command2;
    const proc = Bun.spawn([cmdPath, ...args], {
      cwd,
      stdio: ["inherit", "inherit", "inherit"],
      env: env2
    });
    const code = await proc.exited;
    if (code !== 0) {
      throw new Error(`${command2} ${args.join(" ")} failed (${code})`);
    }
  }
};
var spawnStreaming = (command2, args, options = {}) => {
  const cmdPath = Bun.which(command2) || command2;
  return Bun.spawn([cmdPath, ...args], {
    cwd: options.cwd ?? process2.cwd(),
    stdio: ["inherit", "inherit", "inherit"],
    env: { ...process2.env, ...options.env ?? {} }
  });
};
var killChild = (child) => {
  if (!child || child.killed)
    return;
  const pid = child.pid;
  if (process2.platform === "win32" && pid) {
    try {
      execSync(`taskkill /F /T /PID ${pid}`, { stdio: "ignore" });
      return;
    } catch {}
  }
  try {
    child.kill("SIGTERM");
  } catch {
    try {
      child.kill(9);
    } catch {}
  }
};
var runPackageScript = (script, options = {}) => {
  const tool = preferredJsTool();
  const args = tool === "bun" ? ["run", script] : ["run", script];
  return runCmd(tool, args, options);
};
var spawnPackageScript = (script, options = {}) => {
  const tool = preferredJsTool();
  const args = tool === "bun" ? ["run", script] : ["run", script];
  return spawnStreaming(tool, args, options);
};

// src/build.ts
import path5 from "path";
import process5 from "process";
import { existsSync as existsSync2 } from "fs";
import { mkdir as mkdir4 } from "fs/promises";
import { brotliCompressSync, constants as zlibConstants } from "zlib";

// src/build-config.ts
import path2 from "path";
import { mkdir as mkdir2 } from "fs/promises";
var cString = (value) => JSON.stringify(value.replace(/\\/g, "/"));
var generateBuildConfigZc = async ({
  root,
  mode,
  assetDir,
  devUrl,
  backendScriptPath,
  logLevel
}) => {
  const buildDir = path2.join(root, ".zapp");
  await mkdir2(buildDir, { recursive: true });
  const isDev = mode === "dev" || mode === "dev-embedded";
  const useEmbeddedAssets = mode === "dev-embedded" || mode === "prod-embedded";
  const isDarwin = process.platform === "darwin";
  const prodUrl = isDarwin ? "zapp://index.html" : "https://app.localhost/index.html";
  const initialUrl = mode === "dev" ? devUrl ?? "http://localhost:5173" : prodUrl;
  const defaultLogLevel = isDev ? "info" : "warn";
  const effectiveLogLevel = logLevel ?? defaultLogLevel;
  const content = `// AUTO-GENERATED FILE. DO NOT EDIT.

raw {
    const char* zapp_build_mode_name(void) {
        return ${cString(mode)};
    }

    const char* zapp_build_asset_root(void) {
        return ${cString(assetDir)};
    }

    const char* zapp_build_initial_url(void) {
        return ${cString(initialUrl)};
    }

    int zapp_build_is_dev_mode(void) {
        return ${isDev ? 1 : 0};
    }

    int zapp_build_use_embedded_assets(void) {
        return ${useEmbeddedAssets ? 1 : 0};
    }

    const char* zapp_build_backend_script_path(void) {
        return ${backendScriptPath ? cString(backendScriptPath) : '""'};
    }

    const char* zapp_build_log_level(void) {
        return ${cString(effectiveLogLevel)};
    }
}
`;
  const outPath = path2.join(buildDir, "zapp_build_config.zc");
  await Bun.write(outPath, content);
  return outPath;
};

// src/backend.ts
import path3 from "path";
import process3 from "process";
import { mkdir as mkdir3 } from "fs/promises";
var BACKEND_CONVENTIONS = ["zapp/backend.ts", "zapp/backend.js", "backend.ts", "backend.js"];
async function findBackendScript(root) {
  for (const name of BACKEND_CONVENTIONS) {
    const candidate = path3.join(root, name);
    if (await Bun.file(candidate).exists()) {
      return candidate;
    }
  }
  return null;
}
function resolveZappPackage(pkg, root) {
  try {
    return __require.resolve(pkg, { paths: [root] });
  } catch {}
  const monorepoFallbacks = {
    "@zapp/runtime": "packages/runtime/index.ts",
    "@zapp/backend": "packages/backend/index.ts"
  };
  const relative2 = monorepoFallbacks[pkg];
  if (!relative2)
    return null;
  const candidate = path3.resolve(root, relative2);
  try {
    if (__require("fs").existsSync(candidate))
      return candidate;
  } catch {}
  return null;
}
async function resolveAndBundleBackend({
  root,
  frontendDir,
  backendScript
}) {
  let entryPath = null;
  if (backendScript) {
    entryPath = path3.resolve(root, backendScript);
    if (!await Bun.file(entryPath).exists()) {
      process3.stderr.write(`[zapp] backend script not found: ${entryPath}
`);
      return null;
    }
  } else {
    entryPath = await findBackendScript(root);
  }
  if (!entryPath)
    return null;
  process3.stdout.write(`[zapp] bundling backend script: ${path3.relative(root, entryPath)}
`);
  const buildDir = path3.join(root, ".zapp");
  await mkdir3(buildDir, { recursive: true });
  const outFile = path3.join(buildDir, "backend.bundle.js");
  const runtimePath = resolveZappPackage("@zapp/runtime", root);
  const backendPath = resolveZappPackage("@zapp/backend", root);
  if (!runtimePath || !backendPath) {
    process3.stderr.write(`[zapp] could not resolve @zapp/runtime or @zapp/backend from ${root}
` + `  Install them: bun add @zapp/runtime @zapp/backend
`);
    return null;
  }
  const hasBunBuild = typeof globalThis.Bun !== "undefined" && globalThis.Bun != null && typeof globalThis.Bun.build === "function";
  if (hasBunBuild) {
    const result = await globalThis.Bun.build({
      entrypoints: [entryPath],
      outdir: buildDir,
      naming: "backend.bundle.js",
      target: "browser",
      format: "esm",
      sourcemap: "none",
      minify: false,
      plugins: [
        {
          name: "zapp-backend-alias",
          setup(build) {
            build.onResolve({ filter: /^@zapp\/backend$/ }, () => ({ path: backendPath }));
            build.onResolve({ filter: /^@zapp\/backend\/(.*)/ }, (args) => ({
              path: path3.join(path3.dirname(backendPath), args.path.slice("@zapp/backend/".length))
            }));
            build.onResolve({ filter: /^@zapp\/runtime$/ }, () => ({ path: runtimePath }));
            build.onResolve({ filter: /^@zapp\/runtime\/(.*)/ }, (args) => ({
              path: path3.join(path3.dirname(runtimePath), args.path.slice("@zapp/runtime/".length))
            }));
          }
        }
      ]
    });
    if (!result.success) {
      const lines = (result.logs ?? []).map((log) => log?.message).filter(Boolean).join(`
`);
      process3.stderr.write(`[zapp] backend bundle failed:
${lines}
`);
      return null;
    }
  } else {
    const { build: esbuild } = await Promise.resolve().then(() => __toESM(require_main(), 1));
    await esbuild({
      entryPoints: [entryPath],
      bundle: true,
      format: "esm",
      platform: "browser",
      target: "es2022",
      sourcemap: false,
      minify: false,
      outfile: outFile,
      alias: {
        "@zapp/backend": backendPath,
        "@zapp/runtime": runtimePath
      }
    });
  }
  return outFile;
}

// src/generate.ts
import fs from "fs/promises";
import path4 from "path";
import process4 from "process";
var ZEN_TO_TS_TYPES = {
  string: "string",
  int: "number",
  float: "number",
  double: "number",
  bool: "boolean",
  void: "void"
};
function mapType(zenType) {
  return ZEN_TO_TS_TYPES[zenType.trim()] ?? "unknown";
}
async function scanServices(srcDir) {
  const services = [];
  const files = [];
  async function walk(dir) {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name.startsWith(".") || entry.name === "vendor")
        continue;
      const full = path4.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.name.endsWith(".zc")) {
        files.push(full);
      }
    }
  }
  await walk(srcDir);
  const allContent = [];
  for (const file of files) {
    const content = await fs.readFile(file, "utf8");
    allContent.push({ file, content });
  }
  const addPattern = /\.service\.add\(\s*"([^"]+)"\s*,\s*(\w+)\s*\)/g;
  const registrations = [];
  for (const { content } of allContent) {
    let match;
    while ((match = addPattern.exec(content)) !== null) {
      registrations.push({ serviceName: match[1], handlerName: match[2] });
    }
  }
  for (const { serviceName, handlerName } of registrations) {
    const fnPattern = new RegExp(`fn\\s+${handlerName}\\s*\\(([^)]*)\\)\\s*->\\s*(\\w+)`);
    let found = false;
    for (const { content } of allContent) {
      const fnMatch = fnPattern.exec(content);
      if (!fnMatch)
        continue;
      const rawArgs = fnMatch[1];
      const returnType = mapType(fnMatch[2]);
      const args = [];
      for (const part of rawArgs.split(",")) {
        const trimmed = part.trim();
        if (!trimmed)
          continue;
        const [name, type] = trimmed.split(":").map((s) => s.trim());
        if (name === "app" || type === "App*")
          continue;
        args.push({ name, type: mapType(type) });
      }
      services.push({
        name: serviceName,
        methods: [{ name: serviceName, args, returnType }]
      });
      found = true;
      break;
    }
    if (!found) {
      process4.stderr.write(`[zapp] warning: could not find function '${handlerName}' for service '${serviceName}'
`);
    }
  }
  return services;
}
function generateBindingFile(service) {
  const lines = [
    `// Auto-generated by \`zapp generate\`. Do not edit.`,
    `import { Services } from "@zapp/runtime";`,
    ``
  ];
  const className = service.name.charAt(0).toUpperCase() + service.name.slice(1);
  lines.push(`export class ${className} {`);
  for (const method of service.methods) {
    const params = method.args.map((a) => `${a.name}: ${a.type}`).join(", ");
    const argsExpr = method.args.length === 0 ? "{}" : method.args.length === 1 ? method.args[0].name : `{ ${method.args.map((a) => a.name).join(", ")} }`;
    lines.push(`  static async ${method.name}(${params}): Promise<${method.returnType}> {`);
    lines.push(`    return Services.invoke<${method.returnType}>("${method.name}", ${argsExpr});`);
    lines.push(`  }`);
  }
  lines.push(`}`);
  lines.push(``);
  return lines.join(`
`);
}
async function runGenerate({
  root,
  outDir,
  frontendDir
}) {
  const base = frontendDir ?? root;
  const srcDir = path4.join(base, "src");
  const hasSrcDir = await fs.stat(srcDir).then(() => true, () => false);
  const targetDir = outDir ? path4.resolve(root, outDir) : path4.join(hasSrcDir ? srcDir : base, "generated");
  process4.stdout.write(`[zapp] scanning for service registrations...
`);
  const zappDir = path4.join(root, "zapp");
  const scanDir = await fs.stat(zappDir).then(() => zappDir, () => root);
  const services = await scanServices(scanDir);
  if (services.length === 0) {
    process4.stdout.write(`[zapp] no service registrations found. Nothing to generate.
`);
    return;
  }
  await fs.mkdir(targetDir, { recursive: true });
  const indexExports = [];
  for (const service of services) {
    const className = service.name.charAt(0).toUpperCase() + service.name.slice(1);
    const fileName = `${className}.ts`;
    const filePath = path4.join(targetDir, fileName);
    const content = generateBindingFile(service);
    await fs.writeFile(filePath, content, "utf8");
    process4.stdout.write(`[zapp] generated ${path4.relative(root, filePath)}
`);
    indexExports.push(`export { ${className} } from "./${className}";`);
  }
  const indexPath = path4.join(targetDir, "index.ts");
  await fs.writeFile(indexPath, `// Auto-generated by \`zapp generate\`. Do not edit.
${indexExports.join(`
`)}
`, "utf8");
  process4.stdout.write(`[zapp] generated ${services.length} binding(s) in ${path4.relative(root, targetDir)}/
`);
}

// src/build.ts
var walkFiles = async (dir) => {
  const glob = new Bun.Glob("**/*");
  const files = [];
  for await (const file of glob.scan({ cwd: dir, absolute: true })) {
    const stat = Bun.file(file);
    if (stat.size > 0 || await stat.exists()) {
      files.push(file);
    }
  }
  return files;
};
var maybeBrotli = async (filePath) => {
  const source = await Bun.file(filePath).arrayBuffer();
  const compressed = brotliCompressSync(new Uint8Array(source), {
    params: {
      [zlibConstants.BROTLI_PARAM_QUALITY]: 11
    }
  });
  const outPath = `${filePath}.br`;
  await Bun.write(outPath, compressed);
  return outPath;
};
var generateAssetsZc = async (root, manifest, assetDir) => {
  let zcContent = `// AUTO-GENERATED FILE. DO NOT EDIT.

`;
  if (!manifest.assets || manifest.assets.length === 0) {
    zcContent += `
raw {
    struct ZappEmbeddedAsset zapp_embedded_assets[1];
    int zapp_embedded_assets_count = 0;
}
`;
    const buildDir2 = path5.join(root, ".zapp");
    await mkdir4(buildDir2, { recursive: true });
    const outPath2 = path5.join(buildDir2, "zapp_assets.zc");
    await Bun.write(outPath2, zcContent);
    return outPath2;
  }
  const assetEntries = [];
  const assetExterns = [];
  for (let i = 0;i < manifest.assets.length; i++) {
    const item = manifest.assets[i];
    const isBrotli = item.brotli != null;
    const filePath = isBrotli ? item.brotli.file : item.file;
    const absPathToEmbed = path5.join(assetDir, filePath).replace(/\\/g, "/");
    zcContent += `let __zapp_asset_${i} = embed "${absPathToEmbed}" as u8[];
`;
    let logicalPath = "/" + item.file.replace(/\\/g, "/");
    assetExterns.push(`    extern Slice_uint8_t __zapp_asset_${i};`);
    assetEntries.push(`        zapp_embedded_assets[${i}].path = "${logicalPath}";`);
    assetEntries.push(`        zapp_embedded_assets[${i}].data = __zapp_asset_${i}.data;`);
    assetEntries.push(`        zapp_embedded_assets[${i}].len = __zapp_asset_${i}.len;`);
    assetEntries.push(`        zapp_embedded_assets[${i}].uncompressed_len = ${item.size};`);
    assetEntries.push(`        zapp_embedded_assets[${i}].is_brotli = ${isBrotli ? "true" : "false"};`);
  }
  zcContent += `
raw {
${assetExterns.join(`
`)}
    struct ZappEmbeddedAsset zapp_embedded_assets[${manifest.assets.length || 1}];
    int zapp_embedded_assets_count = ${manifest.assets.length};

    __attribute__((constructor))
    static void init_zapp_assets(void) {
${assetEntries.join(`
`)}
    }
}
`;
  const buildDir = path5.join(root, ".zapp");
  await mkdir4(buildDir, { recursive: true });
  const outPath = path5.join(buildDir, "zapp_assets.zc");
  await Bun.write(outPath, zcContent);
  return outPath;
};
var collectWorkerStems = async (assetDir) => {
  const stems = new Set;
  const manifestPath = path5.join(assetDir, "zapp-workers", "manifest.json");
  try {
    const raw = await Bun.file(manifestPath).text();
    const data = JSON.parse(raw);
    const workers = data.workers ?? data;
    for (const key of Object.keys(workers)) {
      const stem = path5.basename(key).replace(/\.[^.]+$/, "");
      if (stem)
        stems.add(stem);
    }
  } catch {}
  return stems;
};
var buildAssetManifest = async ({
  assetDir,
  withBrotli
}) => {
  const allFiles = await walkFiles(assetDir);
  const workerStems = withBrotli ? await collectWorkerStems(assetDir) : new Set;
  const manifest = {
    v: 1,
    generatedAt: new Date().toISOString(),
    assets: [],
    embedded: true
  };
  for (const file of allFiles) {
    const rel = path5.relative(assetDir, file).split(path5.sep).join("/");
    const stat = Bun.file(file);
    const item = { file: rel, size: stat.size, brotli: null };
    let skipBrotli = false;
    if (rel.startsWith("zapp-workers/")) {
      skipBrotli = true;
    } else if (rel.startsWith("assets/") && workerStems.size > 0) {
      const baseName = path5.basename(rel).replace(/\.[^.]+$/, "");
      for (const stem of workerStems) {
        if (baseName === stem || baseName.startsWith(`${stem}-`)) {
          skipBrotli = true;
          break;
        }
      }
    }
    if (withBrotli && !skipBrotli) {
      const brPath = await maybeBrotli(file);
      const brStat = Bun.file(brPath);
      item.brotli = { file: `${rel}.br`, size: brStat.size };
    }
    manifest.assets.push(item);
  }
  return manifest;
};
var runBuild = async ({
  root,
  frontendDir,
  buildFile,
  nativeOut,
  assetDir,
  withBrotli,
  embedAssets,
  isDebug,
  backendScript,
  logLevel,
  config
}) => {
  if (withBrotli && !embedAssets) {
    process5.stdout.write(`[zapp] note: --brotli has no effect without embedded assets
`);
  }
  await runGenerate({ root, frontendDir });
  process5.stdout.write(`[zapp] building frontend assets (${preferredJsTool()})
`);
  await runPackageScript("build", { cwd: frontendDir });
  const manifest = embedAssets ? await buildAssetManifest({ assetDir, withBrotli }) : { v: 1, generatedAt: new Date().toISOString(), assets: [], embedded: false };
  if (embedAssets) {
    const manifestPath = path5.join(assetDir, "zapp-assets-manifest.json");
    await Bun.write(manifestPath, JSON.stringify(manifest, null, 2));
  }
  const backendScriptPath = await resolveAndBundleBackend({ root, frontendDir, backendScript });
  const buildMode = isDebug ? "prod" : embedAssets ? "prod-embedded" : "prod";
  const effectiveLogLevel = logLevel ?? (isDebug ? "debug" : "warn");
  const buildConfigFile = await generateBuildConfigZc({
    root,
    mode: buildMode,
    assetDir,
    backendScriptPath,
    logLevel: effectiveLogLevel
  });
  process5.stdout.write(`[zapp] building native binary
`);
  await mkdir4(path5.dirname(nativeOut), { recursive: true });
  const qjsLib = await ensureQjsLib(root, isDebug ? "dev" : "release");
  const zcArgs = ["build", buildFile, buildConfigFile, ...nativeIncludeArgs()];
  const assetsFile = await generateAssetsZc(root, manifest, assetDir);
  if (await Bun.file(assetsFile).exists())
    zcArgs.push(assetsFile);
  if (isDebug) {
    zcArgs.push("--debug");
  } else {
    zcArgs.push("-Oz");
    zcArgs.push("-flto");
    zcArgs.push("--no-debug");
  }
  if (process5.platform === "win32") {
    const manifestSrc = path5.join(root, "config", "windows", "app.manifest");
    if (existsSync2(manifestSrc)) {
      const buildDir = path5.join(root, ".zapp", "build");
      await mkdir4(buildDir, { recursive: true });
      const rcPath = path5.join(buildDir, "app.rc");
      await Bun.write(rcPath, `1 24 "${manifestSrc.replace(/\\/g, "/")}"
`);
      const resPath = path5.join(buildDir, "app_manifest.o");
      await runCmd("windres", [rcPath, "-O", "coff", "-o", resPath]);
      zcArgs.push(resPath);
    }
  }
  zcArgs.push("-o", nativeOut, "-L", path5.dirname(qjsLib), "-lqjs");
  await runCmd("zc", zcArgs, { cwd: root, env: { ZAPP_NATIVE: resolveNativeDir() } });
  if (!isDebug) {
    try {
      const stripPath = Bun.which("strip");
      if (stripPath) {
        await runCmd("strip", [nativeOut]);
      }
    } catch (e) {
      process5.stdout.write(`[zapp] warning: strip failed: ${e}
`);
    }
  }
  process5.stdout.write([
    "[zapp] build complete",
    `native: ${nativeOut}`,
    `mode: ${isDebug ? "debug" : buildMode}`,
    "",
    "Run:",
    `${nativeOut}`,
    ""
  ].join(`
`));
};

// src/dev.ts
var waitForUrl = async (url, timeoutMs) => {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(url);
      if (res.ok)
        return;
    } catch {
      await sleep(100);
    }
  }
  throw new Error(`Timed out waiting for ${url}`);
};
var runDev = async ({
  root,
  frontendDir,
  buildFile,
  nativeOut,
  devUrl,
  withBrotli,
  embedAssets,
  backendScript,
  logLevel,
  config
}) => {
  process6.stdout.write(`[zapp] starting dev orchestration (${preferredJsTool()})
`);
  if (withBrotli && !embedAssets) {
    process6.stdout.write(`[zapp] note: --brotli has no effect without --embed-assets
`);
  }
  await runGenerate({ root, frontendDir });
  const vite = embedAssets ? null : spawnPackageScript("dev", { cwd: frontendDir });
  let app = null;
  let shuttingDown = false;
  const shutdown = (reason = "error") => {
    if (shuttingDown)
      return;
    shuttingDown = true;
    if (reason === "user") {
      process6.stdout.write(`
[zapp] gracefully exiting...
`);
    } else if (reason === "app-exit") {
      process6.stdout.write(`[zapp] app exited, cleaning up...
`);
    }
    killChild(app);
    killChild(vite);
    setTimeout(() => process6.exit(0), 1500);
  };
  process6.on("SIGINT", () => shutdown("user"));
  process6.on("SIGTERM", () => shutdown("user"));
  process6.on("SIGHUP", () => shutdown("user"));
  if (process6.platform === "win32" && process6.stdin.isTTY) {
    const rl = createInterface({ input: process6.stdin });
    rl.on("SIGINT", () => shutdown("user"));
    rl.on("close", () => shutdown("user"));
  }
  try {
    const assetDir = path6.join(frontendDir, "dist");
    if (embedAssets) {
      process6.stdout.write(`[zapp] dev embedded mode: building static frontend assets
`);
      await runPackageScript("build", { cwd: frontendDir });
    } else {
      await waitForUrl(devUrl, 30000);
    }
    const backendScriptPath = await resolveAndBundleBackend({ root, frontendDir, backendScript });
    const buildConfigFile = await generateBuildConfigZc({
      root,
      mode: embedAssets ? "dev-embedded" : "dev",
      assetDir,
      devUrl,
      backendScriptPath,
      logLevel
    });
    await mkdir5(path6.dirname(nativeOut), { recursive: true });
    const qjsLib = await ensureQjsLib(root, "dev");
    const zcArgs = ["build", buildFile, buildConfigFile, "-DZAPP_BUILD_DEV", "--debug", ...nativeIncludeArgs()];
    const manifest = embedAssets ? await buildAssetManifest({ assetDir, withBrotli }) : { v: 1, generatedAt: new Date().toISOString(), assets: [], embedded: false };
    const assetsFile = await generateAssetsZc(root, manifest, assetDir);
    zcArgs.push(assetsFile);
    if (process6.platform === "win32") {
      const manifestSrc = path6.join(root, "config", "windows", "app.manifest");
      if (existsSync3(manifestSrc)) {
        const buildDir = path6.join(root, ".zapp", "build");
        await mkdir5(buildDir, { recursive: true });
        const rcPath = path6.join(buildDir, "app.rc");
        await Bun.write(rcPath, `1 24 "${manifestSrc.replace(/\\/g, "/")}"
`);
        const resPath = path6.join(buildDir, "app_manifest.o");
        await runCmd("windres", [rcPath, "-O", "coff", "-o", resPath]);
        zcArgs.push(resPath);
      }
    }
    zcArgs.push("-o", nativeOut, "-L", path6.dirname(qjsLib), "-lqjs");
    await runCmd("zc", zcArgs, { cwd: root, env: { ZAPP_NATIVE: resolveNativeDir() } });
    app = spawnStreaming(nativeOut, [], {
      cwd: root
    });
    app.exited.then((code) => {
      if (!shuttingDown) {
        shutdown("app-exit");
      }
    });
    vite?.exited.then(() => {
      if (!shuttingDown) {
        shutdown("error");
      }
    });
  } catch (error) {
    shutdown("error");
    throw error;
  }
  await new Promise(() => {});
  return path6.resolve(root);
};

// src/init.ts
import path7 from "path";
import { mkdir as mkdir6 } from "fs/promises";
var runInit = async ({
  root,
  name,
  template,
  withBackend
}) => {
  const projectDir = path7.resolve(root, name);
  const zappDir = path7.join(projectDir, "zapp");
  const configDir = path7.join(projectDir, "config");
  const darwinConfigDir = path7.join(configDir, "darwin");
  const windowsConfigDir = path7.join(configDir, "windows");
  console.log(`Scaffolding Zapp project in ${projectDir}...`);
  await mkdir6(projectDir, { recursive: true });
  console.log(`Creating Vite project with template: ${template}...`);
  await spawnStreaming("bun", ["create", "vite", ".", "--template", template], { cwd: projectDir }).exited;
  await mkdir6(zappDir, { recursive: true });
  await mkdir6(darwinConfigDir, { recursive: true });
  await mkdir6(windowsConfigDir, { recursive: true });
  const pkgPath = path7.join(projectDir, "package.json");
  let pkgObj = {};
  try {
    const pkgFile = Bun.file(pkgPath);
    if (await pkgFile.exists()) {
      const pkgRaw = await pkgFile.text();
      pkgObj = JSON.parse(pkgRaw);
    }
  } catch (err) {
    console.error(`Warning: Could not read ${pkgPath}`);
  }
  pkgObj.devDependencies = pkgObj.devDependencies || {};
  pkgObj.devDependencies["@zapp/cli"] = "latest";
  pkgObj.devDependencies["@zapp/vite"] = "latest";
  pkgObj.dependencies = pkgObj.dependencies || {};
  pkgObj.dependencies["@zapp/runtime"] = "latest";
  if (withBackend) {
    pkgObj.dependencies["@zapp/backend"] = "latest";
  }
  await Bun.write(pkgPath, JSON.stringify(pkgObj, null, 2));
  const appZcContent = `import "app/app.zc";

fn run_app() -> int {
    let config = AppConfig{ 
        name: "${name}", 
        applicationShouldTerminateAfterLastWindowClosed: true,
        webContentInspectable: true,
        maxWorkers: 50,
    };
    let app = App::new(config);
    return app.run();
}
`;
  await Bun.write(path7.join(zappDir, "app.zc"), appZcContent);
  const zappConfigContent = `import { defineConfig } from "@zapp/cli/config";

export default defineConfig({
  name: "${name}",
});
`;
  await Bun.write(path7.join(zappDir, "zapp.config.ts"), zappConfigContent);
  const buildZcContent = `// Include paths and library paths are injected by the zapp CLI.

// --- macOS Directives ---
//> macos: framework: Cocoa
//> macos: framework: WebKit
//> macos: framework: CoreFoundation
//> macos: framework: JavaScriptCore
//> macos: framework: Security
//> macos: link: -lcompression
//> macos: cflags: -fobjc-arc -x objective-c
// To use QuickJS instead of JSC on macOS, uncomment:
//   //> macos: define: ZAPP_WORKER_ENGINE_QJS

// --- Windows Directives (QuickJS default) ---
//> windows: cflags: -DUNICODE -D_UNICODE -DCINTERFACE -DCOBJMACROS
//> windows: link: -lole32 -lshell32 -luuid -luser32 -lgdi32 -lcomctl32 -lcomdlg32 -lshlwapi
//> windows: link: -lwinhttp -lbcrypt -ladvapi32 -lrpcrt4 -lcrypt32 -lversion
//> windows: define: ZAPP_WORKER_ENGINE_QJS

import "app.zc";

fn main() -> int {
    return run_app();
}
`;
  await Bun.write(path7.join(zappDir, "build.zc"), buildZcContent);
  if (withBackend) {
    const backendContent = `import { App } from "@zapp/backend";

// Your backend TypeScript runs in a privileged native context
// with direct access to native bridge, window management, and app lifecycle.
`;
    await Bun.write(path7.join(zappDir, "backend.ts"), backendContent);
  }
  const plistContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${name}</string>
    <key>CFBundleIdentifier</key>
    <string>com.zapp.${name}</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.13</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
`;
  await Bun.write(path7.join(darwinConfigDir, "Info.plist"), plistContent);
  const manifestContent = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity
    type="win32"
    name="com.zapp.${name}"
    version="1.0.0.0"
  />
  <description>${name}</description>

  <!-- Enable visual styles (modern controls) -->
  <dependency>
    <dependentAssembly>
      <assemblyIdentity
        type="win32"
        name="Microsoft.Windows.Common-Controls"
        version="6.0.0.0"
        processorArchitecture="*"
        publicKeyToken="6595b64144ccf1df"
        language="*"
      />
    </dependentAssembly>
  </dependency>

  <!-- High-DPI awareness (Per-Monitor V2) -->
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2,PerMonitor</dpiAwareness>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">True/PM</dpiAware>
    </windowsSettings>
  </application>

  <!-- Declare supported OS versions -->
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}" /> <!-- Windows 10/11 -->
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}" /> <!-- Windows 8.1 -->
    </application>
  </compatibility>
</assembly>
`;
  await Bun.write(path7.join(windowsConfigDir, "app.manifest"), manifestContent);
  console.log(`
Project ${name} scaffolded successfully!`);
  console.log(`Next steps:`);
  console.log(`  cd ${name}`);
  console.log(`  bun install`);
  console.log(`  zapp dev`);
};

// src/package.ts
import { mkdir as mkdir7, copyFile, chmod } from "fs/promises";
import path8 from "path";
import process7 from "process";
var runPackage = async ({ root, nativeOut, config }) => {
  if (process7.platform !== "darwin") {
    console.error("The package command is currently only supported on macOS.");
    return;
  }
  const appName = config.name;
  const appBundleName = `${appName}.app`;
  const appBundlePath = path8.join(root, appBundleName);
  console.log(`Packaging ${appName} to ${appBundleName}...`);
  const contentsDir = path8.join(appBundlePath, "Contents");
  const macosDir = path8.join(contentsDir, "MacOS");
  const resourcesDir = path8.join(contentsDir, "Resources");
  await mkdir7(macosDir, { recursive: true });
  await mkdir7(resourcesDir, { recursive: true });
  const execPath = path8.resolve(root, nativeOut);
  const execFile = Bun.file(execPath);
  if (!await execFile.exists()) {
    console.error(`Error: Native binary not found at ${execPath}. Run 'zapp build' first.`);
    return;
  }
  const destExecPath = path8.join(macosDir, appName);
  await copyFile(execPath, destExecPath);
  await chmod(destExecPath, 493);
  const configPlistPath = path8.join(root, "config", "darwin", "Info.plist");
  let plistContent = "";
  const plistFile = Bun.file(configPlistPath);
  if (await plistFile.exists()) {
    plistContent = await plistFile.text();
    console.log(`Using Info.plist from ${configPlistPath}`);
  } else {
    console.log(`No Info.plist found at ${configPlistPath}, generating default...`);
    plistContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${appName}</string>
    <key>CFBundleExecutable</key>
    <string>${appName}</string>
    <key>CFBundleIdentifier</key>
    <string>${config.identifier}</string>
    <key>CFBundleVersion</key>
    <string>${config.version}</string>
    <key>CFBundleShortVersionString</key>
    <string>${config.version}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.13</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>`;
  }
  if (!plistContent.includes("<key>CFBundleExecutable</key>")) {
    plistContent = plistContent.replace("<dict>", `<dict>
    <key>CFBundleExecutable</key>
    <string>${appName}</string>`);
  }
  await Bun.write(path8.join(contentsDir, "Info.plist"), plistContent);
  try {
    console.log(`Codesigning ${appBundlePath}...`);
    await runCmd("codesign", ["--force", "--deep", "--sign", "-", appBundlePath]);
  } catch (err) {
    console.error(`Warning: Failed to codesign ${appBundlePath}:`, err);
  }
  console.log(`Successfully packaged to ${appBundlePath}`);
};

// src/config.ts
import path9 from "path";
function applyDefaults(config) {
  return {
    name: config.name,
    identifier: config.identifier ?? `com.zapp.${config.name}`,
    version: config.version ?? "1.0.0"
  };
}
async function loadConfig(root) {
  const configPath = path9.join(root, "zapp", "zapp.config.ts");
  const configFile = Bun.file(configPath);
  if (await configFile.exists()) {
    try {
      const mod = await import(configPath);
      const raw = mod.default ?? mod;
      if (!raw.name || typeof raw.name !== "string") {
        throw new Error(`"name" is required in ${configPath} and must be a non-empty string`);
      }
      return applyDefaults(raw);
    } catch (err) {
      if (err instanceof Error && err.message.includes("name"))
        throw err;
      throw new Error(`Failed to load ${configPath}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
  const fallbackName = path9.basename(root) || "zapp-app";
  return applyDefaults({ name: fallbackName });
}

// src/zapp-cli.ts
var VALID_LOG_LEVELS = ["error", "warn", "info", "debug", "trace"];
var checkPrerequisites = () => {
  const which = Bun.which("zc");
  if (!which) {
    console.error(`[zapp] Error: 'zc' (Zen-C compiler) not found on PATH.
` + `  Install from: https://github.com/zenc-lang/zenc
`);
    process8.exit(1);
  }
};
var cwd = process8.cwd();
var commonOptions = {
  root: {
    type: "string",
    default: ".",
    describe: "Project root directory"
  },
  frontend: {
    type: "string",
    default: ".",
    describe: "Frontend directory"
  },
  input: {
    type: "string",
    default: "zapp/build.zc",
    describe: "Build file (alias: --build-file)"
  },
  out: {
    type: "string",
    describe: "Override output binary path"
  },
  backend: {
    type: "string",
    describe: "Backend script path"
  },
  "log-level": {
    type: "string",
    choices: VALID_LOG_LEVELS,
    describe: "Log level"
  }
};
var cli = yargs_default(hideBin(process8.argv)).scriptName("zapp").usage("zapp <command> [options]").strict().demandCommand(1, "Please specify a command").command("init [name]", "Scaffold a new Zapp project", (yargs) => yargs.positional("name", {
  type: "string",
  default: "zapp-app",
  describe: "Project name"
}).option("template", {
  type: "string",
  default: "svelte-ts",
  describe: "Frontend template"
}).option("backend", {
  type: "boolean",
  default: false,
  describe: "Include backend script"
}).option("root", commonOptions.root), async (argv) => {
  const root = path10.resolve(cwd, argv.root);
  await runInit({
    root,
    name: argv.name,
    template: argv.template,
    withBackend: argv.backend
  });
}).command("dev", "Run Vite + native app together", (yargs) => yargs.option("root", commonOptions.root).option("frontend", commonOptions.frontend).option("input", commonOptions.input).option("out", commonOptions.out).option("backend", commonOptions.backend).option("log-level", commonOptions["log-level"]).option("dev-url", {
  type: "string",
  default: "http://localhost:5173",
  describe: "Dev server URL"
}).option("brotli", {
  type: "boolean",
  default: false,
  describe: "Brotli-compress embedded assets"
}).option("embed-assets", {
  type: "boolean",
  default: false,
  describe: "Embed assets in binary (default: false for dev)"
}), async (argv) => {
  checkPrerequisites();
  const root = path10.resolve(cwd, argv.root);
  const frontendDir = path10.resolve(root, argv.frontend);
  const buildFile = path10.resolve(root, argv.input);
  const config = await loadConfig(root);
  const nativeOut = argv.out ? path10.resolve(root, argv.out) : path10.resolve(root, "bin", process8.platform === "win32" ? `${config.name}.exe` : config.name);
  await runDev({
    root,
    frontendDir,
    buildFile,
    nativeOut,
    devUrl: argv["dev-url"],
    withBrotli: argv.brotli,
    embedAssets: argv["embed-assets"],
    backendScript: argv.backend,
    logLevel: argv["log-level"],
    config
  });
}).command("build", "Build frontend assets + native binary", (yargs) => yargs.option("root", commonOptions.root).option("frontend", commonOptions.frontend).option("input", commonOptions.input).option("out", commonOptions.out).option("backend", commonOptions.backend).option("log-level", commonOptions["log-level"]).option("asset-dir", {
  type: "string",
  default: "dist",
  describe: "Asset directory"
}).option("brotli", {
  type: "boolean",
  default: false,
  describe: "Brotli-compress embedded assets"
}).option("debug", {
  type: "boolean",
  default: false,
  describe: "Debug build (filesystem assets, debug logs, no optimizations)"
}), async (argv) => {
  checkPrerequisites();
  const root = path10.resolve(cwd, argv.root);
  const frontendDir = path10.resolve(root, argv.frontend);
  const buildFile = path10.resolve(root, argv.input);
  const assetDir = path10.resolve(frontendDir, argv["asset-dir"]);
  const config = await loadConfig(root);
  const nativeOut = argv.out ? path10.resolve(root, argv.out) : path10.resolve(root, "bin", process8.platform === "win32" ? `${config.name}.exe` : config.name);
  const embedAssets = !argv.debug;
  await runBuild({
    root,
    frontendDir,
    buildFile,
    nativeOut,
    assetDir,
    withBrotli: argv.brotli,
    embedAssets,
    isDebug: argv.debug,
    backendScript: argv.backend,
    logLevel: argv["log-level"],
    config
  });
}).command("package", "Package the binary into a macOS .app bundle", (yargs) => yargs.option("root", commonOptions.root).option("out", commonOptions.out), async (argv) => {
  checkPrerequisites();
  const root = path10.resolve(cwd, argv.root);
  const config = await loadConfig(root);
  const nativeOut = argv.out ? path10.resolve(root, argv.out) : path10.resolve(root, "bin", process8.platform === "win32" ? `${config.name}.exe` : config.name);
  await runPackage({ root, nativeOut, config });
}).command("generate", "Generate TypeScript bindings from Zen-C services", (yargs) => yargs.option("root", commonOptions.root).option("frontend", commonOptions.frontend).option("out-dir", {
  type: "string",
  describe: "Output directory for generated files"
}), async (argv) => {
  const root = path10.resolve(cwd, argv.root);
  const frontendDir = path10.resolve(root, argv.frontend);
  await runGenerate({ root, frontendDir, outDir: argv["out-dir"] });
}).alias("h", "help").alias("v", "version").alias("build-file", "input").epilogue("Documentation: https://zapp.dev").parse();
