import {
  zArrayElementType,
  zOptionPayloadType,
  type ZServiceEnumMetadata,
  type ZServiceManifest,
  type ZServiceTypeMetadata,
} from "./z-service-bindings";

interface ZProgramFieldMetadata {
  name: string;
  typeName: string;
  visibility: "public" | "private";
  optionalField: boolean;
}

interface ZProgramFunctionSignature {
  asynchronous: boolean;
  executorAffinity: string | null;
  parameterModes: string[];
  parameterTypes: string[];
  returnType: string;
  errorType: string | null;
}

interface ZProgramMethodMetadata {
  name: string;
  staticMethod: boolean;
  visibility: "public" | "private";
  receiverMode: "in" | "inout" | "move";
  signature: ZProgramFunctionSignature;
}

interface ZProgramTypeSignature {
  implementedTraits: string[];
  fields: ZProgramFieldMetadata[];
  methods: ZProgramMethodMetadata[];
  variants?: {
    name: string;
    payloadType: string | null;
  }[];
}

interface ZProgramSymbolMetadata {
  name: string;
  kind: string;
  exported: boolean;
  importedName: string;
  typeSignature: ZProgramTypeSignature | null;
}

interface ZProgramArgumentMetadata {
  kind: "string" | "number" | "boolean" | "null" | "other";
  type: string;
  value?: string | boolean | null;
}

interface ZProgramCallMetadata {
  offset: number;
  line: number;
  column: number;
  target: {
    module: string;
    symbol: string;
    kind: string;
    name: string;
  };
  arguments: ZProgramArgumentMetadata[];
}

interface ZProgramModuleMetadata {
  path: string;
  symbols: ZProgramSymbolMetadata[];
  calls: ZProgramCallMetadata[];
}

export interface ZProgramMetadata {
  schemaVersion: 1;
  entry: number;
  modules: ZProgramModuleMetadata[];
}

export interface ZWorkerProtocolManifest {
  schemaVersion: 1;
  workerId: string;
  module: string;
  protocolType: string;
  commandType: string;
  messageType: string;
  types: ZServiceTypeMetadata[];
  enums: ZServiceEnumMetadata[];
}

export interface ZWorkerProtocolUse {
  workerId: string;
  module: string;
  offset: number;
}

const scalarTypes = new Set([
  "String",
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

function object(value: unknown, description: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`[zapp] ${description} must be an object`);
  }
  return value as Record<string, unknown>;
}

export function parseZProgramMetadata(source: string): ZProgramMetadata {
  const parsed = object(JSON.parse(source), "Z program metadata");
  if (parsed.schemaVersion !== 1) {
    throw new Error(
      `[zapp] unsupported Z program metadata schema ${JSON.stringify(parsed.schemaVersion)}`,
    );
  }
  if (!Number.isInteger(parsed.entry) || !Array.isArray(parsed.modules)) {
    throw new Error("[zapp] malformed Z program metadata root");
  }
  for (const [moduleIndex, moduleValue] of parsed.modules.entries()) {
    const module = object(moduleValue, `Z program metadata module ${moduleIndex}`);
    if (
      typeof module.path !== "string"
      || !Array.isArray(module.symbols)
      || !Array.isArray(module.calls)
    ) {
      throw new Error(`[zapp] malformed Z program metadata module ${moduleIndex}`);
    }
    for (const [symbolIndex, symbolValue] of module.symbols.entries()) {
      const symbol = object(
        symbolValue,
        `Z program metadata module ${moduleIndex} symbol ${symbolIndex}`,
      );
      if (symbol.typeSignature === null) continue;
      const typeSignature = object(
        symbol.typeSignature,
        `Z program metadata module ${moduleIndex} symbol ${symbolIndex} type signature`,
      );
      if (!Array.isArray(typeSignature.methods)) {
        throw new Error(
          `[zapp] malformed Z program metadata module ${moduleIndex} symbol ${symbolIndex} methods`,
        );
      }
      for (const [methodIndex, methodValue] of typeSignature.methods.entries()) {
        const method = object(
          methodValue,
          `Z program metadata module ${moduleIndex} symbol ${symbolIndex} method ${methodIndex}`,
        );
        const signature = object(
          method.signature,
          `Z program metadata module ${moduleIndex} symbol ${symbolIndex} method ${methodIndex} signature`,
        );
        if (
          !(
            method.receiverMode === "in"
            || method.receiverMode === "inout"
            || method.receiverMode === "move"
          )
          ||
          typeof signature.asynchronous !== "boolean"
          || !(
            signature.executorAffinity === null
            || typeof signature.executorAffinity === "string"
          )
        ) {
          throw new Error(
            `[zapp] malformed Z program metadata module ${moduleIndex} symbol ${symbolIndex} `
            + `method ${methodIndex} execution contract`,
          );
        }
      }
    }
  }
  return parsed as unknown as ZProgramMetadata;
}

