import path from "node:path";
import { mkdir, writeFile } from "node:fs/promises";

export interface ZServiceFieldMetadata {
  name: string;
  type: string;
}

export interface ZServiceTypeMetadata {
  name: string;
  module: string;
  fields: ZServiceFieldMetadata[];
}

export interface ZServiceMethodMetadata {
  id: number;
  name: string;
  input?: string;
  inputMode?: string;
  returns: string;
  error?: string;
  asynchronous: boolean;
  executorAffinity: string | null;
  receiverMode: "in" | "inout" | "move";
}

export interface ZServiceMetadata {
  name: string;
  type: string;
  kind: "struct" | "class";
  module: string;
  lifecycle: boolean;
  registration: {
    module: string;
    offset: number;
    line: number;
    column: number;
    method: string;
  };
  methods: ZServiceMethodMetadata[];
}

export interface ZServiceManifest {
  schemaVersion: 3;
  types: ZServiceTypeMetadata[];
  errors: ZServiceTypeMetadata[];
  services: ZServiceMetadata[];
}

const identifier = /^[A-Za-z_$][A-Za-z0-9_$]*$/;

function assertIdentifier(value: string, description: string): void {
  if (!identifier.test(value)) {
    throw new Error(`[zapp] ${description} ${JSON.stringify(value)} is not a valid identifier`);
  }
}

export function zArrayElementType(type: string): string | null {
  if (!type.startsWith("Array<") || !type.endsWith(">")) return null;
  const element = type.slice("Array<".length, -1).trim();
  if (element.length === 0) {
    throw new Error("[zapp] Array service wire types require an element type");
  }
  let depth = 0;
  for (const character of element) {
    if (character === "<") depth += 1;
    if (character === ">") depth -= 1;
    if (depth < 0) {
      throw new Error(`[zapp] malformed service wire type ${JSON.stringify(type)}`);
    }
  }
  if (depth !== 0) {
    throw new Error(`[zapp] malformed service wire type ${JSON.stringify(type)}`);
  }
  return element;
}

export function zWireCodecSuffix(type: string): string {
  const element = zArrayElementType(type);
  if (element) return `ArrayOf${zWireCodecSuffix(element)}`;
  assertIdentifier(type, "service type");
  return type[0].toUpperCase() + type.slice(1);
}

function tsType(type: string): string {
  const element = zArrayElementType(type);
  if (element) return `Array<${tsType(element)}>`;
  if (type === "String") return "string";
  if (type === "boolean") return "boolean";
  if (type === "u64" || type === "i64") return "bigint";
  if (/^[ui](8|16|32)$/.test(type) || type === "usize" || type === "f64") {
    return "number";
  }
  assertIdentifier(type, "service type");
  return type;
}

function codecName(type: string, operation: "decode" | "encode"): string {
  if (type === "String") return `${operation}String`;
  if (type === "boolean") return `${operation}Boolean`;
  if (type === "u64") return `${operation}U64`;
  if (type === "i64") return `${operation}I64`;
  if (/^[ui](8|16|32)$/.test(type) || type === "usize" || type === "f64") {
    return `${operation}Number`;
  }
  return `${operation}${zWireCodecSuffix(type)}`;
}

function collectArrayType(type: string, selected: Set<string>): void {
  const element = zArrayElementType(type);
  if (!element) return;
  collectArrayType(element, selected);
  selected.add(type);
}

function manifestArrayTypes(manifest: ZServiceManifest): string[] {
  const selected = new Set<string>();
  for (const type of [...manifest.types, ...manifest.errors]) {
    for (const field of type.fields) collectArrayType(field.type, selected);
  }
  for (const service of manifest.services) {
    for (const method of service.methods) {
      if (method.input) collectArrayType(method.input, selected);
      collectArrayType(method.returns, selected);
      if (method.error) collectArrayType(method.error, selected);
    }
  }
  return [...selected];
}

