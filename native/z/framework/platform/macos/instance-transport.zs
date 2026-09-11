import Foundation from "Foundation/Foundation.h";
import { ActivationInbox } from "../../activation-inbox.zs";
import { MacOSInstanceLease } from "./instance-lease.zs";
import { MacOSLaunchCancellation } from "./launch-cancellation.zs";
import {
  launchSocketPath, launchDeadline, waitLaunchSocket, openLaunchSocket,
  checkLaunchPeer, acceptLaunchSocket, closeLaunchSocket, removeLaunchSocket,
  receiveLaunchChunk, sendLaunchChunk, makeLaunchBuffer, launchHeaderLength,
  launchHeader, launchTextBytes, launchBytesText,
  retryLaunchConnection,
} from "./launch-socket.zs";

internal readonly struct MacOSLaunchTransportError {
  code: i32;
  // A failed response is not proof of non-admission. Never retry automatically
  // or start a new primary after this becomes true.
  mayHaveBeenAdmitted: boolean;
  message: String;
}

internal struct MacOSLaunchConnection {
  file: Foundation.NSFileHandle;
  deinit { closeLaunchSocket(in this.file); }
}

internal struct MacOSLaunchEndpoint {
  private lease: MacOSInstanceLease;
  private path: Foundation.NSString;
  private file: Foundation.NSFileHandle;
  deinit {
    removeLaunchSocket(in this.path);
    closeLaunchSocket(in this.file);
  }

  static function listen(lease: MacOSInstanceLease): MacOSLaunchEndpoint throws MacOSLaunchTransportError {
    const identifier: Foundation.NSString = copy lease.identifier;
    let code = 0;
    const path = launchSocketPath(in identifier, inout code);
    if (path == null) throw MacOSLaunchTransportError({ code, mayHaveBeenAdmitted: false, message: "launch endpoint path failed" });
    const file = openLaunchSocket(in path, true, inout code);
    if (file == null) throw MacOSLaunchTransportError({ code, mayHaveBeenAdmitted: false, message: "launch endpoint setup failed" });
    return MacOSLaunchEndpoint({ lease: move lease, path, file });
  }

  // Serial, deadline-bound admission, independent of AppKit/main-loop progress.
  // The application-owned listener worker calls this; no event callback runs here.
  internal function receive(inout this, in inbox: ActivationInbox): boolean throws MacOSLaunchTransportError {
    return try this.receiveCancellable(in inbox, Option<MacOSLaunchCancellation>.none);
  }

  internal function receiveCancellable(
    inout this, in inbox: ActivationInbox, cancellation: Option<MacOSLaunchCancellation>
  ): boolean throws MacOSLaunchTransportError {
    const deadline = launchDeadline(1000);
    const ready = waitForLaunch(in this.file, false, deadline, in cancellation);
    if (ready != 0) throw MacOSLaunchTransportError({ code: ready, mayHaveBeenAdmitted: false, message: "launch endpoint wait failed" });
    let code = 0;
    const file = acceptLaunchSocket(in this.file, inout code);
    if (file == null) throw MacOSLaunchTransportError({ code, mayHaveBeenAdmitted: false, message: "launch connection failed" });
    const connection = MacOSLaunchConnection({ file });
    const peer = checkLaunchPeer(in connection.file);
    if (peer != 0) throw MacOSLaunchTransportError({ code: peer, mayHaveBeenAdmitted: false, message: "launch peer validation failed" });
    const requestDeadline = launchDeadline(1000);
    const bytes = try readFrame(in connection.file, 65536, requestDeadline, false, in cancellation);
    const nativeText = launchBytesText(in bytes);
    let accepted = false;
    if (nativeText != null) {
      const text: String = nativeText;
      accepted = inbox.admitPayload(in text);
    }
    const reply: Foundation.NSString = accepted ? "zapp-launch/1 accepted" : "zapp-launch/1 rejected";
    const response = launchTextBytes(in reply);
    try writeFrame(in connection.file, in response, requestDeadline, accepted, in cancellation);
    return accepted;
  }
}

internal function listenMacOSLaunches(lease: MacOSInstanceLease): MacOSLaunchEndpoint throws MacOSLaunchTransportError {
  return try MacOSLaunchEndpoint.listen(move lease);
}

// Private wire probe accepts encoded input so malformed-frame tests exercise
// the same receiver. Startup will supply encodeApplicationLaunch's checked data.
internal function forwardMacOSLaunch(in identifier: String, in payload: String): boolean throws MacOSLaunchTransportError {
  return try forwardLaunch(in identifier, in payload, false);
}

internal function forwardMacOSLaunchWhenReady(in identifier: String, in payload: String): boolean throws MacOSLaunchTransportError {
  return try forwardLaunch(in identifier, in payload, true);
}

function connectPrimary(in path: Foundation.NSString, deadline: f64, waitForReady: boolean): Foundation.NSFileHandle throws MacOSLaunchTransportError {
  let code = 0;
  let file = openLaunchSocket(in path, false, inout code);
  while (file == null && waitForReady && retryLaunchConnection(code, deadline)) {
    file = openLaunchSocket(in path, false, inout code);
  }
  if (file == null) throw MacOSLaunchTransportError({ code, mayHaveBeenAdmitted: false, message: "primary launch endpoint unavailable" });
  return file;
}