function publicType(
  metadata: ZProgramMetadata,
  name: string,
): { module: ZProgramModuleMetadata; symbol: ZProgramSymbolMetadata } {
  const matches = metadata.modules.flatMap((module) => (
    module.symbols
      .filter((symbol) => symbol.exported && symbol.name === name && symbol.typeSignature !== null)
      .map((symbol) => ({ module, symbol }))
  ));
  if (matches.length === 0) {
    throw new Error(
      `[zapp] public service wire type ${JSON.stringify(name)} is not exported from the checked Z program`,
    );
  }
  if (matches.length > 1) {
    throw new Error(
      `[zapp] public service wire type ${JSON.stringify(name)} is ambiguous across Z modules`,
    );
  }
  return matches[0];
}

function addWireType(
  metadata: ZProgramMetadata,
  name: string,
  types: ZServiceTypeMetadata[],
  enums: ZServiceEnumMetadata[],
  seen: Set<string>,
): void {
  if (scalarTypes.has(name) || seen.has(name)) return;
  const arrayElement = zArrayElementType(name);
  if (arrayElement) {
    addWireType(metadata, arrayElement, types, enums, seen);
    return;
  }
  const optionPayload = zOptionPayloadType(name);
  if (optionPayload) {
    addWireType(metadata, optionPayload, types, enums, seen);
    return;
  }
  if (name.includes("<") || name.includes(">")) {
    throw new Error(
      `[zapp] generic service wire type ${JSON.stringify(name)} is not supported yet; `
      + "Array<T> and Option<T> are the supported generic wire shapes",
    );
  }
  const { module, symbol } = publicType(metadata, name);
  if (symbol.kind === "enum" && symbol.typeSignature) {
    const variants = symbol.typeSignature.variants;
    if (!variants) {
      throw new Error(`[zapp] malformed enum metadata for service wire type ${JSON.stringify(name)}`);
    }
    seen.add(name);
    for (const variant of variants) {
      if (variant.payloadType) {
        addWireType(metadata, variant.payloadType, types, enums, seen);
      }
    }
    enums.push({
      name,
      module: module.path,
      variants: variants.map((variant) => ({
        name: variant.name,
        ...(variant.payloadType ? { payload: variant.payloadType } : {}),
      })),
    });
    return;
  }
  if (symbol.kind !== "struct" || !symbol.typeSignature) {
    throw new Error(
      `[zapp] service wire type ${JSON.stringify(name)} must be an exported Z struct `
      + "or enum",
    );
  }
  seen.add(name);
  const fields = symbol.typeSignature.fields.map((field) => {
    if (field.visibility !== "public") {
      throw new Error(
        `[zapp] service wire type ${name} contains private field ${JSON.stringify(field.name)}`,
      );
    }
    return field.optionalField
      ? {
        name: field.name,
        type: zOptionPayloadType(field.typeName)
          ? field.typeName
          : `Option<${field.typeName}>`,
        optional: true,
      }
      : { name: field.name, type: field.typeName };
  });
  for (const field of fields) addWireType(metadata, field.type, types, enums, seen);
  types.push({ name, module: module.path, fields });
}

