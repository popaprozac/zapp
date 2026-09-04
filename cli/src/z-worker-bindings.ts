import path from "node:path";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import type { ZWorkerProtocolManifest } from "./z-program-metadata";
import {
  assertZServiceCodecNames,
  renderZWireContainerCodecs,
  renderZWireEnumCodecs,
  renderZWireEnums,
  renderZWireNamedCodecs,
  renderZWireTypes,
  zTsWireType,
  zWireCodecName,
  type ZServiceManifest,
} from "./z-service-bindings";

const identifier = /^[A-Za-z_$][A-Za-z0-9_$]*$/;

function assertIdentifier(value: string, description: string): void {
  if (!identifier.test(value)) {
    throw new Error(`[zapp] ${description} ${JSON.stringify(value)} is not a valid identifier`);
  }
}

export function combinedWorkerWireManifest(
  protocols: readonly ZWorkerProtocolManifest[],
): ZServiceManifest {
  const types = new Map<string, ZWorkerProtocolManifest["types"][number]>();
  const enums = new Map<string, ZWorkerProtocolManifest["enums"][number]>();
  const owners = new Map<string, string>();
  for (const protocol of protocols) {
    for (const value of [...protocol.types, ...protocol.enums]) {
      const owner = owners.get(value.name);
      if (owner && owner !== protocol.module) {
        throw new Error(
          `[zapp] worker protocol wire type ${JSON.stringify(value.name)} is exported by both `
          + `${JSON.stringify(owner)} and ${JSON.stringify(protocol.module)}; rename one type`,
        );
      }
      owners.set(value.name, protocol.module);
    }
    for (const value of protocol.types) types.set(value.name, value);
    for (const value of protocol.enums) enums.set(value.name, value);
  }
  return {
    schemaVersion: 5,
    types: [...types.values()],
    enums: [...enums.values()],
    errors: [],
    services: [],
  };
}

function protocolEnum(
  manifest: ZServiceManifest,
  name: string,
): ZServiceManifest["enums"][number] {
  const enumeration = manifest.enums.find((value) => value.name === name);
  if (!enumeration) throw new Error(`[zapp] missing worker protocol enum ${JSON.stringify(name)}`);
  return enumeration;
}

function renderCommands(
  protocol: ZWorkerProtocolManifest,
  manifest: ZServiceManifest,
): string {
  const command = protocolEnum(manifest, protocol.commandType);
  return command.variants.map((variant) => {
    assertIdentifier(variant.name, `${protocol.workerId} command`);
    if (!variant.payload) {
      return `    ${variant.name}(options?: InvokeOptions): CancellablePromise<void> {
      return applicationWorkers.get(${JSON.stringify(protocol.workerId)}).send(
        ${JSON.stringify(variant.name)},
        null,
        options,
      );
    },`;
    }
    return `    ${variant.name}(
      input: ${zTsWireType(variant.payload)},
      options?: InvokeOptions,
    ): CancellablePromise<void> {
      return applicationWorkers.get(${JSON.stringify(protocol.workerId)}).send(
        ${JSON.stringify(variant.name)},
        ${zWireCodecName(variant.payload, "encode")}(input),
        options,
      );
    },`;
  }).join("\n\n");
}

function renderMessageSubscription(
  protocol: ZWorkerProtocolManifest,
  manifest: ZServiceManifest,
): string {
  const message = protocolEnum(manifest, protocol.messageType);
  const subscriptions = message.variants.map((variant) => {
    assertIdentifier(variant.name, `${protocol.workerId} message`);
    const value = variant.payload
      ? `{ kind: ${JSON.stringify(variant.name)}, value: `
        + `${zWireCodecName(variant.payload, "decode")}(data) }`
      : `{ kind: ${JSON.stringify(variant.name)} }`;
    return `        worker.subscribe(${JSON.stringify(variant.name)}, (data) => handler(${value}))`;
  }).join(",\n");
  return `    subscribe(
      handler: (message: ${protocol.messageType}) => void,
    ): ApplicationWorkerSubscription {
      const worker = applicationWorkers.get(${JSON.stringify(protocol.workerId)});
      return combineSubscriptions([
${subscriptions}
      ]);
    },`;
}

function renderWorker(
  protocol: ZWorkerProtocolManifest,
  manifest: ZServiceManifest,
): string {
  assertIdentifier(protocol.workerId, "typed worker ID");
  return `export const ${protocol.workerId} = {
  commands: {
${renderCommands(protocol, manifest)}
  },
  messages: {
${renderMessageSubscription(protocol, manifest)}
  },
};`;
}

function generatedName(value: string): string {
  assertIdentifier(value, "generated worker symbol");
  return value[0].toUpperCase() + value.slice(1);
}