export function assertZServiceCodecNames(manifest: ZServiceManifest): void {
  const owners = new Map<string, string>([
    ["String", "built-in String"],
    ["Boolean", "built-in boolean"],
    ["Number", "built-in number"],
    ["U64", "built-in u64"],
    ["I64", "built-in i64"],
  ]);
  const wireTypes = [
    ...manifest.types.map((type) => type.name),
    ...manifest.errors.map((type) => type.name),
    ...manifestArrayTypes(manifest),
  ];
  for (const type of wireTypes) {
    const suffix = zWireCodecSuffix(type);
    const previous = owners.get(suffix);
    if (previous && previous !== type) {
      throw new Error(
        `[zapp] service wire types ${JSON.stringify(previous)} and ${JSON.stringify(type)} `
        + `produce the same generated codec name ${JSON.stringify(suffix)}`,
      );
    }
    owners.set(suffix, type);
  }
}

function renderArrayCodecs(manifest: ZServiceManifest): string {
  return manifestArrayTypes(manifest).map((type) => {
    const element = zArrayElementType(type)!;
    const suffix = zWireCodecSuffix(type);
    return `function decode${suffix}(value: unknown): ${tsType(type)} {
  if (!Array.isArray(value)) throw new TypeError("expected an array from Z service");
  return value.map(${codecName(element, "decode")});
}

function encode${suffix}(value: ${tsType(type)}): unknown[] {
  return value.map(${codecName(element, "encode")});
}`;
  }).join("\n\n");
}

function renderTypes(manifest: ZServiceManifest): string {
  return manifest.types.map((type) => {
    assertIdentifier(type.name, "service type");
    const fields = type.fields.map((field) => {
      assertIdentifier(field.name, `${type.name} field`);
      return `  ${field.name}: ${tsType(field.type)};`;
    }).join("\n");
    return `export interface ${type.name} {\n${fields}\n}`;
  }).join("\n\n");
}

function renderErrorTypes(manifest: ZServiceManifest): string {
  return manifest.errors.map((type) => {
    assertIdentifier(type.name, "service error type");
    const details = `${type.name}Details`;
    const fields = type.fields.map((field) => {
      assertIdentifier(field.name, `${type.name} field`);
      return `  ${field.name}: ${tsType(field.type)};`;
    }).join("\n");
    const defaultMessage = type.fields.some((field) => (
      field.name === "message" && field.type === "String"
    ))
      ? "details.message"
      : JSON.stringify(`Z service threw ${type.name}`);
    return `export interface ${details} {\n${fields}\n}\n\n`
      + `export class ${type.name} extends ZappError {\n`
      + `  readonly details: ${details};\n\n`
      + `  constructor(details: ${details}, message?: string) {\n`
      + `    super({\n`
      + `      code: "SERVICE_ERROR",\n`
      + `      message: message ?? ${defaultMessage},\n`
      + `    });\n`
      + `    this.name = ${JSON.stringify(type.name)};\n`
      + `    this.details = details;\n`
      + `  }\n`
      + `}`;
  }).join("\n\n");
}

function renderNamedCodecs(types: ZServiceTypeMetadata[]): string {
  return types.map((type) => {
    const decodeFields = type.fields.map((field) =>
      `    ${field.name}: ${codecName(field.type, "decode")}(record.${field.name}),`
    ).join("\n");
    const encodeFields = type.fields.map((field) =>
      `    ${field.name}: ${codecName(field.type, "encode")}(value.${field.name}),`
    ).join("\n");
    return `function decode${type.name}(value: unknown): ${type.name} {
  const record = decodeRecord(value);
  return {
${decodeFields}
  };
}

function encode${type.name}(value: ${type.name}): unknown {
  return {
${encodeFields}
  };
}`;
  }).join("\n\n");
}

function renderErrorCodecs(manifest: ZServiceManifest): string {
  return manifest.errors.map((type) => {
    const decoded = type.fields.map((field) =>
      `    ${field.name}: ${codecName(field.type, "decode")}(record.${field.name}),`
    ).join("\n");
    const encoded = type.fields.map((field) =>
      `    ${field.name}: ${codecName(field.type, "encode")}(value.details.${field.name}),`
    ).join("\n");
    return `function decode${type.name}Details(value: unknown): ${type.name}Details {
  const record = decodeRecord(value);
  return {
${decoded}
  };
}

function decode${type.name}(value: unknown): ${type.name} {
  return new ${type.name}(decode${type.name}Details(value));
}

function encode${type.name}(value: ${type.name}): unknown {
  return {
${encoded}
  };
}`;
  }).join("\n\n");
}

