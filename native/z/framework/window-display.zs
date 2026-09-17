// Read-only measurements in logical desktop units, not live native handles.
export readonly struct Bounds {
  x: f64;
  y: f64;
  width: f64;
  height: f64;
}

export readonly struct Display {
  id: String;
  bounds: Bounds;
  workArea: Bounds;
  scaleFactor: f64;
  isPrimary: boolean;
}
