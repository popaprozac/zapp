import path from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import {
  zArrayElementType,
  zOptionPayloadType,
  zWireCodecSuffix,
  type ZServiceEnumMetadata,
  type ZServiceManifest,
  type ZServiceTypeMetadata,
} from "./z-service-bindings";
import {
  collectZWireType,
  renderZDecodeArray,
  renderZDecodeEnum,
  renderZDecodeOption,
  renderZDecodeScalar,
  renderZDecodeType,
  renderZEncodeArray,
  renderZEncodeEnum,
  renderZEncodeOption,
  renderZEncodeScalar,
  renderZEncodeType,
  zWireCopyableTypes,
} from "./z-service-dispatcher";
import { combinedWorkerWireManifest } from "./z-worker-bindings";
import type { ZWorkerProtocolManifest } from "./z-program-metadata";
import type { ZWorkerProtocolUse } from "./z-program-metadata";
import type { ZGeneratedBuildContribution } from "./z-service-registration";

const identifier = /^[A-Za-z_$][A-Za-z0-9_$]*$/;

export interface RenderZWorkerProtocolAdaptersOptions {
  outputPath: string;
  workerModule: string;
}

function assertIdentifier(value: string, description: string): void {
  if (!identifier.test(value)) {
    throw new Error(`[zapp] ${description} ${JSON.stringify(value)} is not a valid identifier`);
  }
}

function generatedName(value: string): string {
  assertIdentifier(value, "generated worker symbol");
  return value[0].toUpperCase() + value.slice(1);
}

export function zWorkerProtocolAdapterFactoryName(workerId: string): string {
  return `__zappAdapt${generatedName(workerId)}WorkerProtocol`;
}

export function zWorkerProtocolBuildContribution(
  protocols: readonly ZWorkerProtocolManifest[],
  uses: readonly ZWorkerProtocolUse[],
  generatedModule: string,
): ZGeneratedBuildContribution {
  const specifier = "zapp/generated/worker-protocols";
  const protocolsById = new Map(protocols.map((protocol) => [protocol.workerId, protocol]));
  return {
    modules: [{ specifier, source: generatedModule, packageName: "zapp" }],
    callAdapters: uses.map((use) => {
      const protocol = protocolsById.get(use.workerId);
      if (!protocol) {
        throw new Error(`[zapp] missing generated worker protocol ${JSON.stringify(use.workerId)}`);
      }
      return {
        source: use.module,
        offset: use.offset,
        target: "WorkerManager.get",
        replacement: "WorkerManager.getGenerated",
        argument: 0,
        adapterModule: specifier,
        adapterExport: zWorkerProtocolAdapterFactoryName(protocol.workerId),
      };
    }),
  };
}

function relativeModule(fromFile: string, target: string): string {
  let relative = path.relative(path.dirname(fromFile), target).replaceAll(path.sep, "/");
  if (!relative.startsWith(".")) relative = `./${relative}`;
  return relative;
}

function moved(type: string, expression: string, copyableTypes: ReadonlySet<string>): string {
  return copyableTypes.has(type) ? expression : `move ${expression}`;
}

function protocolEnum(
  manifest: ZServiceManifest,
  name: string,
): ZServiceEnumMetadata {
  const enumeration = manifest.enums.find((value) => value.name === name);
  if (!enumeration) throw new Error(`[zapp] missing worker protocol enum ${JSON.stringify(name)}`);
  return enumeration;
}

