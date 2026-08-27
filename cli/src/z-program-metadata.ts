import type { ZServiceManifest, ZServiceTypeMetadata } from "./z-service-bindings";

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
}

interface ZProgramSymbolMetadata {
  name: string;
  kind: string;
  exported: boolean;
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
  seen: Set<string>,
): void {
  if (scalarTypes.has(name) || seen.has(name)) return;
  const { module, symbol } = publicType(metadata, name);
  if (symbol.kind !== "struct" || !symbol.typeSignature) {
    throw new Error(
      `[zapp] service wire type ${JSON.stringify(name)} must be an exported Z struct`,
    );
  }
  seen.add(name);
  const fields = symbol.typeSignature.fields.map((field) => {
    if (field.visibility !== "public") {
      throw new Error(
        `[zapp] service wire type ${name} contains private field ${JSON.stringify(field.name)}`,
      );
    }
    if (field.optionalField) {
      throw new Error(
        `[zapp] optional service wire field ${name}.${field.name} is not supported yet`,
      );
    }
    return { name: field.name, type: field.typeName };
  });
  for (const field of fields) addWireType(metadata, field.type, types, seen);
  types.push({ name, module: module.path, fields });
}

export function deriveZServiceManifest(metadata: ZProgramMetadata): ZServiceManifest {
  const registrations = metadata.modules.flatMap((module) => (
    module.calls.filter((call) => (
      call.target.symbol === "ApplicationServicesBuilder"
      && call.target.kind === "method"
      && (
        call.target.name === "ApplicationServicesBuilder.register"
        || call.target.name === "ApplicationServicesBuilder.registerWithLifecycle"
        || call.target.name === "ApplicationServicesBuilder.registerAsync"
        || call.target.name === "ApplicationServicesBuilder.registerAsyncWithLifecycle"
      )
    )).map((call) => ({ call, module }))
  ));
  const types: ZServiceTypeMetadata[] = [];
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
      if (method.signature.errorType !== null) {
        throw new Error(`[zapp] throwing service method ${serviceType}.${method.name} is not supported yet`);
      }
      if (method.signature.parameterTypes.length > 1) {
        throw new Error(
          `[zapp] service method ${serviceType}.${method.name} must accept zero or one request value`,
        );
      }
      if (method.signature.returnType === "void") {
        throw new Error(`[zapp] void service method ${serviceType}.${method.name} is not supported yet`);
      }
      const input = method.signature.parameterTypes[0];
      if (input) addWireType(metadata, input, types, seenTypes);
      addWireType(metadata, method.signature.returnType, types, seenTypes);
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
  return { schemaVersion: 2, types, services };
}

export function zServiceMethodId(qualifiedName: string): number {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(qualifiedName)) {
    hash = Math.imul(hash ^ byte, 0x01000193);
  }
  return hash >>> 0;
}
