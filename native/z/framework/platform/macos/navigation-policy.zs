import Foundation from "Foundation/Foundation.h";
import { thread } from "std/thread";
import {
  configuredFrontendOrigin,
  configuredNavigationAllowsSelf,
  configuredNavigationExternalSchemeAtIndex,
  configuredNavigationOriginAtIndex,
} from "./configured-webview.zs";

function frontendOrigin(): Foundation.NSURL | null on thread.main {
  return Foundation.NSURL.URLWithString(configuredFrontendOrigin());
}

internal function resolveLogicalURL(
  in logicalURL: String
): Foundation.NSURL | null on thread.main {
  let logical = copy logicalURL;
  if (logical.byteLength == 0) logical = "/";
  const components: Foundation.NSURLComponents | null =
    Foundation.NSURLComponents.componentsWithString(copy logical);
  if (
    components == null
    || components.scheme != null
    || components.host != null
  ) return null;
  const base = frontendOrigin();
  if (base == null) return null;
  const resolved: Foundation.NSURL | null =
    Foundation.NSURL.URLWithString(move logical, relativeToURL: base);
  if (resolved == null) return null;
  return resolved.absoluteURL;
}

function hasSameOrigin(
  in url: Foundation.NSURL,
  in origin: Foundation.NSURL
): boolean on thread.main {
  const scheme = url.scheme;
  const originScheme = origin.scheme;
  const host = url.host;
  const originHost = origin.host;
  if (
    scheme == null
    || originScheme == null
    || host == null
    || originHost == null
  ) return false;
  if (
    scheme.caseInsensitiveCompare(originScheme) != Foundation.NSOrderedSame
    || host.caseInsensitiveCompare(originHost) != Foundation.NSOrderedSame
  ) return false;
  const port = url.port;
  const originPort = origin.port;
  if (port == null || originPort == null) {
    return port == null && originPort == null;
  }
  return port.isEqualToNumber(originPort);
}

internal function hasConfiguredFrontendOrigin(
  in url: Foundation.NSURL
): boolean on thread.main {
  const origin = frontendOrigin();
  return origin != null && hasSameOrigin(in url, in origin);
}

internal function navigationProfileAllowsExternalURL(
  in profile: String,
  in address: String
): boolean on thread.main {
  const url = Foundation.NSURL.URLWithString(copy address);
  if (url == null) return false;
  const scheme = url.scheme;
  if (scheme == null) return false;
  const normalizedScheme: String = scheme.lowercaseString;
  let index: usize = 0;
  while (true) {
    const configured = configuredNavigationExternalSchemeAtIndex(
      in profile,
      index
    );
    match (configured) {
      some(value) => {
        const expected = value.copyBytes(0, value.byteLength - 1);
        if (normalizedScheme == expected) return true;
      }
      none => return false;
    }
    index = index + 1;
  }
  return false;
}

internal function profileAllowsURL(
  in profile: String,
  in url: Foundation.NSURL
): boolean on thread.main {
  if (
    configuredNavigationAllowsSelf(in profile)
    && hasConfiguredFrontendOrigin(in url)
  ) return true;

  let index: usize = 0;
  while (true) {
    const configured = configuredNavigationOriginAtIndex(in profile, index);
    match (configured) {
      some(value) => {
        const origin = Foundation.NSURL.URLWithString(value);
        if (origin != null && hasSameOrigin(in url, in origin)) return true;
      }
      none => return false;
    }
    index = index + 1;
  }
  return false;
}
