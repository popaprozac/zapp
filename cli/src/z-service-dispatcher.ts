import path from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import type {
  ZServiceEnumMetadata,
  ZServiceManifest,
  ZServiceMethodMetadata,
  ZServiceTypeMetadata,
} from "./z-service-bindings";
import {
  assertZServiceCodecNames,
  zArrayElementType,
  zOptionPayloadType,
  zWireCodecSuffix,
} from "./z-service-bindings";

export interface RenderZServiceDispatchersOptions {
  outputPath: string;
  serviceContractModule: string;
  servicesModule: string;
  asyncServiceContractModule: string;
  serviceLifecycleContractModule: string;
}

const identifier = /^[A-Za-z_$][A-Za-z0-9_$]*$/;
const copiedScalars = new Set([
  "boolean",
  "u8",
  "u16",
  "u32",
  "u64",
  "i8",
  "i16",
  "i32",
  "i64",
  "usize",
  "f64",
]);

function assertIdentifier(value: string, description: string): void {
  if (!identifier.test(value)) {
    throw new Error(`[zapp] ${description} ${JSON.stringify(value)} is not a valid Z identifier`);
  }
}

function generatedName(value: string): string {
  assertIdentifier(value, "generated service symbol");
  return value[0].toUpperCase() + value.slice(1);
}

export function zServiceAdapterFactoryName(serviceName: string): string {
  return `__zappAdapt${generatedName(serviceName)}`;
}

export function zServiceUsesAsyncDispatch(
  service: ZServiceManifest["services"][number],
): boolean {
  return service.methods.some((method) => (
    method.asynchronous || method.executorAffinity === "thread.main"
  ));
}

function relativeModule(fromFile: string, target: string): string {
  let relative = path.relative(path.dirname(fromFile), target).replaceAll(path.sep, "/");
  if (!relative.startsWith(".")) relative = `./${relative}`;
  return relative;
}

function moved(
  type: string,
  expression: string,
  copyableTypes: ReadonlySet<string> = copiedScalars,
): string {
  return copyableTypes.has(type) ? expression : `move ${expression}`;
}

function copied(
  type: string,
  expression: string,
  copyableTypes: ReadonlySet<string> = copiedScalars,
): string {
  return copyableTypes.has(type) ? expression : `copy ${expression}`;
}

function inputCall(
  method: ZServiceMethodMetadata,
  copyableTypes: ReadonlySet<string>,
): string {
  if (!method.input) return "";
  if (method.inputMode === "value") {
    return moved(method.input, "input", copyableTypes);
  }
  if (method.inputMode === "in") return "in input";
  throw new Error(
    `[zapp] generated WebView dispatch does not support ${method.inputMode ?? "missing"} `
    + `input capability for method ${JSON.stringify(method.name)}`,
  );
}

export function collectZWireType(
  type: string,
  namedTypes: Map<string, ZServiceTypeMetadata>,
  enumTypes: Map<string, ZServiceEnumMetadata>,
  selected: Set<string>,
): void {
  if (selected.has(type)) return;
  selected.add(type);
  const arrayElement = zArrayElementType(type);
  if (arrayElement) {
    collectZWireType(arrayElement, namedTypes, enumTypes, selected);
    return;
  }
  const optionPayload = zOptionPayloadType(type);
  if (optionPayload) {
    collectZWireType(optionPayload, namedTypes, enumTypes, selected);
    return;
  }
  const enumeration = enumTypes.get(type);
  if (enumeration) {
    for (const variant of enumeration.variants) {
      if (variant.payload) collectZWireType(variant.payload, namedTypes, enumTypes, selected);
    }
    return;
  }
  const named = namedTypes.get(type);
  if (!named) return;
  for (const field of named.fields) collectZWireType(field.type, namedTypes, enumTypes, selected);
}

function collectWireTypeNames(type: string, selected: Set<string>): void {
  if (selected.has(type)) return;
  selected.add(type);
  const nested = zArrayElementType(type) ?? zOptionPayloadType(type);
  if (nested) collectWireTypeNames(nested, selected);
}

