import path from "node:path";
import { mkdir } from "node:fs/promises";
import { runCmd } from "./common";

export type BuildMode = "dev" | "dev-embedded" | "prod" | "prod-embedded";

const cString = (value: string): string => JSON.stringify(value.replace(/\\/g, "/"));

export const generateBuildConfigZc = async ({
  root,
  mode,
  assetDir,
  devUrl,
  backendScriptPath,
}: {
  root: string;
  mode: BuildMode;
  assetDir: string;
  devUrl?: string;
  backendScriptPath?: string | null;
}) => {
  const buildDir = path.join(root, ".zapp");
  await mkdir(buildDir, { recursive: true });

  const isDev = mode === "dev" || mode === "dev-embedded";
  const useEmbeddedAssets = mode === "dev-embedded" || mode === "prod-embedded";
  const initialUrl = mode === "dev" ? devUrl ?? "http://localhost:5173" : "zapp://index.html";

  const content = `// AUTO-GENERATED FILE. DO NOT EDIT.

raw {
    const char* zapp_build_mode_name(void) {
        return ${cString(mode)};
    }

    const char* zapp_build_asset_root(void) {
        return ${cString(assetDir)};
    }

    const char* zapp_build_initial_url(void) {
        return ${cString(initialUrl)};
    }

    int zapp_build_is_dev_mode(void) {
        return ${isDev ? 1 : 0};
    }

    int zapp_build_use_embedded_assets(void) {
        return ${useEmbeddedAssets ? 1 : 0};
    }

    const char* zapp_build_backend_script_path(void) {
        return ${backendScriptPath ? cString(backendScriptPath) : '""'};
    }
}
`;

  const outPath = path.join(buildDir, "zapp_build_config.zc");
  await Bun.write(outPath, content);
  return outPath;
};
