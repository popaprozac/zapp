// Native source asset: reproducible 2x glyph, independent of legacy branding.
import { deflateSync } from "node:zlib";
const size = 36;
const pixels = Buffer.alloc(size * (1 + size * 4));
for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
  const paper = x >= 7 && x <= 28 && y >= 3 && y <= 32;
  const edge = x <= 9 || x >= 26 || y <= 5 || y >= 30;
  const line = x >= 13 && x <= 22 && (y === 12 || y === 13 || y === 19 || y === 20);
  pixels[y * (1 + size * 4) + 1 + x * 4 + 3] = paper && (edge || line) ? 255 : 0;
}
function chunk(type: string, bytes: Buffer): Buffer {
  const contents = Buffer.concat([Buffer.from(type), bytes]);
  let crc = 0xffffffff;
  for (const byte of contents) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  const length = Buffer.alloc(4); length.writeUInt32BE(bytes.length);
  const checksum = Buffer.alloc(4); checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([length, contents, checksum]);
}
const header = Buffer.alloc(13);
header.writeUInt32BE(size, 0); header.writeUInt32BE(size, 4); header[8] = 8; header[9] = 6;
await Bun.write(`${import.meta.dir}/tray.png`, Buffer.concat([
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header),
  chunk("IDAT", deflateSync(pixels)), chunk("IEND", Buffer.alloc(0)),
]));