function wireTypeIsCopyable(
  type: string,
  namedTypes: ReadonlyMap<string, ZServiceTypeMetadata>,
  enumTypes: ReadonlyMap<string, ZServiceEnumMetadata>,
  memo: Map<string, boolean>,
  visiting: Set<string>,
): boolean {
  const cached = memo.get(type);
  if (cached !== undefined) return cached;
  if (copiedScalars.has(type)) return true;
  if (type === "String" || zArrayElementType(type)) return false;
  if (visiting.has(type)) return false;
  visiting.add(type);
  const optionPayload = zOptionPayloadType(type);
  const enumeration = enumTypes.get(type);
  const named = namedTypes.get(type);
  let copyable = false;
  if (optionPayload) {
    copyable = wireTypeIsCopyable(optionPayload, namedTypes, enumTypes, memo, visiting);
  } else if (enumeration) {
    copyable = enumeration.variants.every((variant) => (
      !variant.payload
      || wireTypeIsCopyable(variant.payload, namedTypes, enumTypes, memo, visiting)
    ));
  } else if (named) {
    copyable = named.fields.every((field) => (
      wireTypeIsCopyable(field.type, namedTypes, enumTypes, memo, visiting)
    ));
  }
  visiting.delete(type);
  memo.set(type, copyable);
  return copyable;
}

export function zWireCopyableTypes(
  manifest: ZServiceManifest,
  namedTypes: ReadonlyMap<string, ZServiceTypeMetadata>,
  enumTypes: ReadonlyMap<string, ZServiceEnumMetadata>,
): Set<string> {
  const candidates = new Set<string>(copiedScalars);
  for (const type of [...manifest.types, ...manifest.errors]) {
    collectWireTypeNames(type.name, candidates);
    for (const field of type.fields) collectWireTypeNames(field.type, candidates);
  }
  for (const enumeration of manifest.enums) {
    collectWireTypeNames(enumeration.name, candidates);
    for (const variant of enumeration.variants) {
      if (variant.payload) collectWireTypeNames(variant.payload, candidates);
    }
  }
  for (const service of manifest.services) {
    for (const method of service.methods) {
      if (method.input) collectWireTypeNames(method.input, candidates);
      collectWireTypeNames(method.returns, candidates);
      if (method.error) collectWireTypeNames(method.error, candidates);
    }
  }
  const memo = new Map<string, boolean>();
  return new Set([...candidates].filter((type) => (
    wireTypeIsCopyable(type, namedTypes, enumTypes, memo, new Set())
  )));
}

export function renderZDecodeArray(type: string): string {
  const element = zArrayElementType(type)!;
  const suffix = zWireCodecSuffix(type);
  return `function __zappDecode${suffix}(
  in value: JsonValue
): ${type} throws __ZappServiceCodecError {
  return match (in value) {
    array(values) => {
      let decoded = Array<${element}>();
      for (const element of values) {
        decoded.push(try __zappDecode${zWireCodecSuffix(element)}(in element));
      }
      select decoded;
    }
    _ => throw __zappCodecError("expected an array");
  };
}`;
}

export function renderZEncodeArray(type: string, copyableTypes: ReadonlySet<string>): string {
  const element = zArrayElementType(type)!;
  const suffix = zWireCodecSuffix(type);
  return `function __zappEncode${suffix}(
  value: ${type}
): JsonValue {
  let encoded = Array<JsonValue>();
  for (const element of value) {
    encoded.push(__zappEncode${zWireCodecSuffix(element)}(${copied(element, "element", copyableTypes)}));
  }
  return JsonValue.array(move encoded);
}`;
}

export function renderZDecodeOption(type: string, copyableTypes: ReadonlySet<string>): string {
  const payload = zOptionPayloadType(type)!;
  const suffix = zWireCodecSuffix(type);
  return `function __zappDecode${suffix}(
  in value: JsonValue
): ${type} throws __ZappServiceCodecError {
  return match (in value) {
    nullValue => Option<${payload}>.none;
    _ => {
      const decoded = try __zappDecode${zWireCodecSuffix(payload)}(in value);
      select Option.some(${moved(payload, "decoded", copyableTypes)});
    }
  };
}`;
}

export function renderZEncodeOption(type: string, copyableTypes: ReadonlySet<string>): string {
  const payload = zOptionPayloadType(type)!;
  const suffix = zWireCodecSuffix(type);
  return `function __zappEncode${suffix}(
  value: ${type}
): JsonValue {
  return match (value) {
    some(value) => __zappEncode${zWireCodecSuffix(payload)}(
      ${moved(payload, "value", copyableTypes)}
    );
    none => JsonValue.nullValue;
  };
}`;
}

