// Native application policy, not a permission a renderer can grant itself.
export enum Inspectable {
  auto,
  enabled,
  disabled,
}

internal function resolveInspectable(policy: Inspectable, applicationDefault: boolean): boolean {
  return match (policy) {
    auto => applicationDefault;
    enabled => true;
    disabled => false;
  };
}