function errorDecoderName(method: ZServiceMethodMetadata): string {
  return method.error ? `decode${method.error}Failure` : "undefined";
}

function renderMethodErrorDecoders(manifest: ZServiceManifest): string {
  const errors = new Map(manifest.errors.map((error) => [error.name, error]));
  return [...new Set(manifest.services.flatMap((service) => (
    service.methods.flatMap((method) => method.error ? [method.error] : [])
  )))].map((name) => {
    const errorType = errors.get(name);
    if (!errorType) {
      throw new Error(`[zapp] missing service error metadata for ${JSON.stringify(name)}`);
    }
    const message = errorType.fields.some((field) => (
      field.name === "message" && field.type === "String"
    )) ? "details.message" : "error.message";
    return `function decode${name}Failure(error: unknown): Error {
  if (error instanceof ZappInvocationError && error.errorType === ${JSON.stringify(name)}) {
    const details = decode${name}Details(error.details);
    return new ${name}(details, ${message});
  }
  return error instanceof Error ? error : new Error(String(error));
}`;
  }).join("\n\n");
}

function renderService(service: ZServiceMetadata): string {
  assertIdentifier(service.name, "service name");
  const methods = service.methods.map((method) => {
    assertIdentifier(method.name, `${service.name} method`);
    const parameter = method.input
      ? `input: ${tsType(method.input)}, options?: InvokeOptions`
      : "options?: InvokeOptions";
    const argumentsValue = method.input
      ? `${codecName(method.input, "encode")}(input)`
      : "{}";
    return `  ${method.name}(${parameter}): CancellablePromise<${tsType(method.returns)}> {
    return mapCall(
      Services.invoke<unknown, unknown>(
        ${JSON.stringify(`${service.name}.${method.name}`)},
        ${argumentsValue},
        options,
      ),
      ${codecName(method.returns, "decode")},
      ${errorDecoderName(method)},
    );
  },`;
  }).join("\n\n");
  return `export const ${service.name} = {\n${methods}\n};`;
}

export function renderZServiceBindings(manifest: ZServiceManifest): string {
  if (manifest.schemaVersion !== 3) {
    throw new Error(`[zapp] unsupported Z service metadata schema ${manifest.schemaVersion}`);
  }
  assertZServiceCodecNames(manifest);
  return `// AUTO-GENERATED from Z service metadata. Do not edit.
import {
  Services,
  ZappError,
  ZappInvocationError,
  type CancellablePromise,
  type InvokeOptions,
} from "@zappdev/runtime";

${renderTypes(manifest)}

${renderErrorTypes(manifest)}

function decodeRecord(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("Z service returned an object with an invalid wire shape");
  }
  return value as Record<string, unknown>;
}

function decodeString(value: unknown): string {
  if (typeof value !== "string") throw new TypeError("expected a string from Z service");
  return value;
}

function encodeString(value: string): string { return value; }
function decodeBoolean(value: unknown): boolean {
  if (typeof value !== "boolean") throw new TypeError("expected a boolean from Z service");
  return value;
}
function encodeBoolean(value: boolean): boolean { return value; }
function decodeNumber(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError("expected a finite number from Z service");
  }
  return value;
}
function encodeNumber(value: number): number {
  if (!Number.isFinite(value)) throw new TypeError("Z service numbers must be finite");
  return value;
}
function decodeU64(value: unknown): bigint {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new TypeError("expected an exact u64 string from Z service");
  }
  return BigInt(value);
}
function encodeU64(value: bigint): string { return value.toString(); }
function decodeI64(value: unknown): bigint {
  if (typeof value !== "string" || !/^-?(0|[1-9][0-9]*)$/.test(value)) {
    throw new TypeError("expected an exact i64 string from Z service");
  }
  return BigInt(value);
}
function encodeI64(value: bigint): string { return value.toString(); }

function mapCall<T>(
  source: CancellablePromise<unknown>,
  decode: (value: unknown) => T,
  decodeError?: (error: unknown) => Error,
): CancellablePromise<T> {
  const mapped = source.then(
    decode,
    (error) => { throw decodeError ? decodeError(error) : error; },
  ) as CancellablePromise<T>;
  mapped.cancel = () => source.cancel();
  return mapped;
}

${renderNamedCodecs(manifest.types)}

${renderArrayCodecs(manifest)}

${renderErrorCodecs(manifest)}

${renderMethodErrorDecoders(manifest)}

${manifest.services.map(renderService).join("\n\n")}
`;
}