function forwardLaunch(in identifier: String, in payload: String, waitForReady: boolean): boolean throws MacOSLaunchTransportError {
  if (payload.byteLength == 0 || payload.byteLength > 65536) {
    throw MacOSLaunchTransportError({ code: 0, mayHaveBeenAdmitted: false, message: "launch payload exceeds transport bounds" });
  }
  const nativeIdentifier: Foundation.NSString = copy identifier;
  const text: Foundation.NSString = copy payload;
  let code = 0;
  const path = launchSocketPath(in nativeIdentifier, inout code);
  if (path == null) throw MacOSLaunchTransportError({ code, mayHaveBeenAdmitted: false, message: "launch endpoint path failed" });
  const deadline = launchDeadline(5000);
  const file = try connectPrimary(in path, deadline, waitForReady);
  const connection = MacOSLaunchConnection({ file });
  const ready = waitLaunchSocket(in connection.file, true, deadline);
  if (ready != 0) throw MacOSLaunchTransportError({ code: ready, mayHaveBeenAdmitted: false, message: "primary connection deadline exceeded" });
  const peer = checkLaunchPeer(in connection.file);
  if (peer != 0) throw MacOSLaunchTransportError({ code: peer, mayHaveBeenAdmitted: false, message: "primary peer validation failed" });
  const request = launchTextBytes(in text);
  const cancellation = Option<MacOSLaunchCancellation>.none;
  try writeFrame(in connection.file, in request, deadline, true, in cancellation);
  const response = try readFrame(in connection.file, 64, deadline, true, in cancellation);
  const reply = launchBytesText(in response);
  if (reply != null) {
    const value: String = reply;
    if (value == "zapp-launch/1 accepted") return true;
    if (value == "zapp-launch/1 rejected") return false;
  }
  throw MacOSLaunchTransportError({ code: 0, mayHaveBeenAdmitted: true, message: "invalid primary admission acknowledgement" });
}

function waitForLaunch(in file: Foundation.NSFileHandle, writing: boolean, deadline: f64, in cancellation: Option<MacOSLaunchCancellation>): i32 {
  return match (in cancellation) {
    some(signal) => signal.wait(in file, writing, deadline);
    none => waitLaunchSocket(in file, writing, deadline);
  };
}

function readBytes(in file: Foundation.NSFileHandle, length: usize, deadline: f64, uncertain: boolean, in cancellation: Option<MacOSLaunchCancellation>): Foundation.NSData throws MacOSLaunchTransportError {
  let bytes = makeLaunchBuffer(length);
  let offset: usize = 0;
  while (offset < length) {
    const ready = waitForLaunch(in file, false, deadline, in cancellation);
    if (ready != 0) throw MacOSLaunchTransportError({ code: ready, mayHaveBeenAdmitted: uncertain, message: "launch receive deadline or connection failure" });
    const received = receiveLaunchChunk(in file, inout bytes, offset);
    if (received < 0) throw MacOSLaunchTransportError({ code: i32(-received), mayHaveBeenAdmitted: uncertain, message: "launch connection ended before a complete frame" });
    offset = offset + usize(received);
  }
  return bytes;
}

function readFrame(in file: Foundation.NSFileHandle, maximum: usize, deadline: f64, uncertain: boolean, in cancellation: Option<MacOSLaunchCancellation>): Foundation.NSData throws MacOSLaunchTransportError {
  const header = try readBytes(in file, 4, deadline, uncertain, in cancellation);
  const length = launchHeaderLength(in header);
  if (length == 0 || length > maximum) throw MacOSLaunchTransportError({ code: 0, mayHaveBeenAdmitted: uncertain, message: "invalid launch frame length" });
  return try readBytes(in file, length, deadline, uncertain, in cancellation);
}

function writeBytes(in file: Foundation.NSFileHandle, in bytes: Foundation.NSData, deadline: f64, uncertain: boolean, in cancellation: Option<MacOSLaunchCancellation>): void throws MacOSLaunchTransportError {
  let offset: usize = 0;
  while (offset < bytes.length) {
    const ready = waitForLaunch(in file, true, deadline, in cancellation);
    if (ready != 0) throw MacOSLaunchTransportError({ code: ready, mayHaveBeenAdmitted: uncertain, message: "launch send deadline or connection failure" });
    const sent = sendLaunchChunk(in file, in bytes, offset);
    if (sent < 0) throw MacOSLaunchTransportError({ code: i32(-sent), mayHaveBeenAdmitted: uncertain, message: "launch send failed" });
    offset = offset + usize(sent);
  }
}

function writeFrame(in file: Foundation.NSFileHandle, in bytes: Foundation.NSData, deadline: f64, uncertain: boolean, in cancellation: Option<MacOSLaunchCancellation>): void throws MacOSLaunchTransportError {
  const header = launchHeader(bytes.length);
  try writeBytes(in file, in header, deadline, uncertain, in cancellation);
  try writeBytes(in file, in bytes, deadline, uncertain, in cancellation);
}