export function deriveZServiceManifest(
  metadata: ZProgramMetadata,
  registrationMethod = "ApplicationServices.register",
): ZServiceManifest {
  const separator = registrationMethod.lastIndexOf(".");
  if (separator <= 0 || separator === registrationMethod.length - 1) {
    throw new Error(
      `[zapp] invalid Z service registration method ${JSON.stringify(registrationMethod)}`,
    );
  }
  const registrationSymbol = registrationMethod.slice(0, separator);
  const registrations = metadata.modules.flatMap((module) => (
    module.calls.filter((call) => (
      call.target.symbol === registrationSymbol
      && call.target.kind === "method"
      && call.target.name === registrationMethod
    )).map((call) => ({ call, module }))
  ));
  const types: ZServiceTypeMetadata[] = [];
  const enums: ZServiceEnumMetadata[] = [];
  const errorNames = new Set<string>();
  const seenTypes = new Set<string>();
  const seenServices = new Set<string>();
  const methodIds = new Map<number, string>();
  const services = registrations.map(({ call: registration, module: registrationModule }) => {
    const [nameArgument, serviceArgument] = registration.arguments;
    if (registration.arguments.length !== 2 || nameArgument?.kind !== "string") {
      throw new Error(
        "[zapp] service registration requires a literal service name and one checked service value",
      );
    }
    const name = nameArgument.value;
    if (typeof name !== "string" || name.length === 0) {
      throw new Error("[zapp] a registered Z service name cannot be empty");
    }
    if (seenServices.has(name)) {
      throw new Error(`[zapp] duplicate registered Z service ${JSON.stringify(name)}`);
    }
    seenServices.add(name);
    const serviceType = serviceArgument.type;
    const { module: serviceModule, symbol: service } = publicType(metadata, serviceType);
    const serviceKind = service.kind;
    if ((serviceKind !== "struct" && serviceKind !== "class") || !service.typeSignature) {
      throw new Error(
        `[zapp] registered service ${JSON.stringify(serviceType)} must be an exported Z struct or class`,
      );
    }
    const kind: "struct" | "class" = serviceKind;
    const implementsService = service.typeSignature.implementedTraits
      .includes("Service");
    const implementsAsyncService = service.typeSignature.implementedTraits
      .includes("AsyncService");
    const implementsLifecycle = service.typeSignature.implementedTraits
      .includes("ServiceLifecycle");
    const methods = service.typeSignature.methods.filter((method) => (
      method.visibility === "public"
      && !method.staticMethod
      && !(
        implementsService
        && method.name === "invoke"
        && !method.signature.asynchronous
        && method.signature.parameterModes.length === 1
        && method.signature.parameterModes[0] === "in"
        && method.signature.parameterTypes.length === 1
        && method.signature.parameterTypes[0] === "ServiceInvocation"
        && method.signature.returnType === "ServiceOutcome"
        && method.signature.errorType === null
      )
      && !(
        implementsAsyncService
        && method.name === "invoke"
        && method.signature.asynchronous
        && method.signature.parameterModes.length === 1
        && method.signature.parameterModes[0] === "in"
        && method.signature.parameterTypes.length === 1
        && method.signature.parameterTypes[0] === "ServiceInvocation"
        && method.signature.returnType === "ServiceOutcome"
        && method.signature.errorType === null
      )
      && !(
        implementsLifecycle
        && (method.name === "start" || method.name === "stop")
        && !method.signature.asynchronous
        && method.signature.parameterModes.length === 1
        && method.signature.parameterModes[0] === "in"
        && method.signature.parameterTypes.length === 1
        && method.signature.parameterTypes[0] === "ApplicationContext"
        && method.signature.returnType === "void"
        && method.signature.errorType === "ServiceLifecycleError"
      )
    )).map((method) => {
      if (method.signature.parameterTypes.length > 1) {
        throw new Error(
          `[zapp] service method ${serviceType}.${method.name} must accept zero or one request value`,
        );
      }
      if (method.signature.returnType === "void") {
        throw new Error(`[zapp] void service method ${serviceType}.${method.name} is not supported yet`);
      }
      const input = method.signature.parameterTypes[0];
      if (input) addWireType(metadata, input, types, enums, seenTypes);
      addWireType(metadata, method.signature.returnType, types, enums, seenTypes);
      const error = method.signature.errorType ?? undefined;
      if (error) {
        if (scalarTypes.has(error)) {
          throw new Error(
            `[zapp] service error ${JSON.stringify(error)} for ${serviceType}.${method.name} `
            + "must be an exported Z struct so its payload can cross the WebView boundary",
          );
        }
        const { symbol: errorSymbol } = publicType(metadata, error);
        if (errorSymbol.kind !== "struct") {
          throw new Error(
            `[zapp] service error ${JSON.stringify(error)} for ${serviceType}.${method.name} `
            + "must be an exported Z struct",
          );
        }
        addWireType(metadata, error, types, enums, seenTypes);
        errorNames.add(error);
      }
      const qualifiedName = `${name}.${method.name}`;
      const methodId = zServiceMethodId(qualifiedName);
      const collision = methodIds.get(methodId);
      if (collision && collision !== qualifiedName) {
        throw new Error(
          `[zapp] service method ID collision between ${JSON.stringify(collision)} `
          + `and ${JSON.stringify(qualifiedName)}; rename one method`,
        );
      }
      methodIds.set(methodId, qualifiedName);
      return {
        id: methodId,
        name: method.name,
        ...(input ? { input } : {}),
        ...(input ? { inputMode: method.signature.parameterModes[0] } : {}),
        returns: method.signature.returnType,
        ...(error ? { error } : {}),
        asynchronous: method.signature.asynchronous,
        executorAffinity: method.signature.executorAffinity,
        receiverMode: method.receiverMode,
      };
    });
    if (methods.length === 0) {
      throw new Error(`[zapp] registered service ${serviceType} has no public instance methods`);
    }
    return {
      name,
      type: serviceType,
      kind,
      module: serviceModule.path,
      lifecycle: implementsLifecycle,
      registration: {
        module: registrationModule.path,
        offset: registration.offset,
        line: registration.line,
        column: registration.column,
        method: registration.target.name,
      },
      methods,
    };
  });
  const errors = types.filter((type) => errorNames.has(type.name));
  const values = types.filter((type) => !errorNames.has(type.name));
  return { schemaVersion: 5, types: values, enums, errors, services };
}

