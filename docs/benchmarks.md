# Performance Benchmarks

All benchmarks compare minimal "hello world" equivalent apps across frameworks, measuring binary size, memory usage, startup time, and bridge call throughput.

## macOS

**Machine:** Mac Studio, M4 Max, 36 GB RAM, macOS 26.4

### Binary Size

| Framework   | Size      |
|-------------|-----------|
| Zapp        | 173 KB    |
| Wails       | 7.5 MB    |
| Tauri       | 8.2 MB    |
| Electrobun  | 69.2 MB   |
| Electron    | 263.2 MB  |

### Memory (footprint)

| Framework   | Footprint |
|-------------|-----------|
| Zapp        | 25 MB     |
| Tauri       | 27 MB     |
| Wails       | 31 MB     |
| Electrobun  | 96 MB     |

Electrobun's footprint includes the Bun child process.

### Startup Time

| Framework   | Time     |
|-------------|----------|
| Zapp        | ~170 ms  |
| Wails       | ~170 ms  |
| Tauri       | ~170 ms  |
| Electrobun  | ~529 ms  |
| Electron    | ~831 ms  |

All WebKit-based frameworks (Zapp, Wails, Tauri) hit the same ~170 ms measurement floor. See the methodology section below.

### Bridge Throughput

| Operation | Latency        | Throughput       |
|-----------|----------------|------------------|
| Invoke    | 0.085 ms/call  | 11,765 calls/sec |
| Emit      | 0.002 ms/call  | 500,000/sec      |

## Windows

**Machine:** Intel i9-7940X, 96 GB RAM, Windows 11

### Binary Size

| Framework       | Size      |
|-----------------|-----------|
| Zapp (no workers) | 202 KB  |
| Zapp (+ QJS)    | 960 KB    |
| Tauri           | 8.5 MB    |
| Wails           | 8.7 MB    |
| Electron        | 343 MB    |

### Memory

| Framework | Working Set | Private Bytes |
|-----------|-------------|---------------|
| Zapp      | 22 MB       | 3.6 MB        |
| Tauri     | 26 MB       | 4.2 MB        |
| Wails     | 30 MB       | 19.2 MB       |
| Electron  | 91 MB       | 37.8 MB       |

### Startup Time

| Framework   | Time       |
|-------------|------------|
| Zapp        | ~516 ms    |
| Tauri       | ~516 ms    |
| Wails       | ~516 ms    |
| Electron    | 1,029 ms   |

Zapp, Tauri, and Wails all share the same ~516 ms floor imposed by WebView2 initialization. See the methodology section below.

### Bridge Throughput

| Operation | Latency        |
|-----------|----------------|
| Invoke    | 0.307 ms/call  |
| Emit      | 0.005 ms/call  |

## Methodology

**Binary size** is the size of the final release binary (or `.app` bundle contents on macOS) after a standard release build with no additional stripping beyond framework defaults.

**Memory** is measured after the app has fully launched and rendered its first frame. On macOS, "footprint" is the value reported by `memory_resource` / Activity Monitor's "Memory" column. On Windows, "Working Set" and "Private Bytes" are taken from Task Manager / Performance Monitor.

**Startup time** is measured from process launch to first content paint. The measurement uses a sleep-based timing approach, which introduces a floor -- the smallest measurable interval is bounded by the sleep granularity and WebView initialization overhead. This is why all WebKit frameworks on macOS cluster at ~170 ms and all WebView2 frameworks on Windows cluster at ~516 ms. These numbers represent an upper bound on the measurement floor, not necessarily the true startup time.

**Bridge throughput** measures round-trip calls from the webview to native code and back (invoke), and one-way native-to-webview event delivery (emit). Results are averaged over 10,000+ calls after a warmup period.

For full reproduction steps and raw data, see `benchmarks/RESULTS.md`.
