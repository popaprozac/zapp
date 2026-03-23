import path from "node:path";

export interface MacOSConfig {
  /** Minimum macOS version. Defaults to "13.0" */
  minimumSystemVersion?: string;
  /** App category for the Mac App Store (e.g. "public.app-category.developer-tools") */
  category?: string;
  /** Path to .icon folder for macOS Tahoe liquid glass icons (created with Icon Composer) */
  iconLayers?: string;
}

export interface SecurityConfig {
  /** Custom Content Security Policy. Default: strict self-only policy */
  csp?: string;
  /** Allowed navigation URLs (glob patterns). Default: only app scheme + dev server */
  allowNavigation?: string[];
}

export interface ZappConfig {
  /** App name -- used for binary output, bundle name, window title fallback */
  name: string;
  /** Reverse-domain identifier (e.g. "com.mycompany.myapp"). Defaults to "com.zapp.{name}" */
  identifier?: string;
  /** App version string. Defaults to "1.0.0" */
  version?: string;
  /** Path to app icon source (1024x1024 PNG). Used to generate .icns (macOS) and .ico (Windows). */
  icon?: string;
  /** App description */
  description?: string;
  /** Author name */
  author?: string;
  /** macOS-specific config */
  macos?: MacOSConfig;
  /** Security settings */
  security?: SecurityConfig;
}

export interface ResolvedZappConfig {
  name: string;
  identifier: string;
  version: string;
  icon?: string;
  description?: string;
  author?: string;
  macos?: MacOSConfig;
  security?: SecurityConfig;
}

/** Passthrough helper that provides type inference and autocomplete for zapp.config.ts */
export function defineConfig(config: ZappConfig): ZappConfig {
  return config;
}

function applyDefaults(config: ZappConfig): ResolvedZappConfig {
  return {
    name: config.name,
    identifier: config.identifier ?? `com.zapp.${config.name}`,
    version: config.version ?? "1.0.0",
    icon: config.icon,
    description: config.description,
    author: config.author,
    macos: config.macos,
    security: config.security,
  };
}

export async function loadConfig(root: string): Promise<ResolvedZappConfig> {
  const configPath = path.join(root, "zapp", "zapp.config.ts");
  const configFile = Bun.file(configPath);

  if (await configFile.exists()) {
    try {
      const mod = await import(configPath);
      const raw: ZappConfig = mod.default ?? mod;

      if (!raw.name || typeof raw.name !== "string") {
        throw new Error(`"name" is required in ${configPath} and must be a non-empty string`);
      }

      return applyDefaults(raw);
    } catch (err: unknown) {
      if (err instanceof Error && err.message.includes("name")) throw err;
      throw new Error(`Failed to load ${configPath}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  const fallbackName = path.basename(root) || "zapp-app";
  return applyDefaults({ name: fallbackName });
}
