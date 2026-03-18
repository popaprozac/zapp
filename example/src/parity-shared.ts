type SharedReply = (channel: string, data: unknown) => void
type SharedGlobal = typeof globalThis & {
  receive: (channel: string, handler: (data: unknown, reply: SharedReply) => void) => void
  onconnect: ((event: { ports: MessagePort[] }) => void) | null
  __zapp?: {
    on?: (name: string, handler: (payload: unknown) => void) => () => void
  }
}

const sharedSelf = self as unknown as SharedGlobal
const zapp = sharedSelf.__zapp

let connectCount = 0
let eventCount = 0

sharedSelf.receive('suite-shared-ping', (data, reply) => {
  reply('suite-shared-pong', {
    ok: true,
    payload: data,
    connectCount,
    eventCount,
  })
})

sharedSelf.onconnect = () => {
  connectCount += 1
}

zapp?.on?.('suite:backend-broadcast', () => {
  eventCount += 1
})
