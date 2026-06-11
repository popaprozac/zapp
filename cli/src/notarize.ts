// Apple notarization — submit a signed .app to Apple, wait for the
// verdict, staple the ticket so the bundle opens cleanly on other
// Macs without a security warning.
//
// Three auth paths supported (any one is enough):
//   1. Keychain profile — `xcrun notarytool store-credentials <name>`
//      then set `notarize.keychainProfile` (or env
//      ZAPP_NOTARIZE_KEYCHAIN_PROFILE).
//   2. API key — .p8 from App Store Connect + key ID + issuer ID.
//      Best for CI: no interactive password prompt.
//   3. Apple ID + app-specific password — legacy, password from env
//      ZAPP_NOTARIZE_APPLE_PASSWORD only (never config).
//
// Resolution order: env vars > config > error. Env wins so secrets
// stay out of `zapp.config.ts`.

import path from "node:path";
import type { MacOSConfig } from "./config";
import { clog, clogError } from "./log";

interface ResolvedCredentials {
  /** Args appended to `xcrun notarytool submit ...` for auth. */
  authArgs: string[];
  /** Human label for logging — never includes secrets. */
  describe: string;
}

function envOr(envKey: string, configValue?: string): string | undefined {
  const fromEnv = process.env[envKey];
  if (fromEnv && fromEnv.trim().length > 0) return fromEnv.trim();
  if (configValue && configValue.trim().length > 0) return configValue.trim();
  return undefined;
}

/**
 * Resolve which auth method to use. Returns the args to pass to
 * `xcrun notarytool submit`, or null + a message if no method is
 * configured.
 */
export function resolveNotarizeCredentials(
  notarize: NonNullable<MacOSConfig["notarize"]> | undefined,
): { ok: true; creds: ResolvedCredentials } | { ok: false; reason: string } {
  // Path 1: keychain profile
  const profile = envOr("ZAPP_NOTARIZE_KEYCHAIN_PROFILE", notarize?.keychainProfile);
  if (profile) {
    return {
      ok: true,
      creds: {
        authArgs: ["--keychain-profile", profile],
        describe: `keychain profile "${profile}"`,
      },
    };
  }

  // Path 2: API key
  const apiKeyPath = envOr("ZAPP_NOTARIZE_API_KEY_PATH", notarize?.apiKeyPath);
  const apiKeyId   = envOr("ZAPP_NOTARIZE_API_KEY_ID",   notarize?.apiKeyId);
  const apiIssuer  = envOr("ZAPP_NOTARIZE_API_ISSUER_ID", notarize?.apiIssuerId);
  if (apiKeyPath || apiKeyId || apiIssuer) {
    if (!apiKeyPath || !apiKeyId || !apiIssuer) {
      return {
        ok: false,
        reason:
          "API key auth requires all of: apiKeyPath, apiKeyId, apiIssuerId " +
          "(or the corresponding ZAPP_NOTARIZE_API_KEY_PATH / ID / ISSUER_ID env vars).",
      };
    }
    return {
      ok: true,
      creds: {
        authArgs: ["--key", apiKeyPath, "--key-id", apiKeyId, "--issuer", apiIssuer],
        describe: `API key ${path.basename(apiKeyPath)} (id ${apiKeyId})`,
      },
    };
  }

  // Path 3: Apple ID
  const appleId   = envOr("ZAPP_NOTARIZE_APPLE_ID", notarize?.appleId);
  const password  = process.env.ZAPP_NOTARIZE_APPLE_PASSWORD;
  const teamId    = envOr("ZAPP_NOTARIZE_TEAM_ID",  notarize?.teamId);
  if (appleId || password || teamId) {
    if (!appleId || !password || !teamId) {
      return {
        ok: false,
        reason:
          "Apple ID auth requires appleId + teamId in config (or env) AND " +
          "ZAPP_NOTARIZE_APPLE_PASSWORD env var (app-specific password).",
      };
    }
    return {
      ok: true,
      creds: {
        authArgs: ["--apple-id", appleId, "--team-id", teamId, "--password", password],
        describe: `Apple ID ${appleId}`,
      },
    };
  }

  return {
    ok: false,
    reason:
      "no notarize credentials found. Set one of: keychainProfile, " +
      "apiKey* trio, or appleId/teamId (+ ZAPP_NOTARIZE_APPLE_PASSWORD). " +
      "See docs/patterns.md → Notarization for the full setup.",
  };
}