export function renderZDecodeEnum(
  enumeration: ZServiceEnumMetadata,
  copyableTypes: ReadonlySet<string>,
): string {
  const hasPayload = enumeration.variants.some((variant) => variant.payload !== undefined);
  if (hasPayload) {
    const branches = enumeration.variants.map((variant) => {
      if (!variant.payload) {
        return `      if (kind == ${JSON.stringify(variant.name)}) {
        return ${enumeration.name}.${variant.name};
      }`;
      }
      return `      if (kind == ${JSON.stringify(variant.name)}) {
        const __payload = fields.get("value");
        const decoded = match (in __payload) {
          some(field) => try __zappDecode${zWireCodecSuffix(variant.payload)}(in field);
          none => throw __zappCodecError(${JSON.stringify(
            `missing payload for ${enumeration.name}.${variant.name}`,
          )});
        };
        return ${enumeration.name}.${variant.name}(
          ${moved(variant.payload, "decoded", copyableTypes)}
        );
      }`;
    }).join("\n");
    return `function __zappDecode${enumeration.name}(
  in value: JsonValue
): ${enumeration.name} throws __ZappServiceCodecError {
  return match (in value) {
    object(fields) => {
      const __kind = fields.get("kind");
      const kind = match (in __kind) {
        some(field) => try __zappDecodeString(in field);
        none => throw __zappCodecError("missing required enum discriminator kind");
      };
${branches}
      throw __zappCodecError(${JSON.stringify(`unknown ${enumeration.name} kind`)});
    }
    _ => throw __zappCodecError(${JSON.stringify(`expected an object for ${enumeration.name}`)});
  };
}`;
  }
  const branches = enumeration.variants.map((variant) => (
    `  if (text == ${JSON.stringify(variant.name)}) return `
    + `${enumeration.name}.${variant.name};`
  )).join("\n");
  return `function __zappDecode${enumeration.name}(
  in value: JsonValue
): ${enumeration.name} throws __ZappServiceCodecError {
  const text = match (in value) {
    string(text) => copy text;
    _ => throw __zappCodecError(${JSON.stringify(`expected a ${enumeration.name} variant`)});
  };
${branches}
  throw __zappCodecError(${JSON.stringify(`unknown ${enumeration.name} variant`)});
}`;
}

export function renderZEncodeEnum(
  enumeration: ZServiceEnumMetadata,
  copyableTypes: ReadonlySet<string>,
): string {
  const hasPayload = enumeration.variants.some((variant) => variant.payload !== undefined);
  if (hasPayload) {
    const arms = enumeration.variants.map((variant) => {
      const value = variant.payload
        ? `
      fields.set("value", __zappEncode${zWireCodecSuffix(variant.payload)}(
        ${moved(variant.payload, "value", copyableTypes)}
      ));`
        : "";
      const pattern = variant.payload ? `${variant.name}(value)` : variant.name;
      return `    ${pattern} => {
      let fields = Map<String, JsonValue>();
      fields.set("kind", JsonValue.string(${JSON.stringify(variant.name)}));${value}
      select JsonValue.object(move fields);
    }`;
    }).join("\n");
    return `function __zappEncode${enumeration.name}(
  value: ${enumeration.name}
): JsonValue {
  return match (value) {
${arms}
  };
}`;
  }
  const arms = enumeration.variants.map((variant) => (
    `    ${variant.name} => JsonValue.string(${JSON.stringify(variant.name)});`
  )).join("\n");
  return `function __zappEncode${enumeration.name}(
  value: ${enumeration.name}
): JsonValue {
  return match (value) {
${arms}
  };
}`;
}

