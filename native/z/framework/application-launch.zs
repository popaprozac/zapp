import json from "std/json";

// A secondary process snapshot, not the primary ApplicationContext. Arguments
// exclude argv[0]; empty strings and whitespace are preserved, not shell-parsed.
export readonly struct ApplicationSecondInstanceLaunchedEvent {
  arguments: readonly Array<String>;
  workingDirectory: Option<String>;
}

internal readonly struct ApplicationLaunchError {
  message: String;
}

// Private, versioned transport format. No environment, arbitrary application
// metadata, or service authority crosses this boundary.
readonly struct ApplicationLaunchEnvelope {
  version: u32;
  launch: ApplicationSecondInstanceLaunchedEvent;
}

function validLaunchText(in value: String): boolean {
  if (value.byteLength > 16384) return false;
  let index: usize = 0;
  while (index < value.byteLength) {
    if (value.byteAt(index) == 0) return false;
    index = index + 1;
  }
  return true;
}

internal function validApplicationLaunch(
  in launch: ApplicationSecondInstanceLaunchedEvent
): boolean {
  if (launch.arguments.length > 256) return false;
  let total: usize = 0;
  for (const argument of launch.arguments) {
    if (!validLaunchText(in argument)) return false;
    total = total + argument.byteLength;
    if (total > 65536) return false;
  }
  match (in launch.workingDirectory) {
    some(directory) => {
      if (directory.byteLength == 0 || !validLaunchText(in directory)) return false;
      total = total + directory.byteLength;
    }
    none => {}
  }
  return total <= 65536;
}

internal function encodeApplicationLaunch(
  launch: ApplicationSecondInstanceLaunchedEvent
): String throws ApplicationLaunchError {
  if (!validApplicationLaunch(in launch)) {
    throw ApplicationLaunchError({ message: "invalid or oversized secondary launch" });
  }
  // Move the snapshot into its versioned envelope, then borrow it for encoding.
  // The derived codec writes JSON directly; it does not flatten or copy owners.
  const envelope = ApplicationLaunchEnvelope({
    version: 1,
    launch: move launch,
  });
  const source = json.encode(in envelope);
  if (source.byteLength > 65536) {
    throw ApplicationLaunchError({ message: "secondary launch exceeds the 64 KiB transport limit" });
  }
  return source;
}

internal function decodeApplicationLaunch(
  in source: String
): ApplicationSecondInstanceLaunchedEvent throws ApplicationLaunchError {
  // Check the byte limit before JSON decoding can allocate argument storage.
  if (source.byteLength == 0 || source.byteLength > 65536) {
    throw ApplicationLaunchError({ message: "invalid secondary launch transport size" });
  }
  const decoded = attempt json.decode<ApplicationLaunchEnvelope>(in source);
  const envelope = match (decoded) {
    success(value) => value;
    // Decoder diagnostics may quote input; never expose private arguments.
    failure(_) => throw ApplicationLaunchError({ message: "malformed secondary launch payload" });
  };
  if (envelope.version != 1) {
    throw ApplicationLaunchError({ message: "unsupported secondary launch protocol version" });
  }
  const { launch } = move envelope;
  if (!validApplicationLaunch(in launch)) {
    throw ApplicationLaunchError({ message: "invalid or oversized secondary launch" });
  }
  return move launch;
}
