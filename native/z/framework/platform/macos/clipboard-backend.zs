import AppKit from "AppKit/AppKit.h";
import { thread } from "std/thread";
import {
  ClipboardBackend,
  ClipboardClearOperation,
  ClipboardError,
  ClipboardOperation,
  ClipboardReadTextOperation,
  ClipboardWriteTextOperation,
} from "../../clipboard.zs";

function readMacOSClipboardText(
): Option<String> throws ClipboardError on thread.main {
  const pasteboard = AppKit.NSPasteboard.generalPasteboard;
  const value = pasteboard.stringForType(AppKit.NSPasteboardTypeString);
  if (value == null) return Option.none;
  const text: String = value;
  return Option.some(move text);
}

function writeMacOSClipboardText(
  in text: String
): void throws ClipboardError on thread.main {
  const pasteboard = AppKit.NSPasteboard.generalPasteboard;
  pasteboard.clearContents();
  if (!pasteboard.setString(in text, forType: AppKit.NSPasteboardTypeString)) {
    throw ClipboardError({
      operation: ClipboardOperation.writeText,
      message: "AppKit rejected the clipboard text",
    });
  }
}

function clearMacOSClipboard(
): void throws ClipboardError on thread.main {
  const pasteboard = AppKit.NSPasteboard.generalPasteboard;
  pasteboard.clearContents();
}

internal function macOSClipboardBackend(
): ClipboardBackend on thread.main {
  const readText: ClipboardReadTextOperation = readMacOSClipboardText;
  const writeText: ClipboardWriteTextOperation = writeMacOSClipboardText;
  const clear: ClipboardClearOperation = clearMacOSClipboard;
  return ClipboardBackend({ readText, writeText, clear });
}