/**
 * Submit + staple. Caller has already signed the .app with a real
 * Developer ID. On failure, fetches the submission log via
 * `xcrun notarytool log` and prints the rejection details so the
 * user knows what to fix (Apple's stderr is otherwise cryptic).
 */
export async function notarizeApp(opts: {
  appPath: string;
  notarize: NonNullable<MacOSConfig["notarize"]> | undefined;
}): Promise<boolean> {
  const resolved = resolveNotarizeCredentials(opts.notarize);
  if (!resolved.ok) {
    clogError(`notarization skipped: ${resolved.reason}`);
    return false;
  }

  clog(0, `notarizing via ${resolved.creds.describe}…`);
  clog(0, "(Apple typically takes 1–5 min — be patient)");

  // Apple notarytool needs a flat archive — `ditto` preserves bundle
  // metadata better than `zip` for .app trees.
  const zipPath = opts.appPath.replace(/\.app$/, "") + ".notarize.zip";
  const dittoProc = Bun.spawn(
    ["ditto", "-c", "-k", "--keepParent", opts.appPath, zipPath],
    { stdout: "pipe", stderr: "pipe" },
  );
  const dittoExit = await dittoProc.exited;
  if (dittoExit !== 0) {
    const err = await new Response(dittoProc.stderr).text();
    clogError(`zip for notarization failed:\n${err}`);
    return false;
  }

  // Submit + wait. We capture stdout so we can extract the submission
  // ID (needed to fetch the log on failure).
  const submitArgs = [
    "xcrun", "notarytool", "submit", zipPath,
    ...resolved.creds.authArgs,
    "--wait",
    "--output-format", "json",
  ];
  const submitProc = Bun.spawn(submitArgs, {
    stdout: "pipe",
    stderr: "pipe",
  });
  const submitOut = await new Response(submitProc.stdout).text();
  const submitErr = await new Response(submitProc.stderr).text();
  const submitExit = await submitProc.exited;

  // Cleanup zip whether success or fail.
  await Bun.spawn(["rm", "-f", zipPath]).exited;

  let submissionId: string | undefined;
  let status: string | undefined;
  try {
    const parsed = JSON.parse(submitOut);
    submissionId = parsed.id;
    status = parsed.status;  // "Accepted" | "Invalid" | "Rejected" | etc.
  } catch {
    // notarytool may print non-JSON when something goes very wrong
    // (e.g. auth failure). Fall through to the error path.
  }

  if (submitExit !== 0 || status !== "Accepted") {
    clogError(
      `notarization ${status ? `returned ${status}` : "failed"}`,
    );
    if (submitErr.trim().length > 0) process.stderr.write(submitErr);
    if (submissionId) {
      // Fetch the log to surface the actual reason — Apple's "Invalid"
      // status without a log message is the most common confusion
      // point ("why did it fail?").
      clogError(`fetching submission log (${submissionId})…`);
      const logProc = Bun.spawn(
        ["xcrun", "notarytool", "log", submissionId, ...resolved.creds.authArgs],
        { stdout: "inherit", stderr: "inherit" },
      );
      await logProc.exited;
    }
    return false;
  }

  // Staple — embeds the ticket in the .app so Gatekeeper doesn't have
  // to phone home on first launch.
  clog(0, "notarization accepted, stapling…");
  const stapleProc = Bun.spawn(
    ["xcrun", "stapler", "staple", opts.appPath],
    { stdout: "pipe", stderr: "pipe" },
  );
  const stapleExit = await stapleProc.exited;
  if (stapleExit !== 0) {
    const err = await new Response(stapleProc.stderr).text();
    clogError(`stapling failed:\n${err}`);
    return false;
  }
  clog(0, `notarization complete: ${opts.appPath}`);
  return true;
}
