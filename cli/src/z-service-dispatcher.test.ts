import { describe, expect, it } from "bun:test";
import {
  renderZServiceDispatchers,
} from "./z-service-dispatcher";
import type { ZServiceManifest } from "./z-service-bindings";

const manifest: ZServiceManifest = {
  schemaVersion: 5,
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
  enums: [],
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

  it("widens generated integer bounds before checked comparison", () => {
    const scalar = structuredClone(manifest);
    scalar.services[0].methods[0].input = "i32";
    scalar.services[0].methods[0].returns = "i32";
    scalar.services[0].methods[0].error = undefined;
    const source = renderZServiceDispatchers(scalar, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain(
      "integer < -i64(2147483648) || integer > i64(2147483647)",
    );
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

  it("taskifies synchronous executor-placed methods behind a generated wrapper", () => {
    const placed = structuredClone(manifest);
    placed.services[0].methods[1].asynchronous = false;
    const source = renderZServiceDispatchers(placed, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain(
      "async function __zappCallNotesServiceCountOnMain(\n  service: NotesService",
    );
    expect(source).toContain(
      "): u64 on thread.main {\n  return service.count();\n}",
    );
    expect(source).toContain(
      "await on thread.main __zappCallNotesServiceCountOnMain(move service)",
    );
  });

  it("moves owned input and typed failures through a synchronous placed wrapper", () => {
    const placed = structuredClone(manifest);
    placed.services[0].methods[0].executorAffinity = "thread.main";
    const source = renderZServiceDispatchers(placed, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain(
      "async function __zappCallNotesServiceCreateOnMain(\n"
        + "  service: NotesService,\n  input: CreateNoteInput",
    );
    expect(source).toContain(
      "): Note throws NoteCreationError on thread.main {\n"
        + "  return try service.create(move input);\n}",
    );
    expect(source).toContain(
      "const __called = attempt await on thread.main "
        + "__zappCallNotesServiceCreateOnMain(move service, move input)",
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

  it("generates native Option codecs for null, payloads, and omitted optional fields", () => {
    const optional = structuredClone(manifest);
    optional.types.push({
      name: "NoteSelection",
      module: "/workspace/app/notes-core.zs",
      fields: [
        { name: "selected", type: "Option<Note>" },
        { name: "subtitle", type: "Option<String>", optional: true },
      ],
    });
    optional.services[0].methods.push({
      id: 2,
      name: "find",
      input: "Option<u64>",
      inputMode: "value",
      returns: "Option<Note>",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });
    optional.services[0].methods.push({
      id: 3,
      name: "selection",
      input: "NoteSelection",
      inputMode: "value",
      returns: "NoteSelection",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });

    const source = renderZServiceDispatchers(optional, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain("function __zappDecodeOptionOfU64(");
    expect(source).toContain("nullValue => Option<u64>.none");
    expect(source).toContain("const decoded = try __zappDecodeU64(in value)");
    expect(source).toContain("select Option.some(decoded)");
    expect(source).toContain("function __zappEncodeOptionOfNote(");
    expect(source).toContain("some(value) => __zappEncodeNote(");
    expect(source).toContain("none => JsonValue.nullValue");
    expect(source).toContain("none => Option<String>.none");
    expect(source).toContain("__zappEncodeOptionOfString(move subtitle)");
  });

  it("generates exhaustive native codecs for payload-free enums", () => {
    const withEnum = structuredClone(manifest);
    withEnum.enums.push({
      name: "NoteState",
      module: "/workspace/app/notes-core.zs",
      variants: [{ name: "active" }, { name: "archived" }],
    });
    withEnum.types[0].fields.push({ name: "state", type: "NoteState" });
    withEnum.types[1].fields.push({ name: "state", type: "NoteState" });
    withEnum.services[0].methods.push({
      id: 4,
      name: "echoState",
      input: "NoteState",
      inputMode: "value",
      returns: "NoteState",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });

    const source = renderZServiceDispatchers(withEnum, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain("NoteState } from \"../app/notes-core.zs\"");
    expect(source).toContain("function __zappDecodeNoteState(");
    expect(source).toContain('if (text == "active") return NoteState.active');
    expect(source).toContain('if (text == "archived") return NoteState.archived');
    expect(source).toContain("function __zappEncodeNoteState(");
    expect(source).toContain('active => JsonValue.string("active")');
    expect(source).toContain('archived => JsonValue.string("archived")');
    expect(source).toContain("const result = service.echoState(input)");
    expect(source).not.toContain("service.echoState(move input)");
    expect(source).toContain("__zappEncodeNoteState(\n    result\n  )");
  });

  it("generates tagged native codecs and ownership for payload enums", () => {
    const withEnum = structuredClone(manifest);
    withEnum.enums.push({
      name: "NoteDescription",
      module: "/workspace/app/notes-core.zs",
      variants: [
        { name: "described", payload: "String" },
        { name: "unavailable" },
      ],
    });
    withEnum.services[0].methods.push({
      id: 5,
      name: "echoDescription",
      input: "NoteDescription",
      inputMode: "value",
      returns: "NoteDescription",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });

    const source = renderZServiceDispatchers(withEnum, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain('const __kind = fields.get("kind")');
    expect(source).toContain('if (kind == "described")');
    expect(source).toContain('const __payload = fields.get("value")');
    expect(source).toContain("return NoteDescription.described(\n          move decoded");
    expect(source).toContain("described(value) => {");
    expect(source).toContain('fields.set("kind", JsonValue.string("described"))');
    expect(source).toContain("__zappEncodeString(\n        move value");
    expect(source).toContain("const result = service.echoDescription(move input)");
    expect(source).toContain("__zappEncodeNoteDescription(\n    move result");
  });

  it("keeps cleanup-free payload enums copyable", () => {
    const withEnum = structuredClone(manifest);
    withEnum.enums.push({
      name: "CountResult",
      module: "/workspace/app/notes-core.zs",
      variants: [
        { name: "count", payload: "i32" },
        { name: "unavailable" },
      ],
    });
    withEnum.services[0].methods.push({
      id: 6,
      name: "echoCount",
      input: "CountResult",
      inputMode: "value",
      returns: "CountResult",
      asynchronous: false,
      executorAffinity: null,
      receiverMode: "in",
    });

    const source = renderZServiceDispatchers(withEnum, {
      outputPath: "/workspace/generated/service-dispatchers.zs",
      serviceContractModule: "/workspace/framework/service-contract.zs",
      servicesModule: "/workspace/framework/services.zs",
      asyncServiceContractModule: "/workspace/framework/async-service-contract.zs",
      serviceLifecycleContractModule: "/workspace/framework/service-lifecycle-contract.zs",
    });
    expect(source).toContain("return CountResult.count(\n          decoded");
    expect(source).toContain("__zappEncodeI32(\n        value");
    expect(source).toContain("const result = service.echoCount(input)");
    expect(source).toContain("__zappEncodeCountResult(\n    result");
  });
});
