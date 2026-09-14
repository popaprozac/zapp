// PRIVATE PROBE: readiness of a snapshot of tracked link generations, not DOM,
// font, first-paint, or permanent visual readiness. No change to window creation.
type Link = Pick<HTMLLinkElement, 'addEventListener' | 'removeEventListener' | 'sheet'>;
type Status = 'pending' | 'loaded' | 'failed' | 'changed' | 'disposed';
export type StyleReadiness = 'ready' | 'failed' | 'changed' | 'disposed' | 'timeout';
type Record = { status: Status; cleanup?: () => void };
type Waiter = { snapshot: Record[]; timer?: ReturnType<typeof setTimeout>; finish: (status: StyleReadiness) => void };
export function createStylesheetReadiness() {
  const records = new Map<Link, Record>();
  const waiters = new Set<Waiter>();
  let disposed = false;
  function notify() {
    for (const waiter of waiters) {
      const terminal = waiter.snapshot.find(record => record.status !== 'pending' && record.status !== 'loaded');
      if (terminal) waiter.finish(terminal.status as StyleReadiness);
      else if (waiter.snapshot.every(record => record.status === 'loaded')) waiter.finish('ready');
    }
  }
  function forget(link: Link) {
    const record = records.get(link);
    if (!record) return;
    record.cleanup?.(); record.cleanup = undefined; record.status = 'changed';
    records.delete(link); notify();
  }
  return {
    watch(link: Link) {
      if (disposed) throw new Error('Style experiment: readiness disposed');
      forget(link);
      const record: Record = { status: link.sheet ? 'loaded' : 'pending' };
      records.set(link, record);
      if (record.status === 'loaded') return;
      const settle = (status: Status) => {
        if (record.status !== 'pending') return;
        record.status = status; record.cleanup?.(); record.cleanup = undefined; notify();
      };
      const load = () => settle('loaded'), error = () => settle('failed');
      link.addEventListener('load', load); link.addEventListener('error', error);
      record.cleanup = () => { link.removeEventListener('load', load); link.removeEventListener('error', error); };
    },
    forget,
    ready(timeoutMs: number): Promise<StyleReadiness> {
      if (!Number.isFinite(timeoutMs) || timeoutMs < 0) throw new Error('Style experiment: invalid readiness timeout');
      if (disposed) return Promise.resolve('disposed');
      return new Promise(resolve => {
        let done = false;
        const waiter: Waiter = { snapshot: [...records.values()], finish(status) {
          if (done) return; done = true;
          clearTimeout(waiter.timer); waiter.snapshot = []; waiters.delete(waiter); resolve(status);
        } };
        waiters.add(waiter);
        waiter.timer = setTimeout(() => waiter.finish('timeout'), timeoutMs);
        notify();
      });
    },
    stats: () => ({ links: records.size, listeners: [...records.values()].filter(record => !!record.cleanup).length * 2, waits: waiters.size }),
    dispose() {
      if (disposed) return; disposed = true;
      for (const waiter of waiters) waiter.finish('disposed');
      for (const record of records.values()) { record.cleanup?.(); record.cleanup = undefined; record.status = 'disposed'; }
      records.clear();
    },
  };
}
