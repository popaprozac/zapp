import { describe, expect, it } from "bun:test";
import {
  renderZServiceDispatchers,
} from "./z-service-dispatcher";
import type { ZServiceManifest } from "./z-service-bindings";

const manifest: ZServiceManifest = {
  schemaVersion: 3,
  types: [
    {
      name: "CreateNoteInput",
      module: "/workspace/app/notes-core.zs",
      fields: [{ name: "title", type: "String" }],
    },
    {
      name: "Note",
      module: "/workspace/app/notes-core.zs",
      fields: [
        { name: "id", type: "u64" },
        { name: "title", type: "String" },
      ],
    },
  ],
  errors: [{
    name: "NoteCreationError",
    module: "/workspace/app/notes-core.zs",
    fields: [
      { name: "code", type: "i32" },
      { name: "message", type: "String" },
      { name: "title", type: "String" },
    ],
  }],
  services: [{
    name: "notes",
    type: "NotesService",
    kind: "class",
    module: "/workspace/app/notes-service.zs",
    lifecycle: true,
    registration: {
      module: "/workspace/app/main.zs",
      offset: 100,
      line: 20,
      column: 24,
      method: "ApplicationServicesBuilder.register",
    },
    methods: [
      {
        id: 3_539_395_672,
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
        id: 1_604_992_403,
        name: "count",
        returns: "u64",
        asynchronous: true,
        executorAffinity: "thread.main",
        receiverMode: "in",
      },
    ],
  }],
};