export function renderZDecodeScalar(type: string): string {
  if (type === "String") {
    return `function __zappDecodeString(
  in value: JsonValue
): String throws __ZappServiceCodecError {
  return match (in value) {
    string(text) => copy text;
    _ => throw __zappCodecError("expected a string");
  };
}`;
  }
  if (type === "boolean") {
    return `function __zappDecodeBoolean(
  in value: JsonValue
): boolean throws __ZappServiceCodecError {
  return match (in value) {
    boolean(value) => value;
    _ => throw __zappCodecError("expected a boolean");
  };
}`;
  }
  if (type === "u64" || type === "i64") {
    const suffix = generatedName(type);
    const conversion = type === "u64" ? "toU64" : "toI64";
    return `function __zappDecode${suffix}(
  in value: JsonValue
): ${type} throws __ZappServiceCodecError {
  const text = match (in value) {
    string(text) => copy text;
    _ => throw __zappCodecError("expected an exact ${type} string");
  };
  const parsed = attempt JsonNumber.parse(in text);
  const number = match (parsed) {
    success(number) => number;
    failure(error) => throw __zappCodecError(copy error.message);
  };
  const converted = attempt number.${conversion}();
  return match (converted) {
    success(integer) => integer;
    failure(error) => throw __zappCodecError(copy error.message);
  };
}`;
  }
  if (type === "usize") {
    return `function __zappDecodeUsize(
  in value: JsonValue
): usize throws __ZappServiceCodecError {
  const number = match (in value) {
    number(number) => copy number;
    _ => throw __zappCodecError("expected a usize number");
  };
  const converted = attempt number.toU64();
  const integer = match (converted) {
    success(integer) => integer;
    failure(error) => throw __zappCodecError(copy error.message);
  };
  return usize(integer);
}`;
  }
  const signed = type.match(/^i(8|16|32)$/);
  if (signed) {
    const limits: Record<string, [string, string]> = {
      "8": ["128", "127"],
      "16": ["32768", "32767"],
      "32": ["2147483648", "2147483647"],
    };
    const [minimum, maximum] = limits[signed[1]];
    const suffix = generatedName(type);
    return `function __zappDecode${suffix}(
  in value: JsonValue
): ${type} throws __ZappServiceCodecError {
  const number = match (in value) {
    number(number) => copy number;
    _ => throw __zappCodecError("expected a ${type} number");
  };
  const converted = attempt number.toI64();
  const integer = match (converted) {
    success(integer) => integer;
    failure(error) => throw __zappCodecError(copy error.message);
  };
  if (integer < -i64(${minimum}) || integer > i64(${maximum})) {
    throw __zappCodecError("${type} value is out of range");
  }
  return ${type}(integer);
}`;
  }
  const unsigned = type.match(/^u(8|16|32)$/);
  if (unsigned) {
    const maximums: Record<string, string> = {
      "8": "255",
      "16": "65535",
      "32": "4294967295",
    };
    const maximum = maximums[unsigned[1]];
    const suffix = generatedName(type);
    return `function __zappDecode${suffix}(
  in value: JsonValue
): ${type} throws __ZappServiceCodecError {
  const number = match (in value) {
    number(number) => copy number;
    _ => throw __zappCodecError("expected a ${type} number");
  };
  const converted = attempt number.toU64();
  const integer = match (converted) {
    success(integer) => integer;
    failure(error) => throw __zappCodecError(copy error.message);
  };
  if (integer > u64(${maximum})) {
    throw __zappCodecError("${type} value is out of range");
  }
  return ${type}(integer);
}`;
  }
  if (type === "f64") {
    return `function __zappDecodeF64(
  in value: JsonValue
): f64 throws __ZappServiceCodecError {
  const number = match (in value) {
    number(number) => copy number;
    _ => throw __zappCodecError("expected a finite f64 number");
  };
  const converted = attempt number.toF64();
  return match (converted) {
    success(number) => number;
    failure(error) => throw __zappCodecError(copy error.message);
  };
}`;
  }
  throw new Error(
    `[zapp] generated Z dispatch does not decode scalar ${JSON.stringify(type)} yet`,
  );
}

export function renderZEncodeScalar(type: string): string {
  if (type === "String") {
    return `function __zappEncodeString(value: String): JsonValue {
  return JsonValue.string(move value);
}`;
  }
  if (type === "boolean") {
    return `function __zappEncodeBoolean(value: boolean): JsonValue {
  return JsonValue.boolean(value);
}`;
  }
  if (type === "u64") {
    return `function __zappEncodeU64(value: u64): JsonValue {
  return JsonValue.string(\`${"${value}"}\`);
}`;
  }
  if (type === "i64") {
    return `function __zappEncodeI64(value: i64): JsonValue {
  return JsonValue.string(\`${"${value}"}\`);
}`;
  }
  if (/^i(8|16|32)$/.test(type)) {
    const suffix = generatedName(type);
    return `function __zappEncode${suffix}(value: ${type}): JsonValue {
  return JsonValue.number(JsonNumber.fromI64(i64(value)));
}`;
  }
  if (/^u(8|16|32)$/.test(type) || type === "usize") {
    const suffix = generatedName(type);
    return `function __zappEncode${suffix}(value: ${type}): JsonValue {
  return JsonValue.number(JsonNumber.fromU64(u64(value)));
}`;
  }
  throw new Error(
    `[zapp] generated Z dispatch does not encode scalar ${JSON.stringify(type)} yet`,
  );
}

