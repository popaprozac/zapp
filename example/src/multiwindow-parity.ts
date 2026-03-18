import { Window, Worker } from '@zapp/runtime'

type TestResult = {
  name: string
  status: 'passed' | 'failed'
  details: string
}

type MultiWindowReport = {
  results: TestResult[]
}

type MultiWindowParityGlobal = typeof globalThis & {
  __zappMultiWindowParity?: {
    lastReport: MultiWindowReport | null
    run: () => Promise<MultiWindowReport>
  }
}

const g = globalThis as MultiWindowParityGlobal

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

const addResult = (results: TestResult[], name: string, passed: boolean, details: string): void => {
  results.push({ name, status: passed ? 'passed' : 'failed', details })
}

export const runMultiWindowParitySuite = async (): Promise<MultiWindowReport> => {
  const results: TestResult[] = []
  const report: MultiWindowReport = { results }

  // 1. Create a window from the frontend
  try {
    const win = await Window.create({
      title: 'Parity Test Window',
      width: 400,
      height: 300,
      visible: true,
    })
    addResult(results, 'window create from frontend', typeof win.id === 'string' && win.id.length > 0, win.id)

    // 2. Window actions
    try {
      win.setTitle('Updated Title')
      await delay(100)
      win.minimize()
      await delay(200)
      win.unminimize()
      await delay(200)
      addResult(results, 'window actions (setTitle, minimize, unminimize)', true, 'no errors')
    } catch (error) {
      addResult(results, 'window actions (setTitle, minimize, unminimize)', false, String(error))
    }

    // 3. Create a worker in the current (main) window context
    try {
      const mainWorker = new Worker(new URL('./parity-worker.ts', import.meta.url))
      const mainMsg = await new Promise<unknown>((resolve, reject) => {
        mainWorker.addEventListener('message', (e) => resolve((e as MessageEvent).data), { once: true })
        setTimeout(() => reject(new Error('timeout')), 3000)
        mainWorker.postMessage({ type: 'echo', payload: { from: 'main-window' } })
      })
      mainWorker.terminate()
      addResult(results, 'worker in main window', true, JSON.stringify(mainMsg))
    } catch (error) {
      addResult(results, 'worker in main window', false, String(error))
    }

    // 4. Close the created window
    try {
      win.close()
      await delay(300)
      addResult(results, 'window close', true, `closed ${win.id}`)
    } catch (error) {
      addResult(results, 'window close', false, String(error))
    }
  } catch (error) {
    addResult(results, 'window create from frontend', false, error instanceof Error ? error.message : String(error))
  }

  // 5. Create a window with custom URL
  try {
    const win2 = await Window.create({
      title: 'Custom URL Window',
      width: 400,
      height: 300,
      url: '/index.html',
      visible: true,
    })
    addResult(results, 'window create with url', typeof win2.id === 'string' && win2.id.length > 0, win2.id)
    await delay(500)
    win2.close()
  } catch (error) {
    addResult(results, 'window create with url', false, error instanceof Error ? error.message : String(error))
  }

  // 6. Window.current() returns a valid handle
  try {
    const current = Window.current()
    addResult(results, 'Window.current() returns handle', typeof current.id === 'string' && current.id.length > 0, current.id)
  } catch (error) {
    addResult(results, 'Window.current() returns handle', false, error instanceof Error ? error.message : String(error))
  }

  g.__zappMultiWindowParity = {
    lastReport: report,
    run: runMultiWindowParitySuite,
  }

  console.table(report.results)
  return report
}

g.__zappMultiWindowParity = {
  lastReport: null,
  run: runMultiWindowParitySuite,
}
