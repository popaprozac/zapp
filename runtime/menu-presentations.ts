/** Internal ownership table shared by menu presentation surfaces. */
export class MenuPresentations<Command extends object> {
  private readonly presentations = new Map<string, ReadonlyMap<string, Command>>();
  private readonly owners = new Map<Command, Set<string>>();

  add(token: string, commands: ReadonlyMap<string, Command>): void {
    if (this.presentations.has(token)) {
      throw new Error("menu presentation identity is already active");
    }
    // The caller's serialization table must not be able to mutate a live owner.
    const retained = new Map(commands);
    this.presentations.set(token, retained);
    for (const command of retained.values()) {
      let owners = this.owners.get(command);
      if (!owners) this.owners.set(command, owners = new Set());
      owners.add(token);
    }
  }

  remove(token: string): void {
    const commands = this.presentations.get(token);
    if (!commands) return;
    this.presentations.delete(token);
    for (const command of commands.values()) {
      const owners = this.owners.get(command);
      owners?.delete(token);
      if (owners?.size === 0) this.owners.delete(command);
    }
  }

  command(token: string, id: string): Command | undefined {
    return this.presentations.get(token)?.get(id);
  }

  tokensFor(command: Command): readonly string[] {
    return [...(this.owners.get(command) ?? [])];
  }

  clear(): void {
    this.presentations.clear();
    this.owners.clear();
  }
}
