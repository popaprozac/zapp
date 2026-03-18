type ZappWorkerGlobal = typeof globalThis & {
  receive: (channel: string, handler: (data: unknown) => void) => void
  send: (channel: string, data: unknown) => void
  __zapp?: {
    on?: (name: string, handler: (payload: unknown) => void) => () => void
  }
}

const workerSelf = self as unknown as ZappWorkerGlobal
const zapp = workerSelf.__zapp

let eventCount = 0

workerSelf.onmessage = (event) => {
  console.log('parity-worker received message', JSON.stringify(event.data))
  const data = event.data as { type?: string; payload?: unknown }
  if (data?.type === 'echo') {
    workerSelf.postMessage({ type: 'echo', payload: data.payload })
    return
  }
  if (data?.type === 'get-event-count') {
    workerSelf.postMessage({ type: 'event-count', count: eventCount })
  }
}

workerSelf.receive('suite-ping', (data) => {
  workerSelf.send('suite-pong', { ok: true, payload: data })
})

zapp?.on?.('suite:backend-broadcast', (payload) => {
  eventCount += 1
  workerSelf.postMessage({ type: 'event', count: eventCount, payload })
})