function renderWorkerDefinition(
  protocol: ZWorkerProtocolManifest,
  manifest: ZServiceManifest,
): string {
  const command = protocolEnum(manifest, protocol.commandType);
  const message = protocolEnum(manifest, protocol.messageType);
  const prefix = generatedName(protocol.workerId);
  const messageMethods = message.variants.map((variant) => {
    assertIdentifier(variant.name, `${protocol.workerId} message`);
    return variant.payload
      ? `  ${variant.name}(value: ${zTsWireType(variant.payload)}): void;`
      : `  ${variant.name}(): void;`;
  }).join("\n");
  const messageImplementations = message.variants.map((variant) => {
    if (!variant.payload) {
      return `  ${variant.name}(): void {
    __zappWorkerSend(${JSON.stringify(variant.name)}, "null");
  },`;
    }
    return `  ${variant.name}(value: ${zTsWireType(variant.payload)}): void {
    __zappWorkerSend(
      ${JSON.stringify(variant.name)},
      JSON.stringify(${zWireCodecName(variant.payload, "encode")}(value)),
    );
  },`;
  }).join("\n");
  const commandMethods = command.variants.map((variant) => (
    variant.payload
      ? `  ${variant.name}(
    input: ${zTsWireType(variant.payload)},
    messages: ${prefix}Messages,
  ): void;`
      : `  ${variant.name}(messages: ${prefix}Messages): void;`
  )).join("\n");
  const commandCases = command.variants.map((variant) => (
    variant.payload
      ? `      case ${JSON.stringify(variant.name)}:
        handlers.${variant.name}(
          ${zWireCodecName(variant.payload, "decode")}(decodeWorkerPayload(payload)),
          ${protocol.workerId}Messages,
        );
        return true;`
      : `      case ${JSON.stringify(variant.name)}:
        handlers.${variant.name}(${protocol.workerId}Messages);
        return true;`
  )).join("\n");
  return `export interface ${prefix}Messages {
${messageMethods}
}

export interface ${prefix}Worker {
${commandMethods}
}

const ${protocol.workerId}Messages: ${prefix}Messages = {
${messageImplementations}
};

export function define${prefix}Worker(
  handlers: ${prefix}Worker,
): (channel: string, payload: string) => boolean {
  return (channel, payload) => {
    switch (channel) {
${commandCases}
      default:
        return false;
    }
  };
}`;
}

export function renderZWorkerBindings(
  protocols: readonly ZWorkerProtocolManifest[],
): string {
  const manifest = combinedWorkerWireManifest(protocols);
  assertZServiceCodecNames(manifest);
  return `// AUTO-GENERATED from checked Z worker protocols. Do not edit.
import {
  applicationWorkers,
  type ApplicationWorkerSubscription,
} from "@zappdev/runtime/worker";
import type {
  CancellablePromise,
  InvokeOptions,
} from "@zappdev/runtime/service";

declare function __zappWorkerSend(channel: string, payload: string): void;

${renderZWireTypes(manifest)}

${renderZWireEnums(manifest)}

function decodeRecord(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("Z worker message has an invalid object wire shape");
  }
  return value as Record<string, unknown>;
}

function decodeString(value: unknown): string {
  if (typeof value !== "string") throw new TypeError("expected a string from Z worker");
  return value;
}
function encodeString(value: string): string { return value; }
function decodeBoolean(value: unknown): boolean {
  if (typeof value !== "boolean") throw new TypeError("expected a boolean from Z worker");
  return value;
}
function encodeBoolean(value: boolean): boolean { return value; }
function decodeNumber(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError("expected a finite number from Z worker");
  }
  return value;
}
function encodeNumber(value: number): number {
  if (!Number.isFinite(value)) throw new TypeError("Z worker numbers must be finite");
  return value;
}
function decodeU64(value: unknown): bigint {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new TypeError("expected an exact u64 string from Z worker");
  }
  return BigInt(value);
}
function encodeU64(value: bigint): string { return value.toString(); }
function decodeI64(value: unknown): bigint {
  if (typeof value !== "string" || !/^-?(0|[1-9][0-9]*)$/.test(value)) {
    throw new TypeError("expected an exact i64 string from Z worker");
  }
  return BigInt(value);
}
function encodeI64(value: bigint): string { return value.toString(); }

function decodeWorkerPayload(payload: string): unknown {
  try {
    return JSON.parse(payload);
  } catch {
    throw new TypeError("Z worker command payload is not valid JSON");
  }
}

${renderZWireNamedCodecs(manifest.types)}

${renderZWireEnumCodecs(manifest)}

${renderZWireContainerCodecs(manifest)}

function combineSubscriptions(
  subscriptions: ApplicationWorkerSubscription[],
): ApplicationWorkerSubscription {
  let active = true;
  return {
    unsubscribe(): void {
      if (!active) return;
      active = false;
      for (const subscription of subscriptions) subscription.unsubscribe();
    },
  };
}

${protocols.map((protocol) => renderWorker(protocol, manifest)).join("\n\n")}

${protocols.map((protocol) => renderWorkerDefinition(protocol, manifest)).join("\n\n")}
`;
}

export async function generateZWorkerBindings(
  protocols: readonly ZWorkerProtocolManifest[],
  outputDirectory: string,
): Promise<string> {
  await mkdir(outputDirectory, { recursive: true });
  const output = path.join(outputDirectory, "workers.ts");
  const source = renderZWorkerBindings(protocols);
  let current: string | undefined;
  try {
    current = await readFile(output, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  if (current !== source) await writeFile(output, source, "utf8");
  return output;
}