export function renderZDecodeType(
  type: ZServiceTypeMetadata,
  copyableTypes: ReadonlySet<string>,
): string {
  const fields = type.fields.map((field) => {
    assertIdentifier(field.name, `${type.name} field`);
    const missing = field.optional
      ? `${field.type}.none`
      : `throw __zappCodecError(${JSON.stringify(`missing required field ${field.name}`)})`;
    return `        const __field_${field.name} = fields.get(${JSON.stringify(field.name)});
        const ${field.name} = match (in __field_${field.name}) {
          some(field) => try __zappDecode${zWireCodecSuffix(field.type)}(in field);
          none => ${missing};
        };`;
  }).join("\n");
  const initialization = type.fields
    .map((field) => (
      `          ${field.name}: ${moved(field.type, field.name, copyableTypes)},`
    ))
    .join("\n");
  return `function __zappDecode${generatedName(type.name)}(
  in value: JsonValue
): ${type.name} throws __ZappServiceCodecError {
  return match (in value) {
    object(fields) => {
${fields}
      select ${type.name}({
${initialization}
      });
    }
    _ => throw __zappCodecError(${JSON.stringify(`expected an object for ${type.name}`)});
  };
}`;
}

export function renderZEncodeType(
  type: ZServiceTypeMetadata,
  copyableTypes: ReadonlySet<string>,
): string {
  const names = type.fields.map((field) => field.name).join(", ");
  const fields = type.fields.map((field) => (
    `  fields.set(${JSON.stringify(field.name)}, `
    + `__zappEncode${zWireCodecSuffix(field.type)}(`
    + `${moved(field.type, field.name, copyableTypes)}));`
  )).join("\n");
  return `function __zappEncode${generatedName(type.name)}(
  value: ${type.name}
): JsonValue {
  const { ${names} } = move value;
  let fields = Map<String, JsonValue>();
${fields}
  return JsonValue.object(move fields);
}`;
}

function renderInputDecode(method: ZServiceMethodMetadata): string {
  if (!method.input) return "";
  return `  const __parsed = attempt json.parse(in invocation.arguments);
  const __arguments = match (__parsed) {
    success(value) => value;
    failure(error) => return ServiceOutcome.failure(
      \`INVALID_ARGUMENTS: ${"${error.message}"}\`
    );
  };
  const __decoded = attempt __zappDecode${zWireCodecSuffix(method.input)}(
    in __arguments
  );
  const input = match (__decoded) {
    success(value) => value;
    failure(error) => return ServiceOutcome.failure(
      \`INVALID_ARGUMENTS: ${"${error.message}"}\`
    );
  };
`;
}

function renderSyncMethodHelper(
  serviceName: string,
  serviceType: string,
  method: ZServiceMethodMetadata,
  copyableTypes: ReadonlySet<string>,
): string {
  if (method.receiverMode !== "in") {
    throw new Error(
      `[zapp] generated repeatable service dispatch requires an in receiver for `
      + `${serviceType}.${method.name}, not ${method.receiverMode}`,
    );
  }
  if (method.asynchronous || method.executorAffinity === "thread.main") {
    throw new Error(
      `[zapp] internal dispatcher generation routed suspending method `
      + `${serviceType}.${method.name} through its synchronous branch`,
    );
  }
  const call = `service.${method.name}(${inputCall(method, copyableTypes)})`;
  const invocation = method.error
    ? `  const __called = attempt ${call};
  const result = match (__called) {
    success(value) => value;
    failure(error) => {
      const encodedError = __zappEncode${zWireCodecSuffix(method.error)}(move error);
      return ServiceOutcome.typedFailure(ServiceTypedFailure({
        service: ${JSON.stringify(serviceName)},
        method: ${JSON.stringify(method.name)},
        errorType: ${JSON.stringify(method.error)},
        message: ${JSON.stringify(`${serviceName}.${method.name} threw ${method.error}`)},
        details: json.stringify(in encodedError),
      }));
    }
  };`
    : `  const result = ${call};`;
  const decode = renderInputDecode(method);
  return `function __zappDispatch${generatedName(serviceType)}${generatedName(method.name)}(
  in service: ${serviceType},
  in invocation: ServiceInvocation
): ServiceOutcome {
${decode}${invocation}
  const encoded = __zappEncode${zWireCodecSuffix(method.returns)}(
    ${moved(method.returns, "result", copyableTypes)}
  );
  return ServiceOutcome.success(json.stringify(in encoded));
}`;
}

function renderSyncMethodBranch(
  serviceType: string,
  method: ZServiceMethodMetadata,
): string {
  return `  // Static method ID: ${method.id}
  if (invocation.method == ${JSON.stringify(method.name)}) {
    return __zappDispatch${generatedName(serviceType)}${generatedName(method.name)}(
      in service,
      in invocation
    );
  }`;
}