function renderRuntimeCodecs(manifest: ZServiceManifest): string {
  const named = [...manifest.types, ...manifest.errors].map((type) => {
    const decoded = type.fields.map((field) =>
      `${JSON.stringify(field.name)}: ${codecName(field.type, "decode")}(value[${JSON.stringify(field.name)}])`
    ).join(", ");
    const encoded = type.fields.map((field) =>
      `${JSON.stringify(field.name)}: ${codecName(field.type, "encode")}(value[${JSON.stringify(field.name)}])`
    ).join(", ");
    return `  const decode${type.name} = value => ({ ${decoded} });\n`
      + `  const encode${type.name} = value => ({ ${encoded} });`;
  }).join("\n");
  const arrays = manifestArrayTypes(manifest).map((type) => {
    const element = zArrayElementType(type)!;
    const suffix = zWireCodecSuffix(type);
    return `  const decode${suffix} = value => {
    if (!Array.isArray(value)) throw new TypeError("expected an array from Z service");
    return value.map(${codecName(element, "decode")});
  };\n`
      + `  const encode${suffix} = value => value.map(${codecName(element, "encode")});`;
  }).join("\n");
  return `  const decodeString = value => value;
  const encodeString = value => value;
  const decodeBoolean = value => value;
  const encodeBoolean = value => value;
  const decodeNumber = value => value;
  const encodeNumber = value => value;
  const decodeU64 = value => BigInt(value);
  const encodeU64 = value => value.toString();
  const decodeI64 = value => BigInt(value);
  const encodeI64 = value => value.toString();
${named}
${arrays}`;
}

export function renderZServiceWebviewRuntime(manifest: ZServiceManifest): string {
  assertZServiceCodecNames(manifest);
  const services = manifest.services.map((service) => {
    const methods = service.methods.map((method) => {
      const parameter = method.input ? "input, options" : "options";
      const argumentsValue = method.input
        ? `${codecName(method.input, "encode")}(input)`
        : "{}";
      return `${JSON.stringify(method.name)}: (${parameter}) => map(
        bridge.invoke(${JSON.stringify(`${service.name}.${method.name}`)}, ${argumentsValue}, options),
        ${codecName(method.returns, "decode")},
        ${method.error ? `error => {
          if (error && error.errorType === ${JSON.stringify(method.error)}) {
            error.name = ${JSON.stringify(method.error)};
            error.details = decode${method.error}(error.details);
            if (typeof error.details?.message === "string") {
              error.message = error.details.message;
            }
          }
          return error;
        }` : "undefined"},
      )`;
    }).join(",\n");
    return `${JSON.stringify(service.name)}: {\n${methods}\n}`;
  }).join(",\n");
  return `
(() => {
  const bridge = globalThis[Symbol.for("zapp.bridge")];
  const map = (source, decode, decodeError) => {
    const mapped = source.then(decode, error => {
      throw decodeError ? decodeError(error) : error;
    });
    mapped.cancel = () => source.cancel();
    return mapped;
  };
${renderRuntimeCodecs(manifest)}
  globalThis.__zappServices = {
${services}
  };
})();
`;
}

export async function generateZServiceBindings(
  manifest: ZServiceManifest,
  outputDirectory: string,
): Promise<string> {
  await mkdir(outputDirectory, { recursive: true });
  const output = path.join(outputDirectory, "services.ts");
  await writeFile(output, renderZServiceBindings(manifest), "utf8");
  return output;
}
