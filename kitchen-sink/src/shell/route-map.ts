/** Pure URL ⇄ section-id mapping for the kitchen-sink router. Home is the
 *  N2a-seeded root "/"; every other registry section is "/<id>". Shared by the
 *  sidebar (push) and main pane (render) so both agree on the scheme. */
export function routeForSection(id: string): string {
  return id === "home" ? "/" : "/" + id;
}

export function sectionForRoute(url: string): string {
  return url === "" || url === "/" ? "home" : url.replace(/^\//, "");
}
