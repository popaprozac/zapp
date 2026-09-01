import { describe, expect, it } from "bun:test";
import {
  deriveZServiceManifest,
  parseZProgramMetadata,
  type ZProgramMetadata,
  zServiceMethodId,
} from "./z-program-metadata";

const metadata: ZProgramMetadata = {
  schemaVersion: 1,
  entry: 0,
  modules: [{
    path: "/app.zs",
    symbols: [
      {
        name: "CreateNoteInput",
        kind: "struct",
        exported: true,
        typeSignature: {
          implementedTraits: [],
          fields: [{
            name: "title",
            typeName: "String",
            visibility: "public",
            optionalField: false,
          }],
          methods: [],
        },
      },
      {
        name: "Note",
        kind: "struct",
        exported: true,
        typeSignature: {
          implementedTraits: [],
          fields: [
            { name: "id", typeName: "u64", visibility: "public", optionalField: false },
            { name: "title", typeName: "String", visibility: "public", optionalField: false },
          ],
          methods: [],
        },
      },
      {
        name: "NoteCreationError",
        kind: "struct",
        exported: true,
        typeSignature: {
          implementedTraits: [],
          fields: [
            { name: "message", typeName: "String", visibility: "public", optionalField: false },
            { name: "title", typeName: "String", visibility: "public", optionalField: false },
          ],
          methods: [],
        },
      },
      {
        name: "NotesService",
        kind: "class",
        exported: true,
        typeSignature: {
          implementedTraits: ["ServiceLifecycle"],
          fields: [],
          methods: [
            {
              name: "create",
              staticMethod: false,
              visibility: "public",
              receiverMode: "in",
              signature: {
                asynchronous: false,
                executorAffinity: null,
                parameterModes: ["value"],
                parameterTypes: ["CreateNoteInput"],
                returnType: "Note",
                errorType: "NoteCreationError",
              },
            },
            {
              name: "count",
              staticMethod: false,
              visibility: "public",
              receiverMode: "in",
              signature: {
                asynchronous: true,
                executorAffinity: "thread.main",
                parameterModes: [],
                parameterTypes: [],
                returnType: "u64",
                errorType: null,
              },
            },
            {
              name: "start",
              staticMethod: false,
              visibility: "public",
              receiverMode: "in",
              signature: {
                asynchronous: false,
                executorAffinity: "thread.main",
                parameterModes: ["in"],
                parameterTypes: ["ApplicationContext"],
                returnType: "void",
                errorType: "ServiceLifecycleError",
              },
            },
            {
              name: "stop",
              staticMethod: false,
              visibility: "public",
              receiverMode: "in",
              signature: {
                asynchronous: false,
                executorAffinity: "thread.main",
                parameterModes: ["in"],
                parameterTypes: ["ApplicationContext"],
                returnType: "void",
                errorType: "ServiceLifecycleError",
              },
            },
          ],
        },
      },
    ],
    calls: [{
      offset: 100,
      line: 20,
      column: 24,
      target: {
        module: "/services.zs",
        symbol: "ApplicationServicesBuilder",
        kind: "method",
        name: "ApplicationServicesBuilder.register",
      },
      arguments: [
        { kind: "string", type: "String", value: "notes" },
        { kind: "other", type: "NotesService" },
      ],
    }],
  }],
};

