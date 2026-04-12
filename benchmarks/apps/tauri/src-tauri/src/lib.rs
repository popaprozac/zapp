use std::time::{SystemTime, UNIX_EPOCH};

#[derive(serde::Serialize)]
struct Pong {
    pong: u128,
}

#[tauri::command]
fn ping() -> Pong {
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    Pong { pong: ms }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![ping])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
