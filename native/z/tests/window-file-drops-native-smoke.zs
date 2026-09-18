import WebKit from "WebKit/WebKit.h";
import { thread } from "std/thread";
import fs from "std/fs";
import process from "std/process";
import { macOSDroppedFiles } from "../framework/platform/macos/file-drops.zs";

// Fixture setup only: writeObjects uses NSArray<id<NSPasteboardWriting>>,
// whose nested generic spelling is not imported yet. Production only reads
// native pasteboard items and uses no raw bridge.
function writeItems(in board: WebKit.NSPasteboard, in items: WebKit.NSArray): boolean on thread.main = raw objc {
  return [board writeObjects:items];
}

function place(in board: WebKit.NSPasteboard, in paths: Array<String>): boolean on thread.main {
  board.clearContents();
  const items = WebKit.NSMutableArray.array();
  for (const path of paths) {
    const url = WebKit.NSURL.fileURLWithPath(copy path);
    const source = url.absoluteString;
    if (source == null) return false;
    const item = WebKit.NSPasteboardItem.alloc().init();
    if (!item.setString(source, forType: WebKit.NSPasteboardTypeFileURL)) return false;
    items.addObject(item);
  }
  return writeItems(in board, in items);
}

function run(in directory: String): i32 throws String on thread.main {
  const first = `${directory}/first.txt`;
  const second = `${directory}/second.txt`;
  try fs.writeText(in first, "first");
  try fs.writeText(in second, "second");
  const board = WebKit.NSPasteboard.pasteboardWithUniqueName();
  const directoryURL = WebKit.NSURL.fileURLWithPath(copy directory).URLByResolvingSymlinksInPath;
  if (directoryURL == null) return 11;
  const directoryPath = directoryURL.path;
  if (directoryPath == null) return 12;
  const canonicalDirectory: String = directoryPath;
  const expectedFirst = `${canonicalDirectory}/first.txt`;
  const expectedSecond = `${canonicalDirectory}/second.txt`;
  const valid = Array<String>(copy first, copy second);
  if (!place(in board, in valid)) return 1;
  const paths = match (macOSDroppedFiles(in board)) { some(value) => value; none => return 2; };
  if (paths.length != 2 || paths[0] != expectedFirst || paths[1] != expectedSecond) return 3;
  const directoryBatch = Array<String>(copy first, copy directory);
  if (!place(in board, in directoryBatch)) return 4;
  match (macOSDroppedFiles(in board)) { some(_) => return 5; none => {} }
  const missing = Array<String>(copy first, `${directory}/missing.txt`);
  if (!place(in board, in missing)) return 6;
  match (macOSDroppedFiles(in board)) { some(_) => return 7; none => {} }
  board.clearContents();
  const item = WebKit.NSPasteboardItem.alloc().init();
  if (!item.setString("file://remote.example/secret.txt", forType: WebKit.NSPasteboardTypeFileURL)) return 8;
  const items = WebKit.NSMutableArray.array(); items.addObject(item);
  if (!writeItems(in board, in items)) return 9;
  match (macOSDroppedFiles(in board)) { some(_) => return 10; none => {} }
  board.clearContents();
  board.releaseGlobally();
  return 0;
}
function main(): i32 on thread.main {
  const args = process.args();
  if (args.length != 1) return 90;
  const directory = copy args[0];
  return match (attempt run(in directory)) { success(value) => value; failure(_) => 91; };
}