function renderCodecSupport(
  manifest: ZServiceManifest,
  protocols: readonly ZWorkerProtocolManifest[],
): { source: string; used: ReadonlySet<string>; copyable: ReadonlySet<string> } {
  const allTypes = [...manifest.types, ...manifest.errors];
  const namedTypes = new Map(allTypes.map((type) => [type.name, type]));
  const enumTypes = new Map(manifest.enums.map((enumeration) => (
    [enumeration.name, enumeration]
  )));
  const enumNames = new Set(enumTypes.keys());
  const copyable = zWireCopyableTypes(manifest, namedTypes, enumTypes);
  const decoded = new Set<string>();
  const encoded = new Set<string>();
  for (const protocol of protocols) {
    for (const variant of protocolEnum(manifest, protocol.commandType).variants) {
      if (variant.payload) collectZWireType(
        variant.payload,
        namedTypes,
        enumTypes,
        encoded,
      );
    }
    for (const variant of protocolEnum(manifest, protocol.messageType).variants) {
      if (variant.payload) collectZWireType(
        variant.payload,
        namedTypes,
        enumTypes,
        decoded,
      );
    }
  }
  const scalar = (type: string): boolean => (
    !namedTypes.has(type)
    && !enumNames.has(type)
    && !zArrayElementType(type)
    && !zOptionPayloadType(type)
  );
  const source = [
    ...[...decoded].filter(scalar).sort().map(renderZDecodeScalar),
    ...manifest.enums
      .filter((enumeration) => decoded.has(enumeration.name))
      .map((enumeration) => renderZDecodeEnum(enumeration, copyable)),
    ...allTypes
      .filter((type) => decoded.has(type.name))
      .map((type) => renderZDecodeType(type, copyable)),
    ...[...decoded]
      .filter((type) => zArrayElementType(type))
      .map(renderZDecodeArray),
    ...[...decoded]
      .filter((type) => zOptionPayloadType(type))
      .map((type) => renderZDecodeOption(type, copyable)),
    ...[...encoded].filter(scalar).sort().map(renderZEncodeScalar),
    ...manifest.enums
      .filter((enumeration) => encoded.has(enumeration.name))
      .map((enumeration) => renderZEncodeEnum(enumeration, copyable)),
    ...allTypes
      .filter((type) => encoded.has(type.name))
      .map((type) => renderZEncodeType(type, copyable)),
    ...[...encoded]
      .filter((type) => zArrayElementType(type))
      .map((type) => renderZEncodeArray(type, copyable)),
    ...[...encoded]
      .filter((type) => zOptionPayloadType(type))
      .map((type) => renderZEncodeOption(type, copyable)),
  ].join("\n\n");
  return { source, used: new Set([...decoded, ...encoded]), copyable };
}

function renderCommandEncoder(
  protocol: ZWorkerProtocolManifest,
  manifest: ZServiceManifest,
  copyable: ReadonlySet<string>,
): string {
  const command = protocolEnum(manifest, protocol.commandType);
  const arms = command.variants.map((variant) => {
    assertIdentifier(variant.name, `${protocol.workerId} command`);
    const pattern = variant.payload ? `${variant.name}(value)` : variant.name;
    if (variant.payload) {
      const encoded = `__zappEncode${zWireCodecSuffix(variant.payload)}(`
        + `${moved(variant.payload, "value", copyable)})`;
      return `    ${pattern} => {
      const encoded = ${encoded};
      select EncodedApplicationWorkerCommand({
        channel: ${JSON.stringify(variant.name)},
        payload: json.stringify(in encoded),
      });
    }`;
    }
    return `    ${pattern} => EncodedApplicationWorkerCommand({
      channel: ${JSON.stringify(variant.name)},
      payload: "null",
    });`;
  }).join("\n");
  return `function __zappEncode${generatedName(protocol.workerId)}Command(
  command: ${protocol.commandType}
): EncodedApplicationWorkerCommand {
  return match (command) {
${arms}
  };
}`;
}

function protocolFailure(
  messageExpression: string,
): string {
  return `__zappWorkerProtocolError(
          in message,
          ${messageExpression}
        )`;
}

function renderMessageDecoder(
  protocol: ZWorkerProtocolManifest,
  manifest: ZServiceManifest,
  copyable: ReadonlySet<string>,
): string {
  const message = protocolEnum(manifest, protocol.messageType);
  const branches = message.variants.map((variant) => {
    assertIdentifier(variant.name, `${protocol.workerId} message`);
    if (!variant.payload) {
      return `  if (message.channel == ${JSON.stringify(variant.name)}) {
    return ${protocol.messageType}.${variant.name};
  }`;
    }
    return `  if (message.channel == ${JSON.stringify(variant.name)}) {
    const parsed = attempt json.parse(in message.payload);
    const value = match (parsed) {
      success(value) => value;
      failure(error) => throw ${protocolFailure("copy error.message")};
    };
    const decoded = attempt __zappDecode${zWireCodecSuffix(variant.payload)}(in value);
    const payload = match (decoded) {
      success(value) => value;
      failure(error) => throw ${protocolFailure("copy error.message")};
    };
    return ${protocol.messageType}.${variant.name}(
      ${moved(variant.payload, "payload", copyable)}
    );
  }`;
  }).join("\n");
  return `function __zappDecode${generatedName(protocol.workerId)}Message(
  in message: ApplicationWorkerMessage
): ${protocol.messageType} throws ApplicationWorkerProtocolError {
${branches}
  throw __zappWorkerProtocolError(
    in message,
    \`unknown application worker channel ${"${message.channel}"}\`
  );
}`;
}

