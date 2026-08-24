import { describe, expect, it } from "bun:test";
import {
  deriveZServiceManifest,
  parseZProgramMetadata,
  type ZProgramMetadata,
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
        name: "NotesService",
        kind: "class",
        exported: true,
        typeSignature: {
          implementedTraits: ["Service", "ServiceLifecycle"],
          fields: [],
          methods: [
            {
              name: "create",
              staticMethod: false,
              visibility: "public",
              signature: {
                asynchronous: false,
                parameterModes: ["value"],
                parameterTypes: ["CreateNoteInput"],
                returnType: "Note",
                errorType: null,
              },
            },
            {
              name: "count",
              staticMethod: false,
              visibility: "public",
              signature: {
                asynchronous: false,
                parameterModes: [],
                parameterTypes: [],
                returnType: "u64",
                errorType: null,
              },
            },
            {
              name: "invoke",
              staticMethod: false,
              visibility: "public",
              signature: {
                asynchronous: false,
                parameterModes: ["in"],
                parameterTypes: ["ServiceInvocation"],
                returnType: "ServiceOutcome",
                errorType: null,
              },
            },
            {
              name: "start",
              staticMethod: false,
              visibility: "public",
              signature: {
                asynchronous: false,
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
              signature: {
                asynchronous: false,
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
      target: {
        module: "/services.zs",
        symbol: "ApplicationServicesBuilder",
        kind: "method",
        name: "ApplicationServicesBuilder.registerWithLifecycle",
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
      schemaVersion: 1,
      types: [
        { name: "CreateNoteInput", fields: [{ name: "title", type: "String" }] },
        {
          name: "Note",
          fields: [
            { name: "id", type: "u64" },
            { name: "title", type: "String" },
          ],
        },
      ],
      services: [{
        name: "notes",
        type: "NotesService",
        methods: [
          { name: "create", input: "CreateNoteInput", returns: "Note" },
          { name: "count", returns: "u64" },
        ],
      }],
    });
  });

  it("fails closed on unknown compiler schemas", () => {
    expect(() => parseZProgramMetadata('{"schemaVersion":2,"entry":0,"modules":[]}'))
      .toThrow(/unsupported Z program metadata schema 2/);
  });

  it("requires literal registration names", () => {
    const invalid = structuredClone(metadata);
    invalid.modules[0].calls[0].arguments[0] = { kind: "other", type: "String" };
    expect(() => deriveZServiceManifest(invalid))
      .toThrow(/requires a literal service name/);
  });
});
