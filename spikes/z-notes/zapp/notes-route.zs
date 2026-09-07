// The application accepts exactly one route and an unsigned decimal note ID.
// No external input becomes a service method or a WebView destination.
export function noteIdFromURL(in url: String): Option<u64> {
  const prefix = "znotes://notes/";
  if (url.byteLength <= prefix.byteLength) return Option.none;
  let offset: usize = 0;
  while (offset < prefix.byteLength) {
    let byte = url.byteAt(offset);
    if (byte >= 65 && byte <= 90) byte = byte + 32;
    if (byte != prefix.byteAt(offset)) return Option.none;
    offset = offset + 1;
  }
  let id: u64 = 0;
  while (offset < url.byteLength) {
    const byte = url.byteAt(offset);
    if (byte < 48 || byte > 57) return Option.none;
    const digit = u64(byte - 48);
    if (id > 1844674407370955161) return Option.none;
    if (id == 1844674407370955161 && digit > 5) return Option.none;
    id = id * 10 + digit;
    offset = offset + 1;
  }
  if (id == 0) return Option.none;
  return Option.some(id);
}