function renderMessageFilter(
  protocol: ZWorkerProtocolManifest,
  manifest: ZServiceManifest,
): string {
  const message = protocolEnum(manifest, protocol.messageType);
  const conditions = message.variants.map((variant) => (
    `message.channel == ${JSON.stringify(variant.name)}`
  )).join(" || ");
  return `function __zappAccepts${generatedName(protocol.workerId)}Message(
  in message: ApplicationWorkerMessage
): boolean {
  return ${conditions || "false"};
}`;
}

function renderAdapter(
  protocol: ZWorkerProtocolManifest,
  manifest: ZServiceManifest,
  copyable: ReadonlySet<string>,
): string {
  return `${renderCommandEncoder(protocol, manifest, copyable)}

${renderMessageFilter(protocol, manifest)}

${renderMessageDecoder(protocol, manifest, copyable)}

export function ${zWorkerProtocolAdapterFactoryName(protocol.workerId)}(
  marker: WorkerProtocol<${protocol.commandType}, ${protocol.messageType}>
): ApplicationWorkerProtocolAdapter<${protocol.commandType}, ${protocol.messageType}> {
  const encode = move (
    command: ${protocol.commandType}
  ): EncodedApplicationWorkerCommand =>
    __zappEncode${generatedName(protocol.workerId)}Command(move command);
  const accepts = move (
    in message: ApplicationWorkerMessage
  ): boolean => __zappAccepts${generatedName(protocol.workerId)}Message(
    in message
  );
  const decode = move (
    in message: ApplicationWorkerMessage
  ): Result<${protocol.messageType}, ApplicationWorkerProtocolError> =>
    attempt __zappDecode${generatedName(protocol.workerId)}Message(in message);
  return ApplicationWorkerProtocolAdapter<
    ${protocol.commandType},
    ${protocol.messageType}
  >({
    workerId: ${JSON.stringify(protocol.workerId)},
    marker,
    encode: move encode,
    accepts: move accepts,
    decode: move decode,
  });
}`;
}

export function renderZWorkerProtocolAdapters(
  protocols: readonly ZWorkerProtocolManifest[],
  options: RenderZWorkerProtocolAdaptersOptions,
): string {
  const manifest = combinedWorkerWireManifest(protocols);
  const codecs = renderCodecSupport(manifest, protocols);
  const imports = new Map<string, Set<string>>();
  const addImport = (module: string, name: string): void => {
    const names = imports.get(module) ?? new Set<string>();
    names.add(name);
    imports.set(module, names);
  };
  for (const protocol of protocols) {
    addImport(protocol.module, protocol.commandType);
    addImport(protocol.module, protocol.messageType);
  }
  for (const type of manifest.types) {
    if (codecs.used.has(type.name)) addImport(type.module, type.name);
  }
  for (const enumeration of manifest.enums) {
    if (codecs.used.has(enumeration.name)) addImport(enumeration.module, enumeration.name);
  }
  const nativeImports = [...imports.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([module, names]) => (
      `import { ${[...names].sort().join(", ")} } from `
      + `${JSON.stringify(relativeModule(options.outputPath, module))};`
    )).join("\n");
  return `// AUTO-GENERATED from checked Z worker protocols. Do not edit.
import json from "std/json";
import { JsonNumber, JsonValue } from "std/json";
import { Map } from "std/collections";
import {
  ApplicationWorkerMessage,
  ApplicationWorkerProtocolAdapter,
  ApplicationWorkerProtocolError,
  EncodedApplicationWorkerCommand,
  WorkerProtocol,
} from ${JSON.stringify(relativeModule(options.outputPath, options.workerModule))};
${nativeImports}

struct __ZappServiceCodecError {
  message: String;
}

function __zappCodecError(message: String): __ZappServiceCodecError {
  return __ZappServiceCodecError({ message: move message });
}

function __zappWorkerProtocolError(
  in message: ApplicationWorkerMessage,
  detail: String
): ApplicationWorkerProtocolError {
  return ApplicationWorkerProtocolError({
    workerId: copy message.workerId,
    channel: copy message.channel,
    message: move detail,
  });
}

${codecs.source}

${protocols.map((protocol) => renderAdapter(protocol, manifest, codecs.copyable)).join("\n\n")}
`;
}

export async function generateZWorkerProtocolAdapters(
  protocols: readonly ZWorkerProtocolManifest[],
  options: RenderZWorkerProtocolAdaptersOptions,
): Promise<string> {
  await mkdir(path.dirname(options.outputPath), { recursive: true });
  await writeFile(
    options.outputPath,
    renderZWorkerProtocolAdapters(protocols, options),
    "utf8",
  );
  return options.outputPath;
}