describe("generated Z service dispatch", () => {
  it("lowers typed calls, ownership, executor placement, and codecs", () => {
    const source = renderZServiceDispatchers(manifest, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain(
      'import { CreateNoteInput, Note, NoteCreationError } from "../app/notes-core.zs";',
    );
    expect(source).toContain(
      'import { NotesService } from "../app/notes-service.zs";',
    );
    expect(source).toContain("// Static method ID: 3539395672");
    expect(source).toContain("service.create(move input)");
    expect(source).toContain("const __called = attempt service.create(move input)");
    expect(source).toContain("ServiceOutcome.typedFailure(");
    expect(source).toContain('errorType: "NoteCreationError"');
    expect(source).toContain("__zappEncodeNoteCreationError(move error)");
    expect(source).toContain("function __zappDispatchNotesServiceCreate(");
    expect(source).toContain("return __zappDispatchNotesServiceCreate(");
    expect(source).toContain("await on thread.main service.count()");
    expect(source).toContain("function __zappSelectNotesServiceAsyncMethod(");
    expect(source).toContain(
      "some(handler) => return await handler(move service, in invocation)",
    );
    expect(source).toContain("__zappDecodeCreateNoteInput");
    expect(source).toContain("__zappEncodeNote");
    expect(source).toContain("import { JsonNumber, JsonValue } from \"std/json\";");
    expect(source).toContain(
      "JsonValue.number(JsonNumber.fromI64(i64(value)))",
    );
    expect(source).toContain('ServiceOutcome.failure("UNKNOWN_METHOD")');
    expect(source).toContain(
      "class __ZappNotesServiceAdapter implements AsyncService, ServiceLifecycle",
    );
    expect(source).toContain("function __zappAdaptNotes(");
  });

  it("rejects writable request capabilities at generation time", () => {
    const invalid = structuredClone(manifest);
    invalid.services[0].methods[0].inputMode = "inout";
    expect(() => renderZServiceDispatchers(invalid, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    })).toThrow(/does not support inout input capability/);
  });

  it("preserves typed errors through suspending executor-placed dispatch", () => {
    const throwing = structuredClone(manifest);
    throwing.services[0].methods[1].error = "NoteCreationError";
    const source = renderZServiceDispatchers(throwing, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain(
      "const __called = attempt await on thread.main service.count()",
    );
    expect(source).toContain("ServiceOutcome.typedFailure(");
    expect(source).toContain('errorType: "NoteCreationError"');
    expect(source).toContain("__zappEncodeNoteCreationError(move error)");
  });

  it("decodes and transfers owned request values into suspending methods", () => {
    const suspending = structuredClone(manifest);
    suspending.services[0].methods[0].asynchronous = true;
    const source = renderZServiceDispatchers(suspending, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain("const __parsed = attempt json.parse(in invocation.arguments)");
    expect(source).toContain("const input = match (__decoded)");
    expect(source).toContain(
      "const __called = attempt await service.create(move input)",
    );
    expect(source).toContain(
      "__zappFinishNotesServiceCreate(move service, in invocation)",
    );
  });

  it("keeps synchronous struct services on the non-task adapter path", () => {
    const synchronous = structuredClone(manifest);
    synchronous.services[0].kind = "struct";
    synchronous.services[0].lifecycle = false;
    synchronous.services[0].methods = [synchronous.services[0].methods[0]];
    const source = renderZServiceDispatchers(synchronous, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain('import { Service } from "../framework/services.zs";');
    expect(source).not.toContain("import { AsyncService }");
    expect(source).toContain("class __ZappNotesServiceAdapter implements Service");
    expect(source).toContain("function __zappInvokeNotes(");
    expect(source).toContain("const target = this.service;");
    expect(source).toContain("in target");
    expect(source).toContain("new __ZappNotesServiceAdapter({ service: service })");
  });

  it("routes multiple suspending methods through one generated async adapter", () => {
    const multiple = structuredClone(manifest);
    multiple.services[0].methods.push({
      id: 2_050_071_619,
      name: "isEmpty",
      returns: "boolean",
      asynchronous: true,
      executorAffinity: "thread.main",
      receiverMode: "in",
    });
    const source = renderZServiceDispatchers(multiple, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain("async function __zappFinishNotesServiceCount(");
    expect(source).toContain("async function __zappFinishNotesServiceIsEmpty(");
    expect(source).toContain("type __ZappNotesServiceAsyncMethod = async (");
    expect(source).toContain("function __zappSelectNotesServiceAsyncMethod(");
    expect(source).toContain('if (invocation.method == "count") {');
    expect(source).toContain('if (invocation.method == "isEmpty") {');
    expect(source).toContain(
      "await __zappFinishNotesServiceCount(move service, in invocation)",
    );
    expect(source).toContain(
      "await __zappFinishNotesServiceIsEmpty(move service, in invocation)",
    );
    expect(source).toContain("return Option.some(move handler)");
    expect(source).toContain(
      "some(handler) => return await handler(move service, in invocation)",
    );
  });

  it("generates checked native codecs for arrays of service structs", () => {
    const collections = structuredClone(manifest);
    collections.types.push({
      name: "NotesPage",
      module: "/workspace/app/notes-core.zs",
      fields: [
        { name: "notes", type: "Array<Note>" },
        { name: "pages", type: "Array<Array<Note>>" },
      ],
    });
    collections.services[0].methods.push({
      id: 1,
      name: "list",
      returns: "NotesPage",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });
    collections.services[0].methods.push({
      id: 2,
      name: "replace",
      input: "NotesPage",
      inputMode: "value",
      returns: "u64",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });
    const source = renderZServiceDispatchers(collections, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain("function __zappEncodeArrayOfNote(");
    expect(source).toContain("value: Array<Note>");
    expect(source).toContain("__zappEncodeNote(copy element)");
    expect(source).toContain("function __zappEncodeArrayOfArrayOfNote(");
    expect(source).toContain("__zappEncodeArrayOfNote(copy element)");
    expect(source).toContain("__zappEncodeArrayOfNote(move notes)");
    expect(source).toContain("function __zappDecodeArrayOfNote(");
    expect(source).toContain("decoded.push(try __zappDecodeNote(in element))");
    expect(source).toContain("function __zappDecodeU64(");
    expect(source).toContain('expected an exact u64 string');
  });
});
