use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

const DATABASE_PATH: &str = "/tmp/z-notes-benchmark-tauri.sqlite3";
const BENCHMARK_CONTROL_PATH: &str = "/tmp/z-notes-benchmark-tauri.control";
const BENCHMARK_READY_PATH: &str = "/tmp/z-notes-benchmark-tauri.ready";
const BENCHMARK_RESULT_PATH: &str = "/tmp/z-notes-benchmark-tauri.result.json";

#[derive(Serialize)]
struct Note {
    id: String,
    title: String,
    body: String,
}

#[derive(Deserialize)]
struct CreateNoteInput {
    title: String,
    body: String,
}

#[derive(Deserialize)]
struct BenchmarkReport {
    phase: String,
    payload: String,
}

fn with_database<T>(operation: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T, String> {
    let database = Connection::open(DATABASE_PATH).map_err(|error| error.to_string())?;
    database
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS notes (\
               id INTEGER PRIMARY KEY,\
               title TEXT NOT NULL,\
               body TEXT NOT NULL\
             );\
             INSERT OR IGNORE INTO notes (id, title, body) VALUES\
               (1, 'Welcome to Z Notes', 'A native notes application implemented across desktop frameworks.'),\
               (2, 'One workload', 'The frontend, storage behavior, and workflow stay equivalent.');",
        )
        .map_err(|error| error.to_string())?;
    operation(&database).map_err(|error| error.to_string())
}

#[tauri::command]
fn list_notes() -> Result<Vec<Note>, String> {
    with_database(|database| {
        let mut statement = database.prepare("SELECT id, title, body FROM notes ORDER BY id")?;
        let notes = statement.query_map([], |row| {
            Ok(Note {
                id: row.get::<_, i64>(0)?.to_string(),
                title: row.get(1)?,
                body: row.get(2)?,
            })
        })?;
        notes.collect()
    })
}

#[tauri::command]
fn create_note(input: CreateNoteInput) -> Result<Note, String> {
    if input.title.is_empty() {
        return Err("a note title is required".into());
    }
    with_database(|database| {
        let id: i64 = database.query_row(
            "SELECT COALESCE(MAX(id), 0) + 1 FROM notes",
            [],
            |row| row.get(0),
        )?;
        database.execute(
            "INSERT INTO notes (id, title, body) VALUES (?, ?, ?)",
            params![id, input.title, input.body],
        )?;
        Ok(Note {
            id: id.to_string(),
            title: input.title,
            body: input.body,
        })
    })
}

#[tauri::command]
fn benchmark_mode() -> bool {
    Path::new(BENCHMARK_CONTROL_PATH).exists()
}

#[tauri::command]
fn report_benchmark(report: BenchmarkReport) -> Result<bool, String> {
    let path = if report.phase == "ready" {
        BENCHMARK_READY_PATH
    } else {
        BENCHMARK_RESULT_PATH
    };
    fs::write(path, report.payload)
        .map(|_| true)
        .map_err(|error| error.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            list_notes,
            create_note,
            benchmark_mode,
            report_benchmark,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Tauri application");
}