function workerProtocolArguments(typeName: string): [string, string] | null {
  const prefix = "WorkerProtocol<";
  if (!typeName.startsWith(prefix) || !typeName.endsWith(">")) return null;
  const body = typeName.slice(prefix.length, -1);
  let depth = 0;
  for (let index = 0; index < body.length; index += 1) {
    const character = body[index];
    if (character === "<") depth += 1;
    else if (character === ">") depth -= 1;
    else if (character === "," && depth === 0) {
      const command = body.slice(0, index).trim();
      const message = body.slice(index + 1).trim();
      return command.length > 0 && message.length > 0
        ? [command, message]
        : null;
    }
    if (depth < 0) return null;
  }
  return null;
}

/** Derive one checked worker protocol from an exported marker alias. */
export function deriveZWorkerProtocolManifest(
  metadata: ZProgramMetadata,
  workerId: string,
  modulePath: string,
  protocolType: string,
): ZWorkerProtocolManifest {
  const normalizedModule = modulePath.replaceAll("\\", "/");
  const module = metadata.modules.find((candidate) => (
    candidate.path.replaceAll("\\", "/") === normalizedModule
  ));
  if (!module) {
    throw new Error(
      `[zapp] worker ${JSON.stringify(workerId)} protocol module `
      + `${JSON.stringify(modulePath)} was not present in checked Z metadata`,
    );
  }
  const aliases = module.symbols.filter((symbol) => (
    symbol.name === protocolType && symbol.exported && symbol.kind === "type"
  ));
  if (aliases.length !== 1) {
    throw new Error(
      `[zapp] worker ${JSON.stringify(workerId)} protocol type `
      + `${JSON.stringify(protocolType)} must be one exported Z type alias`,
    );
  }
  const arguments_ = workerProtocolArguments(aliases[0].importedName);
  if (!arguments_) {
    throw new Error(
      `[zapp] worker ${JSON.stringify(workerId)} protocol type `
      + `${JSON.stringify(protocolType)} must alias WorkerProtocol<Command, Message>`,
    );
  }
  const [commandType, messageType] = arguments_;
  if (commandType.includes("<") || messageType.includes("<")) {
    throw new Error(
      `[zapp] worker ${JSON.stringify(workerId)} protocol roots must be named exported enums`,
    );
  }
  const types: ZServiceTypeMetadata[] = [];
  const enums: ZServiceEnumMetadata[] = [];
  const seen = new Set<string>();
  addWireType(metadata, commandType, types, enums, seen);
  addWireType(metadata, messageType, types, enums, seen);
  for (const [role, name] of [
    ["command", commandType],
    ["message", messageType],
  ] as const) {
    if (!enums.some((enumeration) => enumeration.name === name)) {
      throw new Error(
        `[zapp] worker ${JSON.stringify(workerId)} ${role} type `
        + `${JSON.stringify(name)} must be an exported Z enum`,
      );
    }
  }
  return {
    schemaVersion: 1,
    workerId,
    module: module.path,
    protocolType,
    commandType,
    messageType,
    types,
    enums,
  };
}

