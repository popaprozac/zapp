import path from "node:path";
import { readFile, writeFile } from "node:fs/promises";
import type { ZServiceManifest, ZServiceMetadata } from "./z-service-bindings";
import { zServiceAdapterFactoryName } from "./z-service-dispatcher";

interface RegistrationCall {
  argumentStart: number;
  close: number;
}

const runtimeRegistrationMethods = new Map([
  ["ApplicationServicesBuilder.registerAsync", "registerAsync"],
  ["ApplicationServicesBuilder.registerAsyncWithLifecycle", "registerAsyncWithLifecycle"],
]);

function relativeModule(fromFile: string, target: string): string {
  let relative = path.relative(path.dirname(fromFile), target).replaceAll(path.sep, "/");
  if (!relative.startsWith(".")) relative = `./${relative}`;
  return relative;
}

function registrationMethodName(service: ZServiceMetadata): string {
  const method = runtimeRegistrationMethods.get(service.registration.method);
  if (!method) {
    throw new Error(
      `[zapp] cannot generate runtime registration for unsupported method `
      + `${JSON.stringify(service.registration.method)}`,
    );
  }
  return method;
}

function scanRegistrationCall(
  source: string,
  open: number,
  service: ZServiceMetadata,
): RegistrationCall {
  if (source[open] !== "(") {
    throw new Error(
      `[zapp] stale service metadata for ${JSON.stringify(service.name)}: expected "(" at `
      + `${service.registration.module}:${service.registration.line}:${service.registration.column}`,
    );
  }

  let parentheses = 1;
  let brackets = 0;
  let braces = 0;
  let comma = -1;
  let quote: "\"" | "'" | "`" | null = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;

  for (let index = open + 1; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];

    if (lineComment) {
      if (character === "\n") lineComment = false;
      continue;
    }
    if (blockComment) {
      if (character === "*" && next === "/") {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote !== null) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === "/" && next === "/") {
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === "/" && next === "*") {
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === "\"" || character === "'" || character === "`") {
      quote = character;
      continue;
    }
    if (character === "(") parentheses += 1;
    else if (character === ")") {
      parentheses -= 1;
      if (parentheses === 0) {
        if (comma < 0) {
          throw new Error(
            `[zapp] service registration for ${JSON.stringify(service.name)} no longer has two arguments`,
          );
        }
        let argumentStart = comma + 1;
        while (/\s/.test(source[argumentStart] ?? "")) argumentStart += 1;
        return { argumentStart, close: index };
      }
    } else if (character === "[") brackets += 1;
    else if (character === "]") brackets -= 1;
    else if (character === "{") braces += 1;
    else if (character === "}") braces -= 1;
    else if (
      character === ","
      && parentheses === 1
      && brackets === 0
      && braces === 0
    ) {
      if (comma >= 0) {
        throw new Error(
          `[zapp] service registration for ${JSON.stringify(service.name)} no longer has exactly two arguments`,
        );
      }
      comma = index;
    }
  }

  throw new Error(
    `[zapp] unterminated service registration for ${JSON.stringify(service.name)} at `
    + `${service.registration.module}:${service.registration.line}:${service.registration.column}`,
  );
}

function rewriteRegistration(
  source: string,
  service: ZServiceMetadata,
): string {
  const open = service.registration.offset;
  const declaredMethod = service.registration.method.split(".").at(-1) ?? "";
  let methodEnd = open;
  while (/\s/.test(source[methodEnd - 1] ?? "")) methodEnd -= 1;
  const methodStart = methodEnd - declaredMethod.length;
  if (
    methodStart < 0
    || source.slice(methodStart, methodEnd) !== declaredMethod
    || source[methodStart - 1] !== "."
  ) {
    throw new Error(
      `[zapp] stale service metadata for ${JSON.stringify(service.name)}: expected `
      + `${JSON.stringify(declaredMethod)} before `
      + `${service.registration.module}:${service.registration.line}:${service.registration.column}`,
    );
  }

  const call = scanRegistrationCall(source, open, service);
  const factory = zServiceAdapterFactoryName(service.name);
  return source.slice(0, methodStart)
    + registrationMethodName(service)
    + source.slice(methodEnd, call.argumentStart)
    + `${factory}(`
    + source.slice(call.argumentStart, call.close)
    + ")"
    + source.slice(call.close);
}

export function rewriteZServiceRegistrationModule(
  source: string,
  modulePath: string,
  generatedModule: string,
  manifest: ZServiceManifest,
): string {
  const services = manifest.services
    .filter((service) => (
      service.registration.module === modulePath
      && runtimeRegistrationMethods.has(service.registration.method)
    ))
    .sort((left, right) => right.registration.offset - left.registration.offset);
  if (services.length === 0) return source;

  let rewritten = source;
  for (const service of services) rewritten = rewriteRegistration(rewritten, service);

  const factories = services
    .map((service) => zServiceAdapterFactoryName(service.name))
    .sort();
  const generatedImport = `import { ${factories.join(", ")} } from `
    + `${JSON.stringify(relativeModule(modulePath, generatedModule))};\n`;
  return generatedImport + rewritten;
}

export async function installGeneratedZServiceRegistrations(
  manifest: ZServiceManifest,
  generatedModule: string,
): Promise<string[]> {
  const modules = [...new Set(manifest.services
    .filter((service) => runtimeRegistrationMethods.has(service.registration.method))
    .map((service) => service.registration.module))];
  for (const modulePath of modules) {
    const source = await readFile(modulePath, "utf8");
    const rewritten = rewriteZServiceRegistrationModule(
      source,
      modulePath,
      generatedModule,
      manifest,
    );
    await writeFile(modulePath, rewritten, "utf8");
  }
  return modules;
}
