export interface SharedNote {
  id: string;
  title: string;
  body: string;
}

export interface CreateSharedNoteInput {
  title: string;
  body: string;
}

export interface NotesAdapter {
  list(): Promise<SharedNote[]>;
  create(input: CreateSharedNoteInput): Promise<SharedNote>;
}

export interface BenchmarkResult {
  iterations: number;
  durationMs: number;
}

export interface BenchmarkHarness {
  enabled: boolean;
  iterations?: number;
  ready(): Promise<unknown>;
  complete(result: BenchmarkResult): Promise<unknown>;
}

export function mountNotesApp(
  adapter: NotesAdapter,
  harness?: BenchmarkHarness | null,
): Promise<void>;