describe("compiler-produced Z program metadata", () => {
  it("derives the typed service manifest without scanning Z source", () => {
    expect(deriveZServiceManifest(metadata)).toEqual({
      schemaVersion: 4,
      types: [
        {
          name: "CreateNoteInput",
          module: "/app.zs",
          fields: [{ name: "title", type: "String" }],
        },
        {
          name: "Note",
          module: "/app.zs",
          fields: [
            { name: "id", type: "u64" },
            { name: "title", type: "String" },
          ],
        },
      ],
      enums: [],
      errors: [{
        name: "NoteCreationError",
        module: "/app.zs",
        fields: [
          { name: "message", type: "String" },
          { name: "title", type: "String" },
        ],
      }],
      services: [{
        name: "notes",
        type: "NotesService",
        kind: "class",
        module: "/app.zs",
        lifecycle: true,
        registration: {
          module: "/app.zs",
          offset: 100,
          line: 20,
          column: 24,
          method: "ApplicationServicesBuilder.register",
        },
        methods: [
          {
            id: zServiceMethodId("notes.create"),
            name: "create",
            input: "CreateNoteInput",
            inputMode: "value",
            returns: "Note",
            error: "NoteCreationError",
            asynchronous: false,
            executorAffinity: null,
            receiverMode: "in",
          },
          {
            id: zServiceMethodId("notes.count"),
            name: "count",
            returns: "u64",
            asynchronous: true,
            executorAffinity: "thread.main",
            receiverMode: "in",
          },
        ],
      }],
    });
  });

  it("derives lifecycle and async execution from an ordinary service", () => {
    const service = metadata.modules[0].symbols.find(
      (symbol) => symbol.name === "NotesService",
    );
    expect(service?.typeSignature?.implementedTraits).toEqual(["ServiceLifecycle"]);
    const derived = deriveZServiceManifest(metadata).services[0];
    expect(derived.lifecycle).toBe(true);
    expect(derived.methods.find((method) => method.name === "count")).toMatchObject({
      asynchronous: true,
      executorAffinity: "thread.main",
    });
  });

  it("retains typed async and executor contracts for dispatcher generation", () => {
    expect(deriveZServiceManifest(metadata).services[0].methods).toContainEqual({
      id: zServiceMethodId("notes.count"),
      name: "count",
      returns: "u64",
      asynchronous: true,
      executorAffinity: "thread.main",
      receiverMode: "in",
    });
  });

  it("derives Array<T> service shapes without treating Array as a nominal export", () => {
    const collections = structuredClone(metadata);
    const service = collections.modules[0].symbols.find(
      (symbol) => symbol.name === "NotesService",
    )!;
    service.typeSignature!.methods.push({
      name: "list",
      staticMethod: false,
      visibility: "public",
      receiverMode: "in",
      signature: {
        asynchronous: false,
        executorAffinity: null,
        parameterModes: [],
        parameterTypes: [],
        returnType: "Array<Note>",
        errorType: null,
      },
    });

    const derived = deriveZServiceManifest(collections);
    expect(derived.services[0].methods).toContainEqual({
      id: zServiceMethodId("notes.list"),
      name: "list",
      returns: "Array<Note>",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });
    expect(derived.types.filter((type) => type.name === "Note")).toHaveLength(1);
  });

  it("derives explicit options and optional struct fields as distinct wire contracts", () => {
    const optional = structuredClone(metadata);
    const input = optional.modules[0].symbols.find(
      (symbol) => symbol.name === "CreateNoteInput",
    )!;
    input.typeSignature!.fields.push({
      name: "subtitle",
      typeName: "Option<String>",
      visibility: "public",
      optionalField: true,
    });
    const service = optional.modules[0].symbols.find(
      (symbol) => symbol.name === "NotesService",
    )!;
    service.typeSignature!.methods.push({
      name: "find",
      staticMethod: false,
      visibility: "public",
      receiverMode: "in",
      signature: {
        asynchronous: false,
        executorAffinity: null,
        parameterModes: ["value"],
        parameterTypes: ["Option<u64>"],
        returnType: "Option<Note>",
        errorType: null,
      },
    });

    const derived = deriveZServiceManifest(optional);
    expect(derived.types.find((type) => type.name === "CreateNoteInput")?.fields)
      .toContainEqual({
        name: "subtitle",
        type: "Option<String>",
        optional: true,
      });
    expect(derived.services[0].methods).toContainEqual({
      id: zServiceMethodId("notes.find"),
      name: "find",
      input: "Option<u64>",
      inputMode: "value",
      returns: "Option<Note>",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });
    expect(derived.types.filter((type) => type.name === "Note")).toHaveLength(1);
  });

  it("derives payload-free enums as named string wire contracts", () => {
    const withEnum = structuredClone(metadata);
    withEnum.modules[0].symbols.push({
      name: "NoteState",
      kind: "enum",
      exported: true,
      typeSignature: {
        implementedTraits: [],
        fields: [],
        methods: [],
        variants: [
          { name: "active", payloadType: null },
          { name: "archived", payloadType: null },
        ],
      },
    });
    withEnum.modules[0].symbols.find((symbol) => symbol.name === "Note")!
      .typeSignature!.fields.push({
        name: "state",
        typeName: "NoteState",
        visibility: "public",
        optionalField: false,
      });

    const derived = deriveZServiceManifest(withEnum);
    expect(derived.enums).toEqual([{
      name: "NoteState",
      module: "/app.zs",
      variants: ["active", "archived"],
    }]);
    expect(derived.types.find((type) => type.name === "Note")?.fields)
      .toContainEqual({ name: "state", type: "NoteState" });
  });

  it("rejects payload enums until their tagged wire representation is settled", () => {
    const withPayload = structuredClone(metadata);
    withPayload.modules[0].symbols.push({
      name: "LookupResult",
      kind: "enum",
      exported: true,
      typeSignature: {
        implementedTraits: [],
        fields: [],
        methods: [],
        variants: [
          { name: "found", payloadType: "Note" },
          { name: "missing", payloadType: null },
        ],
      },
    });
    withPayload.modules[0].symbols.find((symbol) => symbol.name === "NotesService")!
      .typeSignature!.methods.push({
        name: "lookup",
        staticMethod: false,
        visibility: "public",
        receiverMode: "in",
        signature: {
          asynchronous: false,
          executorAffinity: null,
          parameterModes: [],
          parameterTypes: [],
          returnType: "LookupResult",
          errorType: null,
        },
      });

    expect(() => deriveZServiceManifest(withPayload)).toThrow(
      "service wire enum LookupResult.found carries payload \"Note\"; "
      + "payload enum wire representation is not settled yet",
    );
  });

  it("assigns stable static method IDs", () => {
    expect(zServiceMethodId("notes.create")).toBe(3_539_395_672);
    expect(zServiceMethodId("notes.count")).toBe(1_604_992_403);
  });

  it("fails closed on unknown compiler schemas", () => {
    expect(() => parseZProgramMetadata('{"schemaVersion":2,"entry":0,"modules":[]}'))
      .toThrow(/unsupported Z program metadata schema 2/);
  });

  it("fails closed when method execution metadata is absent", () => {
    const invalid = JSON.parse(JSON.stringify(metadata));
    delete invalid.modules[0].symbols[3].typeSignature.methods[0]
      .signature.executorAffinity;
    expect(() => parseZProgramMetadata(JSON.stringify(invalid)))
      .toThrow(/method 0 execution contract/);
  });

  it("requires literal registration names", () => {
    const invalid = structuredClone(metadata);
    invalid.modules[0].calls[0].arguments[0] = { kind: "other", type: "String" };
    expect(() => deriveZServiceManifest(invalid))
      .toThrow(/requires a literal service name/);
  });

  it("retains typed errors for suspending service methods", () => {
    const throwing = structuredClone(metadata);
    throwing.modules[0].symbols[3].typeSignature!.methods[1].signature.errorType =
      "NoteCreationError";
    const manifest = deriveZServiceManifest(throwing);
    expect(manifest.services[0].methods[1].error).toBe("NoteCreationError");
    expect(manifest.errors.map((error) => error.name)).toContain(
      "NoteCreationError",
    );
  });

  it("ignores framework-internal builder delegation", () => {
    const delegated = structuredClone(metadata);
    delegated.modules[0].calls.unshift({
      offset: 50,
      line: 10,
      column: 12,
      target: {
        module: "/services.zs",
        symbol: "ServicesBuilder",
        kind: "method",
        name: "ServicesBuilder.register",
      },
      arguments: [
        { kind: "other", type: "String" },
        { kind: "other", type: "T" },
      ],
    });
    expect(deriveZServiceManifest(delegated).services).toHaveLength(1);
  });
});