function renderAsyncMethodHelpers(
  serviceName: string,
  serviceType: string,
  method: ZServiceMethodMetadata,
  copyableTypes: ReadonlySet<string>,
): string {
  if (method.receiverMode !== "in") {
    throw new Error(
      `[zapp] generated repeatable service dispatch requires an in receiver for `
      + `${serviceType}.${method.name}, not ${method.receiverMode}`,
    );
  }
  const suffix = `${generatedName(serviceType)}${generatedName(method.name)}`;
  const decode = renderInputDecode(method);
  const directCall = `service.${method.name}(${inputCall(method, copyableTypes)})`;
  const synchronousPlacement = method.executorAffinity === "thread.main"
    && !method.asynchronous;
  const placementInput = method.input
    ? `, ${moved(method.input, "input", copyableTypes)}`
    : "";
  const call = synchronousPlacement
    ? `__zappCall${suffix}OnMain(move service${placementInput})`
    : directCall;
  const throws = method.error ? ` throws ${method.error}` : "";
  const wrapperParameters = method.input
    ? `,\n  input: ${method.input}`
    : "";
  const wrapperInvocation = method.error ? `try ${directCall}` : directCall;
  const wrapperBody = method.returns === "void"
    ? `  ${wrapperInvocation};\n  return;`
    : `  return ${wrapperInvocation};`;
  const placementWrapper = synchronousPlacement
    ? `async function __zappCall${suffix}OnMain(\n  service: ${serviceType}${wrapperParameters}\n): ${method.returns}${throws} on thread.main {\n${wrapperBody}\n}\n\n`
    : "";
  const awaited = method.executorAffinity === "thread.main"
    ? `await on thread.main ${call}`
    : `await ${call}`;
  const invocation = method.error
    ? `  const __called = attempt ${awaited};
  const methodResult = match (__called) {
    success(value) => value;
    failure(error) => {
      const encodedError = __zappEncode${zWireCodecSuffix(method.error)}(move error);
      return ServiceOutcome.typedFailure(ServiceTypedFailure({
        service: ${JSON.stringify(serviceName)},
        method: ${JSON.stringify(method.name)},
        errorType: ${JSON.stringify(method.error)},
        message: ${JSON.stringify(`${serviceName}.${method.name} threw ${method.error}`)},
        details: json.stringify(in encodedError),
      }));
    }
  };`
    : `  const methodResult = ${awaited};`;
  const encode = `  const encoded = __zappEncode${zWireCodecSuffix(method.returns)}(
    ${moved(method.returns, "methodResult", copyableTypes)}
  );
  return ServiceOutcome.success(json.stringify(in encoded));`;
  return `${placementWrapper}async function __zappFinish${suffix}(
  service: ${serviceType},
  in invocation: ServiceInvocation
): ServiceOutcome {
${decode}${invocation}
${encode}
}`;
}

