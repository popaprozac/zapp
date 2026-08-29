export interface Note {
  id: string;
  title: string;
  body: string;
}

export interface CreateNoteInput {
  title: string;
  body: string;
}

export interface BenchmarkReport {
  phase: string;
  payload: string;
}

export type NotesRPC = {
  bun: {
    requests: {
      list: { params: {}; response: Note[] };
      create: { params: CreateNoteInput; response: Note };
      benchmarkMode: { params: {}; response: boolean };
      reportBenchmark: { params: BenchmarkReport; response: boolean };
    };
    messages: {};
  };
  webview: {
    requests: {};
    messages: {};
  };
};
