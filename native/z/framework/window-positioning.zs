import { WindowError } from "./application-error.zs";

// Global logical coordinates: primary display top-left, x right, y down.
export readonly struct WindowPosition {
  x: f64;
  y: f64;
}

internal function checkedWindowPosition(position: WindowPosition): WindowPosition throws WindowError {
  // A finite value subtracts from itself to zero; NaN and infinities do not.
  if (position.x - position.x != 0 || position.y - position.y != 0) {
    throw WindowError({ id: "", message: "window coordinates must be finite logical values" });
  }
  return position;
}
