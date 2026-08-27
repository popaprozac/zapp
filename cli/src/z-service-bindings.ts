import path from "node:path";
import { mkdir, writeFile } from "node:fs/promises";

export interface ZServiceFieldMetadata {
  name: string;
  type: string;
}

export interface ZServiceTypeMetadata {
  name: string;
  fields: ZServiceFieldMetadata[];
}

export interface ZServiceMethodMetadata {
  id: number;
  name: string;
  input?: string;
  returns: string;
  asynchronous: boolean;
  executorAffinity: string | null;
}

export interface ZServiceMetadata {
  name: string;
  type: string;
  methods: ZServiceMethodMetadata[];
}

export interface ZServiceManifest {
  schemaVersion: 2;
  types: ZServiceTypeMetadata[];
  services: ZServiceMetadata[];
}

const identifier = /^[A-Za-z_$][A-Za-z0-9_$]*$/;

function assertIdentifier(value: string, description: string): void {
  if (!identifier.test(value)) {
    throw new Error(`[zapp] ${description} ${JSON.stringify(value)} is not a valid identifier`);
  }
}

function tsType(type: string): string {
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
  assertIdentifier(type, "service type");
  return `${operation}${type}`;
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

function renderNamedCodecs(manifest: ZServiceManifest): string {
  return manifest.types.map((type) => {
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
    );
  },`;
  }).join("\n\n");
  return `export const ${service.name} = {\n${methods}\n};`;
}

export function renderZServiceBindings(manifest: ZServiceManifest): string {
  if (manifest.schemaVersion !== 2) {
    throw new Error(`[zapp] unsupported Z service metadata schema ${manifest.schemaVersion}`);
  }
  return `// AUTO-GENERATED from Z service metadata. Do not edit.
import { Services, type CancellablePromise, type InvokeOptions } from "@zappdev/runtime";

${renderTypes(manifest)}

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
): CancellablePromise<T> {
  const mapped = source.then(decode) as CancellablePromise<T>;
  mapped.cancel = () => source.cancel();
  return mapped;
}

${renderNamedCodecs(manifest)}

${manifest.services.map(renderService).join("\n\n")}
`;
}

function renderRuntimeCodecs(manifest: ZServiceManifest): string {
  const named = manifest.types.map((type) => {
    const decoded = type.fields.map((field) =>
      `${JSON.stringify(field.name)}: ${codecName(field.type, "decode")}(value[${JSON.stringify(field.name)}])`
    ).join(", ");
    const encoded = type.fields.map((field) =>
      `${JSON.stringify(field.name)}: ${codecName(field.type, "encode")}(value[${JSON.stringify(field.name)}])`
    ).join(", ");
    return `  const decode${type.name} = value => ({ ${decoded} });\n`
      + `  const encode${type.name} = value => ({ ${encoded} });`;
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
${named}`;
}

export function renderZServiceWebviewRuntime(manifest: ZServiceManifest): string {
  const services = manifest.services.map((service) => {
    const methods = service.methods.map((method) => {
      const parameter = method.input ? "input, options" : "options";
      const argumentsValue = method.input
        ? `${codecName(method.input, "encode")}(input)`
        : "{}";
      return `${JSON.stringify(method.name)}: (${parameter}) => map(
        bridge.invoke(${JSON.stringify(`${service.name}.${method.name}`)}, ${argumentsValue}, options),
        ${codecName(method.returns, "decode")}
      )`;
    }).join(",\n");
    return `${JSON.stringify(service.name)}: {\n${methods}\n}`;
  }).join(",\n");
  return `
(() => {
  const bridge = globalThis[Symbol.for("zapp.bridge")];
  const map = (source, decode) => {
    const mapped = source.then(decode);
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
