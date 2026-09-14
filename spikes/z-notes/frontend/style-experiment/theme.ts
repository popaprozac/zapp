// PRIVATE fixture policy, not an approved theme API. Only these three names
// cross documents. Copy inline custom-property declarations, not computed CSS.
const attribute = 'data-style-theme', className = 'style-theme-dark', variable = '--style-accent';
export function mirrorSelectedTheme(source: HTMLElement, target: HTMLElement) {
  let owner: HTMLElement | undefined = source, child: HTMLElement | undefined = target;
  const read = (root: HTMLElement) => ({attribute:root.getAttribute(attribute), class:root.classList.contains(className), value:root.style.getPropertyValue(variable), priority:root.style.getPropertyPriority(variable)});
  const initial = read(target);
  let last = initial;
  function apply() {
    if (!owner || !child) return;
    last = read(owner);
    if (last.attribute === null) child.removeAttribute(attribute); else child.setAttribute(attribute, last.attribute);
    child.classList.toggle(className, last.class);
    if (last.value) child.style.setProperty(variable, last.value, last.priority); else child.style.removeProperty(variable);
  }
  let observer: MutationObserver | undefined = new source.ownerDocument.defaultView!.MutationObserver(apply);
  observer.observe(source, {attributes:true, attributeFilter:[attribute, 'class', 'style']}); apply();
  return { dispose() {
    observer?.disconnect(); observer = undefined;
    if (!child) return;
    const current = read(child);
    // Restore only values still owned by the mirror; don't undo a child's newer
    // independent edit made after the final synchronization.
    if (current.attribute === last.attribute) {
      if (initial.attribute === null) child.removeAttribute(attribute); else child.setAttribute(attribute, initial.attribute);
    }
    if (current.class === last.class) child.classList.toggle(className, initial.class);
    if (current.value === last.value && current.priority === last.priority) {
      if (initial.value) child.style.setProperty(variable, initial.value, initial.priority); else child.style.removeProperty(variable);
    }
    owner = undefined; child = undefined;
  }, stats: () => ({ observing:!!observer, roots: owner && child ? 2 : 0 }) };
}