function renderDispatcher(
  service: ZServiceManifest["services"][number],
  copyableTypes: ReadonlySet<string>,
): string {
  assertIdentifier(service.name, "service name");
  assertIdentifier(service.type, "service type");
  const asyncDispatch = zServiceUsesAsyncDispatch(service);
  if (asyncDispatch && service.kind !== "class") {
    throw new Error(
      `[zapp] generated async service adapters currently require a class service; `
      + `${service.type} is a ${service.kind}`,
    );
  }
  const asynchronous = service.methods.filter((method) => (
    method.asynchronous || method.executorAffinity === "thread.main"
  ));
  const synchronous = service.methods.filter((method) => !asynchronous.includes(method));
  const helpers = [
    ...synchronous.map((method) => renderSyncMethodHelper(
      service.name,
      service.type,
      method,
      copyableTypes,
    )),
    ...asynchronous.map((method) => renderAsyncMethodHelpers(
      service.name,
      service.type,
      method,
      copyableTypes,
    )),
  ]
    .join("\n\n");
  const asyncMethodType = `__Zapp${generatedName(service.type)}AsyncMethod`;
  const asyncSelection = asynchronous.length > 0
    ? `type ${asyncMethodType} = async (
  service: ${service.type},
  in invocation: ServiceInvocation
) => ServiceOutcome;

function __zappSelect${generatedName(service.type)}AsyncMethod(
  in invocation: ServiceInvocation
): Option<${asyncMethodType}> {
${asynchronous.map((method) => `  // Static method ID: ${method.id}
  if (invocation.method == ${JSON.stringify(method.name)}) {
    const handler: ${asyncMethodType} = async (
      service: ${service.type},
      in invocation: ServiceInvocation
    ): ServiceOutcome => await __zappFinish${generatedName(service.type)}${generatedName(
      method.name,
    )}(move service, in invocation);
    return Option.some(move handler);
  }`).join("\n")}
  return Option<${asyncMethodType}>.none;
}`
    : "";
  const asyncTail = asynchronous.length > 0
    ? `  const selected = __zappSelect${generatedName(service.type)}AsyncMethod(
    in invocation
  );
  match (selected) {
    some(handler) => return await handler(move service, in invocation);
    none => return ServiceOutcome.failure("UNKNOWN_METHOD");
  }`
    : `${asynchronous.map((method) => `  // Static method ID: ${method.id}
  if (invocation.method == ${JSON.stringify(method.name)}) {
    return await __zappFinish${generatedName(service.type)}${generatedName(
      method.name,
    )}(move service);
  }`).join("\n")}
  return ServiceOutcome.failure("UNKNOWN_METHOD");`;
  const adapter = `__Zapp${generatedName(service.name)}ServiceAdapter`;
  const lifecycle = service.lifecycle
    ? `

  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    try this.service.start(in context);
  }

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main {
    try this.service.stop(in context);
  }`
    : "";
  const serviceTrait = asyncDispatch ? "AsyncService" : "Service";
  const implemented = service.lifecycle
    ? `${serviceTrait}, ServiceLifecycle`
    : serviceTrait;
  const invokeFunction = asyncDispatch
    ? `async function __zappInvoke${generatedName(service.name)}(
  service: ${service.type},
  in invocation: ServiceInvocation
): ServiceOutcome {
${synchronous.map((method) => renderSyncMethodBranch(service.type, method)).join("\n")}
${asyncTail}
}`
    : `function __zappInvoke${generatedName(service.name)}(
  in service: ${service.type},
  in invocation: ServiceInvocation
): ServiceOutcome {
${synchronous.map((method) => renderSyncMethodBranch(service.type, method)).join("\n")}
  return ServiceOutcome.failure("UNKNOWN_METHOD");
}`;
  const invokeMethod = asyncDispatch
    ? `  async function invoke(
    in invocation: ServiceInvocation
  ): ServiceOutcome {
    const target = this.service;
    return await __zappInvoke${generatedName(service.name)}(
      move target,
      in invocation
    );
  }`
    : `  function invoke(
    in invocation: ServiceInvocation
  ): ServiceOutcome {
    const target = this.service;
    return __zappInvoke${generatedName(service.name)}(
      in target,
      in invocation
    );
  }`;
  return `${helpers}${helpers ? "\n\n" : ""}${asyncSelection}${asyncSelection ? "\n\n" : ""}${invokeFunction}

export readonly class ${adapter} implements ${implemented} {
  readonly service: ${service.type};

${invokeMethod}${lifecycle}
}

export function ${zServiceAdapterFactoryName(service.name)}(
  service: ${service.type}
): ${adapter} {
  return new ${adapter}({ service: ${service.kind === "class" ? "move service" : "service"} });
}`;
}

