// CLI logging — a single level-gated emitter so `bun run dev/build` output
// matches the native ZAPP_LOG levels. 0 = default, 1 = verbose, 2 = debug.

let cliLevel = 0;

export function levelFromArgv(argv: string[]): number {
  if (argv.includes("--debug")) return 2;
  if (argv.includes("--verbose") || argv.includes("-v")) return 1;
  return 0;
}

export function setCliLevel(level: number): void {
  cliLevel = level;
}

export function getCliLevel(): number {
  return cliLevel;
}

// ZAPP_LOG value to hand the spawned native app so its level matches the CLI.
export function envFromLevel(level: number): string {
  return level >= 2 ? "debug" : level >= 1 ? "verbose" : "";
}

// Emit a "[zapp] …" line if `level` <= the active CLI level. Default(0) always
// prints; verbose(1)/debug(2) gate. Errors should use clogError (always).
export function clog(level: number, ...parts: unknown[]): void {
  if (cliLevel >= level) {
    process.stdout.write(`[zapp] ${parts.join(" ")}\n`);
  }
}

export function clogError(...parts: unknown[]): void {
  process.stderr.write(`[zapp] ${parts.join(" ")}\n`);
}
