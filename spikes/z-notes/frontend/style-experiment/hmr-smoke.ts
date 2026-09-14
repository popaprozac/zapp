// Private Vite fixture. The CLI writes files only after these DOM checkpoints
// traverse the ordinary native service response path. No fake HMR events.
export async function verifyFileHmr(
  children: { doc: Document; value: (name: string) => string }[],
  pulse: () => Promise<unknown>,
  until: (check: () => boolean, label: string) => Promise<void>,
) {
  const entry = import.meta.env.VITE_ZAPP_STYLE_HMR_ENTRY;
  if (!entry || !import.meta.hot) throw new Error('Style experiment: missing isolated HMR fixture');
  let fullReload = false;
  const reload = () => { fullReload = true; };
  import.meta.hot.on('vite:beforeFullReload', reload);
  const owner = document;
  const inputs = children.map(({ doc }) => {
    const input = doc.createElement('input'); input.value = 'unsaved across CSS HMR'; doc.body.append(input); return input;
  });
  const sourceStyles = () => [...owner.head.querySelectorAll('style')].filter(node => node.textContent?.includes('--style-hmr'));
  try {
    const module = await import(/* @vite-ignore */ entry);
    if (module.revision !== 'initial') throw new Error(`Style experiment: wrong HMR entry ${entry}: ${String(module.revision)}`);
    try {
      await until(() => children.every(child => child.value('--style-hmr') === 'phase-initial'), 'initial real Vite CSS module');
    } catch (error) {
      throw new Error(`${error}; source=${JSON.stringify(sourceStyles().map(node => node.textContent))}; children=${JSON.stringify(children.map(child => child.value('--style-hmr')))}`);
    }
    const initial = sourceStyles();
    if (initial.length !== 1) throw new Error('Style experiment: expected one Vite-owned CSS fixture');
    const start = performance.now();
    owner.body.dataset.styleHmrPhase = 'ready'; await pulse();
    await until(() => children.every(child => child.value('--style-hmr') === 'updated'), 'file watcher → Vite HMR → child styles');
    const updateMs = performance.now() - start;
    if (!initial[0].isConnected) throw new Error('Style experiment: CSS edit recreated the Vite source sheet');
    owner.body.dataset.styleHmrPhase = 'updated'; await pulse();
    await until(() => children.every(child => child.value('--style-hmr') === '') && sourceStyles().length === 0, 'import removal → Vite CSS pruning');
    if (fullReload || document !== owner || inputs.some(input => !input.isConnected || input.value !== 'unsaved across CSS HMR')) {
      throw new Error('Style experiment: CSS HMR lost document identity or unsaved child state');
    }
    if (initial[0].isConnected) throw new Error('Style experiment: pruned source node is retained in head');
    owner.body.dataset.styleHmrPhase = 'pruned'; await pulse();
    return { updateMs, pruneMs: performance.now() - start - updateMs };
  } finally {
    import.meta.hot.off('vite:beforeFullReload', reload);
    for (const input of inputs) input.remove();
  }
}
