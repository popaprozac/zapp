import type { NavigationProfileConfig, ResolvedConfig } from "./config";

export interface ResolvedNavigationProfile {
  name: string;
  allowsSelf: boolean;
  origins: string[];
  externalSchemes: string[];
}

function canonicalOrigin(value: string): string {
  return new URL(value).origin;
}

/** Resolve the fail-closed profile catalog consumed by native generation. */
export function resolveNavigationProfiles(
  config: Pick<ResolvedConfig, "navigationProfiles">,
): ResolvedNavigationProfile[] {
  const authored: Record<string, NavigationProfileConfig> =
    config.navigationProfiles ?? {
      default: { navigate: ["self"], openExternal: [] },
    };
  return Object.entries(authored).map(([name, profile]) => {
    const navigate = profile.navigate ?? [];
    return {
      name,
      allowsSelf: navigate.includes("self"),
      origins: navigate
        .filter((value) => value !== "self")
        .map(canonicalOrigin),
      externalSchemes: (profile.openExternal ?? [])
        .map((value) => value.toLowerCase()),
    };
  });
}
