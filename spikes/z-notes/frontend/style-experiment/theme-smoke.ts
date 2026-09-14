import { mirrorSelectedTheme } from './theme';
type Child = { doc: Document; value: (name: string) => string };
const flush = () => new Promise(resolve => setTimeout(resolve, 0));
function assert(value: unknown, label: string): asserts value { if (!value) throw new Error(`Theme experiment: ${label}`); }
export async function verifySelectedTheme(small: Child, wide: Child, independent: Child) {
  const owner = document.documentElement;
  const initialAttribute = owner.getAttribute('data-style-theme');
  const initialClass = owner.classList.contains('style-theme-dark');
  const initialValue = owner.style.getPropertyValue('--style-accent');
  const initialPriority = owner.style.getPropertyPriority('--style-accent');
  const privateAttribute = owner.getAttribute('data-style-private');
  const privateClass = owner.classList.contains('style-unrelated');
  const privateValue = owner.style.getPropertyValue('--style-private');
  const privatePriority = owner.style.getPropertyPriority('--style-private');
  const style = document.createElement('style');
  style.textContent = '[data-style-theme="dark"] [data-style-probe]{--theme-attribute:dark} .style-theme-dark [data-style-probe]{--theme-class:dark} [data-style-probe]{--theme-variable:var(--style-accent,missing)}';
  document.head.append(style);
  const smallRoot = small.doc.documentElement, wideRoot = wide.doc.documentElement;
  smallRoot.setAttribute('data-style-theme', 'child-original');
  smallRoot.classList.add('child-only'); smallRoot.style.setProperty('--style-accent', 'child-accent');
  const a = mirrorSelectedTheme(owner, smallRoot), b = mirrorSelectedTheme(owner, wideRoot);
  try {
    owner.setAttribute('data-style-theme', 'dark'); owner.classList.add('style-theme-dark');
    owner.style.setProperty('--style-accent', 'owner-accent', 'important'); await flush();
    for (const child of [small, wide]) {
      assert(child.value('--theme-attribute') === 'dark' && child.value('--theme-class') === 'dark', 'named attribute/class reach the child');
      assert(child.value('--theme-variable') === 'owner-accent', 'selected inline custom property reaches the child');
      assert(child.doc.documentElement.style.getPropertyPriority('--style-accent') === 'important', 'custom-property priority preserved');
    }
    assert(smallRoot.classList.contains('child-only'), 'child-local class preserved');
    assert(!independent.doc.documentElement.hasAttribute('data-style-theme'), 'independent child gets no selected theme');
    // These names are test-owned and outside the allowlist.
    owner.setAttribute('data-style-private', 'do-not-copy'); owner.classList.add('style-unrelated');
    owner.style.setProperty('--style-private', 'do-not-copy'); await flush();
    assert(!smallRoot.hasAttribute('data-style-private') && !smallRoot.classList.contains('style-unrelated') && !smallRoot.style.getPropertyValue('--style-private'), 'no blanket attribute/class/style copying');
    owner.removeAttribute('data-style-theme'); owner.classList.remove('style-theme-dark'); owner.style.removeProperty('--style-accent'); await flush();
    assert(!smallRoot.hasAttribute('data-style-theme') && !smallRoot.classList.contains('style-theme-dark') && !smallRoot.style.getPropertyValue('--style-accent'), 'selected removals synchronize');
    owner.setAttribute('data-style-theme', 'dark'); a.dispose(); a.dispose(); await flush();
    assert(smallRoot.getAttribute('data-style-theme') === 'child-original' && smallRoot.style.getPropertyValue('--style-accent') === 'child-accent', 'dispose restores still-owned initial values');
    assert(wideRoot.getAttribute('data-style-theme') === 'dark', 'sibling remains live');
    assert(a.stats().roots === 0 && !a.stats().observing, 'queued theme change cannot keep or update the disposed child');
    wideRoot.setAttribute('data-style-theme', 'child-newer'); b.dispose();
    assert(wideRoot.getAttribute('data-style-theme') === 'child-newer', 'dispose preserves a newer child-local edit');
    assert(b.stats().roots === 0 && !b.stats().observing, 'second theme observer released');
  } finally {
    a.dispose(); b.dispose(); style.remove();
    if (initialAttribute === null) owner.removeAttribute('data-style-theme'); else owner.setAttribute('data-style-theme', initialAttribute);
    owner.classList.toggle('style-theme-dark', initialClass);
    if (initialValue) owner.style.setProperty('--style-accent', initialValue, initialPriority); else owner.style.removeProperty('--style-accent');
    if (privateAttribute === null) owner.removeAttribute('data-style-private'); else owner.setAttribute('data-style-private', privateAttribute);
    owner.classList.toggle('style-unrelated', privateClass);
    if (privateValue) owner.style.setProperty('--style-private', privateValue, privatePriority); else owner.style.removeProperty('--style-private');
  }
}
