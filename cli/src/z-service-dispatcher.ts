import path from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import type {
  ZServiceManifest,
  ZServiceMethodMetadata,
  ZServiceTypeMetadata,
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

function moved(type: string, expression: string): string {
  return copiedScalars.has(type) ? expression : `move ${expression}`;
}

function inputCall(method: ZServiceMethodMetadata): string {
  if (!method.input) return "";
  if (method.inputMode === "value") return "move input";
  if (method.inputMode === "in") return "in input";
  throw new Error(
    `[zapp] generated WebView dispatch does not support ${method.inputMode ?? "missing"} `
    + `input capability for method ${JSON.stringify(method.name)}`,
  );
}

function collectType(
  type: string,
  namedTypes: Map<string, ZServiceTypeMetadata>,
  selected: Set<string>,
): void {
  if (selected.has(type)) return;
  selected.add(type);
  const named = namedTypes.get(type);
  if (!named) return;
  for (const field of named.fields) collectType(field.type, namedTypes, selected);
}

function renderDecodeScalar(type: string): string {
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
  throw new Error(
    `[zapp] generated Z dispatch does not decode scalar ${JSON.stringify(type)} yet`,
  );
}

function renderEncodeScalar(type: string): string {
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

function renderDecodeType(type: ZServiceTypeMetadata): string {
  const fields = type.fields.map((field) => {
    assertIdentifier(field.name, `${type.name} field`);
    return `        const __field_${field.name} = fields.get(${JSON.stringify(field.name)});
        const ${field.name} = match (in __field_${field.name}) {
          some(field) => try __zappDecode${generatedName(field.type)}(in field);
          none => throw __zappCodecError(${JSON.stringify(`missing required field ${field.name}`)});
        };`;
  }).join("\n");
  const initialization = type.fields
    .map((field) => `          ${field.name}: ${moved(field.type, field.name)},`)
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

function renderEncodeType(type: ZServiceTypeMetadata): string {
  const names = type.fields.map((field) => field.name).join(", ");
  const fields = type.fields.map((field) => (
    `  fields.set(${JSON.stringify(field.name)}, `
    + `__zappEncode${generatedName(field.type)}(${moved(field.type, field.name)}));`
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

function renderSyncMethodHelper(
  serviceName: string,
  serviceType: string,
  method: ZServiceMethodMetadata,
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
  const call = `service.${method.name}(${inputCall(method)})`;
  const invocation = method.error
    ? `  const __called = attempt ${call};
  const result = match (__called) {
    success(value) => value;
    failure(error) => {
      const encodedError = __zappEncode${generatedName(method.error)}(move error);
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
  const decode = method.input
    ? `    const __parsed = attempt json.parse(in invocation.arguments);
    const __arguments = match (__parsed) {
      success(value) => value;
      failure(error) => return ServiceOutcome.failure(
        \`INVALID_ARGUMENTS: ${"${error.message}"}\`
      );
    };
    const __decoded = attempt __zappDecode${generatedName(method.input)}(
      in __arguments
    );
    const input = match (__decoded) {
      success(value) => value;
      failure(error) => return ServiceOutcome.failure(
        \`INVALID_ARGUMENTS: ${"${error.message}"}\`
      );
    };
`
    : "";
  return `function __zappDispatch${generatedName(serviceType)}${generatedName(method.name)}(
  in service: ${serviceType},
  in invocation: ServiceInvocation
): ServiceOutcome {
${decode}${invocation}
  const encoded = __zappEncode${generatedName(method.returns)}(
    ${moved(method.returns, "result")}
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
  serviceType: string,
  method: ZServiceMethodMetadata,
): string {
  if (method.error) {
    throw new Error(
      `[zapp] generated async Z dispatch cannot lower throwing method `
      + `${serviceType}.${method.name} in the current fixed-point compiler tier`,
    );
  }
  if (method.receiverMode !== "in") {
    throw new Error(
      `[zapp] generated repeatable service dispatch requires an in receiver for `
      + `${serviceType}.${method.name}, not ${method.receiverMode}`,
    );
  }
  if (method.input) {
    throw new Error(
      `[zapp] generated async Z dispatch does not carry request values across `
      + `suspension for ${serviceType}.${method.name} yet`,
    );
  }
  const suffix = `${generatedName(serviceType)}${generatedName(method.name)}`;
  const encode = `  const encoded = __zappEncode${generatedName(method.returns)}(
    ${moved(method.returns, "methodResult")}
  );
  return ServiceOutcome.success(json.stringify(in encoded));`;
  if (method.executorAffinity === "thread.main") {
    return `async function __zappCall${suffix}(
  service: ${serviceType}
): ${method.returns} {
  return await on thread.main service.${method.name}();
}

async function __zappFinish${suffix}(
  service: ${serviceType}
): ServiceOutcome {
  const methodResult = await __zappCall${suffix}(move service);
${encode}
}`;
  }
  return `async function __zappFinish${suffix}(
  service: ${serviceType}
): ServiceOutcome {
  const methodResult = await service.${method.name}();
${encode}
}`;
}

function renderDispatcher(
  service: ZServiceManifest["services"][number],
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
    ...synchronous.map((method) => renderSyncMethodHelper(service.name, service.type, method)),
    ...asynchronous.map((method) => renderAsyncMethodHelpers(service.type, method)),
  ]
    .join("\n\n");
  const asyncMethodType = `__Zapp${generatedName(service.type)}AsyncMethod`;
  const asyncSelection = asynchronous.length > 0
    ? `type ${asyncMethodType} = async (
  service: ${service.type}
) => ServiceOutcome;

function __zappSelect${generatedName(service.type)}AsyncMethod(
  in invocation: ServiceInvocation
): Option<${asyncMethodType}> {
${asynchronous.map((method) => `  // Static method ID: ${method.id}
  if (invocation.method == ${JSON.stringify(method.name)}) {
    const handler: ${asyncMethodType} = async (
      service: ${service.type}
    ): ServiceOutcome => await __zappFinish${generatedName(service.type)}${generatedName(
      method.name,
    )}(move service);
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
    some(handler) => return await handler(move service);
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
  if (manifest.schemaVersion !== 3) {
    throw new Error(`[zapp] unsupported Z service metadata schema ${manifest.schemaVersion}`);
  }
  const allTypes = [...manifest.types, ...manifest.errors];
  const namedTypes = new Map(allTypes.map((type) => [type.name, type]));
  const decoded = new Set<string>();
  const encoded = new Set<string>();
  for (const service of manifest.services) {
    for (const method of service.methods) {
      if (method.input) collectType(method.input, namedTypes, decoded);
      collectType(method.returns, namedTypes, encoded);
      if (method.error) collectType(method.error, namedTypes, encoded);
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
  const nativeImports = [...imports.entries()].sort(([left], [right]) => left.localeCompare(right))
    .map(([module, names]) => (
      `import { ${[...names].sort().join(", ")} } from `
      + `${JSON.stringify(relativeModule(options.outputPath, module))};`
    )).join("\n");

  const scalarDecoders = [...decoded]
    .filter((type) => !namedTypes.has(type))
    .sort()
    .map(renderDecodeScalar);
  const typeDecoders = allTypes
    .filter((type) => decoded.has(type.name))
    .map(renderDecodeType);
  const scalarEncoders = [...encoded]
    .filter((type) => !namedTypes.has(type))
    .sort()
    .map(renderEncodeScalar);
  const typeEncoders = allTypes
    .filter((type) => encoded.has(type.name))
    .map(renderEncodeType);

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

${[...scalarDecoders, ...typeDecoders, ...scalarEncoders, ...typeEncoders].join("\n\n")}

${manifest.services.map(renderDispatcher).join("\n\n")}
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