/** Resolve typed WorkerManager.get(marker) calls to configured protocols. */
export function deriveZWorkerProtocolUses(
  metadata: ZProgramMetadata,
  protocols: readonly ZWorkerProtocolManifest[],
): ZWorkerProtocolUse[] {
  const byShape = new Map<string, ZWorkerProtocolManifest[]>();
  for (const protocol of protocols) {
    const key = `${protocol.commandType}\0${protocol.messageType}`;
    const entries = byShape.get(key) ?? [];
    entries.push(protocol);
    byShape.set(key, entries);
  }
  return metadata.modules.flatMap((module) => module.calls
    .filter((call) => (
      call.target.symbol === "WorkerManager"
      && call.target.kind === "method"
      && call.target.name === "WorkerManager.get"
    ))
    .map((call) => {
      if (call.arguments.length !== 1) {
        throw new Error("[zapp] typed WorkerManager.get requires one WorkerProtocol marker");
      }
      const shape = workerProtocolArguments(call.arguments[0].type);
      if (!shape) {
        throw new Error(
          "[zapp] typed WorkerManager.get requires a WorkerProtocol<Command, Message> marker",
        );
      }
      const matches = byShape.get(`${shape[0]}\0${shape[1]}`) ?? [];
      if (matches.length === 0) {
        throw new Error(
          `[zapp] no configured application worker uses protocol `
          + `WorkerProtocol<${shape[0]}, ${shape[1]}>`,
        );
      }
      if (matches.length > 1) {
        throw new Error(
          `[zapp] protocol WorkerProtocol<${shape[0]}, ${shape[1]}> is configured for `
          + `${matches.map((match) => JSON.stringify(match.workerId)).join(", ")}; `
          + "typed lookup currently requires one configured worker per protocol",
        );
      }
      return {
        workerId: matches[0].workerId,
        module: module.path,
        offset: call.offset,
      };
    }));
}

export function zServiceMethodId(qualifiedName: string): number {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(qualifiedName)) {
    hash = Math.imul(hash ^ byte, 0x01000193);
  }
  return hash >>> 0;
}
