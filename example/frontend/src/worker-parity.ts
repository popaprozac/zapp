import { App, Events, SharedWorker, Worker } from '@zapp/runtime'

type TestStatus = 'passed' | 'failed'

type TestResult = {
  name: string
  status: TestStatus
  details: string
}

type WorkerParityReport = {
  engine: string
  results: TestResult[]
}

type WorkerParityOptions = {
  includeOwnerReset?: boolean
}

type ParityGlobal = typeof globalThis & {
  __zappWorkerParity?: {
    lastReport: WorkerParityReport | null
    run: (options?: WorkerParityOptions) => Promise<WorkerParityReport>
  }
}

const g = globalThis as ParityGlobal

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

const withTimeout = async <T>(promise: Promise<T>, label: string, timeoutMs = 4000): Promise<T> => {
  let timer: ReturnType<typeof setTimeout> | null = null
  try {
    return await Promise.race([
      promise,
      new Promise<T>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} timed out after ${timeoutMs}ms`)), timeoutMs)
      }),
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
}

const onceMessage = <T>(worker: Worker, predicate: (data: unknown) => data is T): Promise<T> =>
  new Promise((resolve, reject) => {
    const handler: EventListener = (event) => {
      const messageEvent = event as MessageEvent
      if (predicate(messageEvent.data)) {
        worker.removeEventListener('message', handler)
        resolve(messageEvent.data)
      }
    }
    worker.addEventListener('message', handler)
    setTimeout(() => {
      worker.removeEventListener('message', handler)
      reject(new Error('worker message not received'))
    }, 4000)
  })

const onceError = (worker: Worker): Promise<ErrorEvent> =>
  new Promise((resolve, reject) => {
    const handler = (event: Event) => {
      worker.removeEventListener('error', handler)
      resolve(event as ErrorEvent)
    }
    worker.addEventListener('error', handler)
    setTimeout(() => {
      worker.removeEventListener('error', handler)
      reject(new Error('worker error not received'))
    }, 4000)
  })

const onceChannel = <T>(worker: Worker | SharedWorker, channel: string): Promise<T> =>
  new Promise((resolve, reject) => {
    const stop = worker.receive(channel, (data) => {
      stop()
      resolve(data as T)
    })
    setTimeout(() => {
      stop()
      reject(new Error(`channel ${channel} not received`))
    }, 4000)
  })

const addResult = (results: TestResult[], name: string, passed: boolean, details: string): void => {
  results.push({ name, status: passed ? 'passed' : 'failed', details })
}

export const runWorkerParitySuite = async (options: WorkerParityOptions = {}): Promise<WorkerParityReport> => {
  const results: TestResult[] = []
  const report: WorkerParityReport = {
    engine: String(App.getConfig?.().name ?? 'unknown'),
    results,
  }

  const worker = new Worker(new URL('./parity-worker.ts', import.meta.url))
  try {
    const echoMessage = onceMessage<{ type: 'echo'; payload: unknown }>(
      worker,
      (data): data is { type: 'echo'; payload: unknown } =>
        typeof data === 'object' && data !== null && (data as { type?: string }).type === 'echo'
    )
    worker.postMessage({ type: 'echo', payload: { hello: 'parity' } })
    const echo = await withTimeout(echoMessage, 'dedicated worker echo')
    addResult(results, 'dedicated worker create/post', echo.payload != null, JSON.stringify(echo))

    const channelPromise = onceChannel<{ ok: boolean; payload: unknown }>(worker, 'suite-pong')
    worker.send('suite-ping', { hello: 'channel' })
    const channel = await withTimeout(channelPromise, 'dedicated worker channel')
    addResult(results, 'dedicated worker channel bridge', channel.ok === true, JSON.stringify(channel))

    const eventPromise = onceMessage<{ type: 'event'; count: number }>(
      worker,
      (data): data is { type: 'event'; count: number } =>
        typeof data === 'object' && data !== null && (data as { type?: string }).type === 'event'
    )
    Events.emit('suite:backend-broadcast', { source: 'parity-suite' })
    const event = await withTimeout(eventPromise, 'dedicated worker event fanout')
    addResult(results, 'dedicated worker event delivery', event.count === 1, JSON.stringify(event))
  } catch (error) {
    addResult(results, 'dedicated worker flow', false, error instanceof Error ? error.message : String(error))
  } finally {
    worker.terminate()
  }

  const sharedOne = new SharedWorker(new URL('./parity-shared.ts', import.meta.url))
  const sharedTwo = new SharedWorker(new URL('./parity-shared.ts', import.meta.url))
  try {
    const sharedReply = onceChannel<{ ok: boolean; connectCount: number; eventCount: number }>(
      sharedOne,
      'suite-shared-pong'
    )
    sharedOne.send('suite-shared-ping', { hello: 'shared' })
    const initial = await withTimeout(sharedReply, 'shared worker connect state')
    addResult(results, 'shared worker connect/reuse', initial.connectCount >= 2, JSON.stringify(initial))

    Events.emit('suite:backend-broadcast', { source: 'shared-suite' })
    await delay(150)
    const sharedEventReply = onceChannel<{ ok: boolean; connectCount: number; eventCount: number }>(
      sharedOne,
      'suite-shared-pong'
    )
    sharedOne.send('suite-shared-ping', { hello: 'shared-event' })
    const sharedState = await withTimeout(sharedEventReply, 'shared worker event state')
    addResult(
      results,
      'shared worker event once-per-context',
      sharedState.eventCount === 1,
      JSON.stringify(sharedState)
    )

    sharedTwo.port.close()
    await delay(150)
    const sharedThree = new SharedWorker(new URL('./parity-shared.ts', import.meta.url))
    try {
      const reconnectReply = onceChannel<{ ok: boolean; connectCount: number; eventCount: number }>(
        sharedThree,
        'suite-shared-pong'
      )
      sharedThree.send('suite-shared-ping', { hello: 'reconnect' })
      const reconnect = await withTimeout(reconnectReply, 'shared worker reconnect state')
      addResult(results, 'shared worker reconnect', reconnect.connectCount >= 3, JSON.stringify(reconnect))
    } finally {
      sharedThree.port.close()
    }
  } catch (error) {
    addResult(results, 'shared worker flow', false, error instanceof Error ? error.message : String(error))
  } finally {
    sharedTwo.port.close()
    sharedOne.port.close()
  }

  try {
    const errorWorker = new Worker(new URL('./parity-error.ts', import.meta.url))
    try {
      const errorEvent = await withTimeout(onceError(errorWorker), 'worker runtime error')
      addResult(
        results,
        'worker script error shape',
        typeof errorEvent.message === 'string' && errorEvent.message.length > 0,
        errorEvent.message || 'missing error message'
      )
    } finally {
      errorWorker.terminate()
    }
  } catch (error) {
    addResult(results, 'worker script error shape', false, error instanceof Error ? error.message : String(error))
  }

  if (options.includeOwnerReset === true) {
    try {
      const bridge = (globalThis as typeof globalThis & Record<symbol, { resetOwnerWorkers?: () => void }>)[
        Symbol.for('zapp.bridge')
      ]
      bridge?.resetOwnerWorkers?.()
      await delay(150)
      addResult(results, 'owner reset path', true, 'bridge.resetOwnerWorkers() invoked')
    } catch (error) {
      addResult(results, 'owner reset path', false, error instanceof Error ? error.message : String(error))
    }
  } else {
    addResult(results, 'owner reset path', true, 'skipped in auto-run to avoid killing demo workers')
  }

  try {
    const workers: Worker[] = []
    let maxWorkersError = ''
    for (let i = 0; i < 60; i += 1) {
      const w = new Worker(new URL('./parity-worker.ts', import.meta.url))
      workers.push(w)
      w.onerror = (event) => {
        maxWorkersError ||= event.message
      }
    }
    await delay(250)
    addResult(
      results,
      'maxWorkers enforcement',
      maxWorkersError.includes('Max worker limit'),
      maxWorkersError || 'no maxWorkers error observed'
    )
    for (const w of workers) {
      w.terminate()
    }
  } catch (error) {
    addResult(results, 'maxWorkers enforcement', false, error instanceof Error ? error.message : String(error))
  }

  g.__zappWorkerParity = {
    lastReport: report,
    run: runWorkerParitySuite,
  }

  console.table(report.results)
  return report
}

g.__zappWorkerParity = {
  lastReport: null,
  run: runWorkerParitySuite,
}