export function renderZServiceDispatchers(
  manifest: ZServiceManifest,
  options: RenderZServiceDispatchersOptions,
): string {
  if (manifest.schemaVersion !== 5) {
    throw new Error(`[zapp] unsupported Z service metadata schema ${manifest.schemaVersion}`);
  }
  assertZServiceCodecNames(manifest);
  const allTypes = [...manifest.types, ...manifest.errors];
  const namedTypes = new Map(allTypes.map((type) => [type.name, type]));
  const enumTypes = new Map(manifest.enums.map((enumeration) => (
    [enumeration.name, enumeration]
  )));
  const enumNames = new Set(enumTypes.keys());
  const copyableTypes = zWireCopyableTypes(manifest, namedTypes, enumTypes);
  const decoded = new Set<string>();
  const encoded = new Set<string>();
  for (const service of manifest.services) {
    for (const method of service.methods) {
      if (method.input) collectZWireType(method.input, namedTypes, enumTypes, decoded);
      collectZWireType(method.returns, namedTypes, enumTypes, encoded);
      if (method.error) collectZWireType(method.error, namedTypes, enumTypes, encoded);
    }
  }

  const imports = new Map<string, Set<string>>();
  const addImport = (module: string, name: string): void => {
    const names = imports.get(module) ?? new Set<string>();
    names.add(name);
    imports.set(module, names);
  };
  for (const service of manifest.services) addImport(service.module, service.type);
  for (const type of allTypes) {
    if (decoded.has(type.name) || encoded.has(type.name)) addImport(type.module, type.name);
  }
  for (const enumeration of manifest.enums) {
    if (decoded.has(enumeration.name) || encoded.has(enumeration.name)) {
      addImport(enumeration.module, enumeration.name);
    }
  }
  const nativeImports = [...imports.entries()].sort(([left], [right]) => left.localeCompare(right))
    .map(([module, names]) => (
      `import { ${[...names].sort().join(", ")} } from `
      + `${JSON.stringify(relativeModule(options.outputPath, module))};`
    )).join("\n");

  const scalarDecoders = [...decoded]
    .filter((type) => (
      !namedTypes.has(type) && !enumNames.has(type)
      && !zArrayElementType(type) && !zOptionPayloadType(type)
    ))
    .sort()
    .map(renderZDecodeScalar);
  const arrayDecoders = [...decoded]
    .filter((type) => zArrayElementType(type))
    .map(renderZDecodeArray);
  const optionDecoders = [...decoded]
    .filter((type) => zOptionPayloadType(type))
    .map((type) => renderZDecodeOption(type, copyableTypes));
  const enumDecoders = manifest.enums
    .filter((enumeration) => decoded.has(enumeration.name))
    .map((enumeration) => renderZDecodeEnum(enumeration, copyableTypes));
  const typeDecoders = allTypes
    .filter((type) => decoded.has(type.name))
    .map((type) => renderZDecodeType(type, copyableTypes));
  const scalarEncoders = [...encoded]
    .filter((type) => (
      !namedTypes.has(type) && !enumNames.has(type)
      && !zArrayElementType(type) && !zOptionPayloadType(type)
    ))
    .sort()
    .map(renderZEncodeScalar);
  const arrayEncoders = [...encoded]
    .filter((type) => zArrayElementType(type))
    .map((type) => renderZEncodeArray(type, copyableTypes));
  const optionEncoders = [...encoded]
    .filter((type) => zOptionPayloadType(type))
    .map((type) => renderZEncodeOption(type, copyableTypes));
  const enumEncoders = manifest.enums
    .filter((enumeration) => encoded.has(enumeration.name))
    .map((enumeration) => renderZEncodeEnum(enumeration, copyableTypes));
  const typeEncoders = allTypes
    .filter((type) => encoded.has(type.name))
    .map((type) => renderZEncodeType(type, copyableTypes));

  return `// AUTO-GENERATED from checked Z service metadata. Do not edit.
import json from "std/json";
import { JsonNumber, JsonValue } from "std/json";
import { Map } from "std/collections";
import { thread } from "std/thread";
import { ServiceInvocation, ServiceOutcome, ServiceTypedFailure } from ${JSON.stringify(
    relativeModule(options.outputPath, options.serviceContractModule),
  )};
${manifest.services.some((service) => !zServiceUsesAsyncDispatch(service))
    ? `import { Service } from ${JSON.stringify(
      relativeModule(options.outputPath, options.servicesModule),
    )};`
    : ""}
${manifest.services.some(zServiceUsesAsyncDispatch)
    ? `import { AsyncService } from ${JSON.stringify(
    relativeModule(options.outputPath, options.asyncServiceContractModule),
  )};`
    : ""}
${manifest.services.some((service) => service.lifecycle)
    ? `import {
  ApplicationContext,
  ServiceLifecycle,
  ServiceLifecycleError,
} from ${JSON.stringify(
      relativeModule(options.outputPath, options.serviceLifecycleContractModule),
    )};`
    : ""}
${nativeImports}

struct __ZappServiceCodecError {
  message: String;
}

function __zappCodecError(message: String): __ZappServiceCodecError {
  return __ZappServiceCodecError({ message: move message });
}

${[
    ...scalarDecoders,
    ...enumDecoders,
    ...typeDecoders,
    ...arrayDecoders,
    ...optionDecoders,
    ...scalarEncoders,
    ...enumEncoders,
    ...typeEncoders,
    ...arrayEncoders,
    ...optionEncoders,
  ].join("\n\n")}

${manifest.services.map((service) => renderDispatcher(service, copyableTypes)).join("\n\n")}
`;
}

export async function generateZServiceDispatchers(
  manifest: ZServiceManifest,
  options: RenderZServiceDispatchersOptions,
): Promise<string> {
  await mkdir(path.dirname(options.outputPath), { recursive: true });
  await writeFile(
    options.outputPath,
    renderZServiceDispatchers(manifest, options),
    "utf8",
  );
  return options.outputPath;
}
