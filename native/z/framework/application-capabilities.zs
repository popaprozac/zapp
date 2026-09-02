import { Map, Set } from "std/collections";

export readonly struct CapabilityProfile {
  permissions: readonly Array<String>;
  serviceMethods: readonly Array<String>;
  workerIds: readonly Array<String>;
}

export readonly class CapabilitySelection {
  readonly names: readonly Array<String>;
  readonly permissions: readonly Set<String>;
  readonly serviceMethods: readonly Set<String>;
  readonly workerIds: readonly Set<String>;

  function allowsPermission(in permission: String): boolean {
    return this.permissions.has(permission);
  }

  function allowsService(in method: String): boolean {
    return this.serviceMethods.has(method);
  }

  function allowsWorker(in id: String): boolean {
    return this.workerIds.has(id);
  }

  function copyNames(): Array<String> {
    let copied = Array<String>();
    let index: usize = 0;
    while (index < this.names.length) {
      const name: String = this.names[index].copyBytes(
        0,
        this.names[index].byteLength
      );
      copied.push(move name);
      index = index + 1;
    }
    return copied;
  }
}

// Immutable policy compiled from zapp.config.ts. Profiles are selected only
// by trusted native WindowOptions and checked at the bridge boundary.
export readonly class ApplicationCapabilities {
  readonly profiles: readonly Map<String, CapabilityProfile>;

  function hasProfile(in name: String): boolean {
    return this.profiles.has(name);
  }

  function resolveProfiles(
    in selectedProfiles: Array<String>
  ): Option<CapabilitySelection> {
    let names = Array<String>();
    let permissions = Set<String>();
    let serviceMethods = Set<String>();
    let workerIds = Set<String>();
    for (const name of selectedProfiles) {
      const found = this.profiles.get(name);
      match (in found) {
        some(profile) => {
          names.push(name.copyBytes(0, name.byteLength));
          let permissionIndex: usize = 0;
          while (permissionIndex < profile.permissions.length) {
            const permission: String = profile.permissions[
              permissionIndex
            ].copyBytes(
              0,
              profile.permissions[permissionIndex].byteLength
            );
            permissions.add(move permission);
            permissionIndex = permissionIndex + 1;
          }
          let methodIndex: usize = 0;
          while (methodIndex < profile.serviceMethods.length) {
            const method: String = profile.serviceMethods[
              methodIndex
            ].copyBytes(
              0,
              profile.serviceMethods[methodIndex].byteLength
            );
            serviceMethods.add(move method);
            methodIndex = methodIndex + 1;
          }
          let workerIndex: usize = 0;
          while (workerIndex < profile.workerIds.length) {
            const workerId: String = profile.workerIds[
              workerIndex
            ].copyBytes(
              0,
              profile.workerIds[workerIndex].byteLength
            );
            workerIds.add(move workerId);
            workerIndex = workerIndex + 1;
          }
        }
        none => return Option<CapabilitySelection>.none;
      }
    }
    return Option.some(new CapabilitySelection({
      names: names.freeze(),
      permissions: permissions.freeze(),
      serviceMethods: serviceMethods.freeze(),
      workerIds: workerIds.freeze(),
    }));
  }
}
