// --- A11y DOM mirror (teak accessibility bridge, wire format v2) ---
// The browser half of Teak's `Host.publishA11yTree` / `pollA11yActions`
// (teak docs/features/a11y.md, src/platform/wasm.zig "A11y DOM-mirror wire
// format"). A canvas-rendered UI is opaque to assistive technology; this
// mirrors Teak's semantic tree into a real, NESTED DOM subtree of ARIA
// elements, positioned over the canvas so AT focus rings and touch
// exploration land where the pixels are:
//
//   wasm -> JS   __zunk_publish_a11y_tree(records, len, strings, slen): 64-byte
//                records (parents before children), diffed against the DOM.
//   JS -> wasm   __zunk_poll_a11y_actions(recs, cap, strs, scap) -> count:
//                what AT did (activate / focus / set value), queued here as DOM
//                events fire and drained once per frame. Teak turns them into
//                ordinary input; there is no second mutation path (the DOM is
//                derived state, never an authority).
//
// Record (little endian, 64 bytes):
//    0 cmd_index u32   4 role u32 (wire code, ROLES below)   8 label off,len u32 x2
//   16 bounds x,y,w,h i32 x4   32 state f32   36 flags u32 (FLAG)
//   40 value off,len u32 x2   48 sel_start,sel_end u32 x2 (bytes in value)
//   56 parent u32 (record index, 0xFFFFFFFF = root)   60 level u32
// Action record (16 bytes): kind u32 (0 activate, 1 focus, 2 set_value,
//   3 increment, 4 decrement), cmd_index u32, str_off u32, str_len u32.
const zunkA11y = (() => {
  const NONE = 0xFFFFFFFF;
  const FLAG = { focused: 1, disabled: 2, selected: 4, expandable: 8, expanded: 16, modal: 32, polite: 64, assertive: 128 };
  // wire code -> [tag, aria role | null, kind]. kind: 't' text leaf (label as textContent),
  // 'b' native button, 'i' input, 'a' textarea, 'c' container (aria-label), 's' slider,
  // 'k' toggle (checkbox/radio), 'l' labelled leaf button-like (textContent + tabindex).
  const ROLES = [
    ['div', null, 'c'],          // 0 generic
    ['div', 'region', 'c'],      // 1 region (scroll)
    ['span', null, 't'],         // 2 text
    ['span', null, 't'],         // 3 rich text
    ['button', null, 'b'],       // 4 button
    ['input', 'textbox', 'i'],   // 5 textbox
    ['div', 'checkbox', 'k'],    // 6
    ['div', 'radio', 'k'],       // 7
    ['div', 'slider', 's'],      // 8
    ['div', 'separator', 'c'],   // 9
    ['div', 'img', 'c'],         // 10
    ['div', 'dialog', 'c'],      // 11
    ['textarea', 'textbox', 'a'],// 12 multiline textbox
    ['div', 'combobox', 'l'],    // 13
    ['div', 'listbox', 'c'],     // 14
    ['div', 'option', 'l'],      // 15
    ['div', 'menu', 'c'],        // 16
    ['div', 'menuitem', 'l'],    // 17
    ['div', 'tablist', 'c'],     // 18
    ['div', 'tab', 'l'],         // 19
    ['div', 'tree', 'c'],        // 20
    ['div', 'treeitem', 'l'],    // 21
    ['div', 'table', 'c'],       // 22
    ['div', 'row', 'c'],         // 23
    ['div', 'cell', 'c'],        // 24
    ['div', 'progressbar', 'c'], // 25
    ['div', 'status', 'c'],      // 26
    ['div', 'alert', 'c'],       // 27
    ['div', 'list', 'c'],        // 28
    ['div', 'listitem', 'c'],    // 29
    ['div', 'toolbar', 'c'],     // 30
    ['div', 'heading', 'c'],     // 31
    ['div', 'menubar', 'c'],     // 32
    ['div', 'columnheader', 'c'],// 33
    ['div', 'link', 'l'],        // 34
  ];
  const KIND = { activate: 0, focus: 1, set_value: 2, increment: 3, decrement: 4 };

  let root = null;
  const els = new Map();   // cmd_index -> element
  const queue = [];        // pending actions {kind, idx, text}
  let programmatic = false;
  let focusedKey = -1;
  let lastKeyMs = 0;
  const dec = new TextDecoder();
  const enc = new TextEncoder();

  function ensureRoot() {
    if (root) return;
    root = document.createElement('div');
    root.id = 'zunk-a11y-root';
    // Overlaid on the canvas (children are absolutely positioned at their
    // bounds), invisible, never intercepting the pointer.
    root.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;overflow:visible;pointer-events:none;opacity:0;';
    document.body.appendChild(root);
    document.addEventListener('keydown', () => { lastKeyMs = performance.now(); }, true);
  }

  function place() {
    const c = document.getElementById('app') || document.querySelector('canvas');
    if (!c || !c.getBoundingClientRect) return;
    const r = c.getBoundingClientRect();
    root.style.left = (r.left + window.scrollX) + 'px';
    root.style.top = (r.top + window.scrollY) + 'px';
  }

  function enqueue(kind, idx, text) {
    if (queue.length < 64) queue.push({ kind, idx, text: text || '' });
  }

  function make(code, key) {
    const [tag, role, kind] = ROLES[code];
    const el = document.createElement(tag);
    el._code = code;
    el._key = key;
    el.dataset.cmd = String(key);
    el.style.position = 'absolute';
    el.style.margin = '0';
    el.style.padding = '0';
    el.style.border = '0';
    el.style.overflow = 'hidden';
    el.style.font = '12px sans-serif';
    el.style.pointerEvents = 'none';
    if (role) el.setAttribute('role', role);
    if (kind === 'i') el.type = 'text';
    if (kind === 'b' || kind === 'k' || kind === 's' || kind === 'l' || kind === 'i' || kind === 'a') {
      if (kind !== 'b' && kind !== 'i' && kind !== 'a') el.tabIndex = 0;
      el.addEventListener('focus', () => { if (!programmatic) enqueue(KIND.focus, key); });
    }
    if (kind === 'b' || kind === 'k' || kind === 'l') {
      // AT activation (and Enter/Space on a focused element) arrives as a click.
      el.addEventListener('click', e => { e.preventDefault(); enqueue(KIND.activate, key); });
      // Keys that activate a DOM control must not ALSO reach Teak's keyboard
      // path (one action, one path).
      el.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') e.stopPropagation(); });
    }
    if (kind === 'i' || kind === 'a') {
      // Typing arrives through zunk's keydown handler (Teak's normal input
      // path). An `input` event with no recent key press is AT setting the
      // value programmatically: report it as set_value.
      el.addEventListener('input', () => {
        if (performance.now() - lastKeyMs > 80) enqueue(KIND.set_value, key, el.value);
      });
    }
    if (kind === 'k') {
      // Space toggles a checkbox; it arrives as a click above, not as a Teak key.
    }
    return el;
  }

  const utf16Len = (bytes, n) => dec.decode(bytes.subarray(0, n)).length;

  function apply(el, code, dv, off, strs, sptr) {
    const kind = ROLES[code][2];
    const lofs = dv.getUint32(off + 8, true), llen = dv.getUint32(off + 12, true);
    const state = dv.getFloat32(off + 32, true), flags = dv.getUint32(off + 36, true);
    const vofs = dv.getUint32(off + 40, true), vlen = dv.getUint32(off + 44, true);
    const ss = dv.getUint32(off + 48, true), se = dv.getUint32(off + 52, true);
    const level = dv.getUint32(off + 60, true);
    const label = llen ? dec.decode(strs.subarray(lofs, lofs + llen)) : '';
    const x = dv.getInt32(off + 16, true), y = dv.getInt32(off + 20, true);
    const w = dv.getInt32(off + 24, true), h = dv.getInt32(off + 28, true);
    const s = el.style;
    s.left = x + 'px'; s.top = y + 'px'; s.width = w + 'px'; s.height = h + 'px';
    if (kind === 't' || kind === 'b' || kind === 'l') {
      if (el.textContent !== label) el.textContent = label;
      if (kind === 'l') el.removeAttribute('aria-label');
    } else if (label) el.setAttribute('aria-label', label);
    else el.removeAttribute('aria-label');
    const disabled = (flags & FLAG.disabled) !== 0;
    if (kind === 'b' || kind === 'i' || kind === 'a') el.disabled = disabled;
    if (disabled) el.setAttribute('aria-disabled', 'true'); else el.removeAttribute('aria-disabled');
    if (kind === 'k') el.setAttribute('aria-checked', state >= 0.5 ? 'true' : 'false');
    if (kind === 's') {
      el.setAttribute('aria-valuemin', '0'); el.setAttribute('aria-valuemax', '1');
      el.setAttribute('aria-valuenow', String(state));
    }
    if (code === 25) {
      el.setAttribute('aria-valuemin', '0'); el.setAttribute('aria-valuemax', '100');
      el.setAttribute('aria-valuenow', String(Math.round(state * 100)));
    }
    if (code === 19 || code === 15 || code === 21 || code === 23) {
      el.setAttribute('aria-selected', (flags & FLAG.selected) ? 'true' : 'false');
    } else if (code === 17) {
      if (flags & FLAG.selected) el.setAttribute('aria-current', 'true'); else el.removeAttribute('aria-current');
    }
    if (flags & FLAG.expandable) el.setAttribute('aria-expanded', (flags & FLAG.expanded) ? 'true' : 'false');
    else el.removeAttribute('aria-expanded');
    if (level) el.setAttribute('aria-level', String(level)); else el.removeAttribute('aria-level');
    if (flags & FLAG.modal) el.setAttribute('aria-modal', 'true'); else el.removeAttribute('aria-modal');
    if (flags & (FLAG.polite | FLAG.assertive)) {
      el.setAttribute('aria-live', (flags & FLAG.assertive) ? 'assertive' : 'polite');
      el.setAttribute('aria-atomic', 'true');
    } else el.removeAttribute('aria-live');
    if (code === 12 || kind === 'a') el.setAttribute('aria-multiline', 'true');
    if (kind === 'i' || kind === 'a') {
      const val = vlen ? dec.decode(strs.subarray(vofs, vofs + vlen)) : '';
      if (el.value !== val) el.value = val;
      if (document.activeElement === el && !programmatic) {
        const vb = strs.subarray(vofs, vofs + vlen);
        try { el.setSelectionRange(utf16Len(vb, ss), utf16Len(vb, se)); } catch (e) { /* not selectable */ }
      }
    }
    return flags;
  }

  function publish(rptr, rlen, sptr, slen) {
    ensureRoot();
    place();
    const count = (rlen / 64) | 0;
    const dv = new DataView(memory.buffer, rptr, rlen);
    const strs = new Uint8Array(memory.buffer, sptr, slen);
    const seen = new Set();
    const order = new Array(count);
    const lastPlaced = new Map(); // parent element -> last child placed in order
    let wantFocus = -1;
    for (let i = 0; i < count; i++) {
      const off = i * 64;
      const key = dv.getUint32(off, true);
      const code = dv.getUint32(off + 4, true);
      if (code >= ROLES.length) { order[i] = null; continue; }
      let el = els.get(key);
      if (!el || el._code !== code) {
        if (el) el.remove();
        el = make(code, key);
        els.set(key, el);
      }
      seen.add(key);
      order[i] = el;
      const flags = apply(el, code, dv, off, strs, sptr);
      if (flags & FLAG.focused) wantFocus = key;
      const parentIdx = dv.getUint32(off + 56, true);
      const parentEl = parentIdx !== NONE && parentIdx < i && order[parentIdx] ? order[parentIdx] : root;
      const last = lastPlaced.get(parentEl);
      const expectedNext = last ? last.nextSibling : parentEl.firstChild;
      if (expectedNext !== el) parentEl.insertBefore(el, expectedNext);
      lastPlaced.set(parentEl, el);
    }
    els.forEach((el, key) => { if (!seen.has(key)) { el.remove(); els.delete(key); } });
    // Focus sync (Teak -> DOM): move DOM focus when Teak's focus moved.
    if (wantFocus !== focusedKey) {
      focusedKey = wantFocus;
      const el = wantFocus >= 0 ? els.get(wantFocus) : null;
      if (el && document.activeElement !== el && typeof el.focus === 'function') {
        programmatic = true;
        try { el.focus({ preventScroll: true }); } finally { programmatic = false; }
      }
    }
  }

  function poll(recPtr, recCap, strPtr, strCap) {
    if (queue.length === 0) return 0;
    const dv = new DataView(memory.buffer, recPtr, recCap * 16);
    const bytes = new Uint8Array(memory.buffer, strPtr, strCap);
    let used = 0, n = 0;
    while (queue.length && n < recCap) {
      const a = queue.shift();
      let off = 0, len = 0;
      if (a.text) {
        const b = enc.encode(a.text);
        if (b.length <= strCap - used) { bytes.set(b, used); off = used; len = b.length; used += len; }
        else continue; // too large to deliver: drop (the value stays authoritative in Teak)
      }
      const o = n * 16;
      dv.setUint32(o, a.kind, true);
      dv.setUint32(o + 4, a.idx, true);
      dv.setUint32(o + 8, off, true);
      dv.setUint32(o + 12, len, true);
      n++;
    }
    return n;
  }

  return { publish, poll };
})();
