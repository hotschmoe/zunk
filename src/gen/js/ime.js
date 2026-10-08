// --- IME bridge (zunk.web.ime) ---
// The browser half of `src/web/ime.zig`. A canvas cannot receive IME input, so a
// visually hidden <textarea> takes keyboard focus while the app has a focused
// text field. The browser's IME (candidate window, preedit) works against that
// element; this bridge turns its events into a small queue that wasm drains once
// per frame (`zunk_ime_poll`), like the host-services bridge: JS never calls into
// wasm.
//
// Record, little endian, 4-byte aligned:
//   u32 kind   1 = composition started, 2 = composition text changed,
//              3 = text committed (also: a composition ended; empty = cancelled)
//   u32 cursor caret inside the text, in UTF-8 bytes (kind 2), else 0
//   u32 len    byte length of the text
//   len bytes  UTF-8, padded to a multiple of 4
//
// Double insertion: zunk's input layer already turns printable keydowns into
// typed text and preventDefault()s them, so no `input` event follows for them.
// The textarea therefore only ever reports text the keyboard path cannot: IME
// results and insertText from virtual keyboards / automation. Paste and drop
// arrive through the host-services bridge and are ignored here.
const zunkIme = (() => {
  const MAX_QUEUE = 64;
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const queue = [];
  let ta = null;
  let active = false;
  let composing = false;

  const ignoredInput = t => !t || t === 'insertCompositionText' || t === 'insertFromComposition' ||
    t.startsWith('insertFromPaste') || t.startsWith('insertFromDrop') || t.startsWith('insertFromYank') ||
    t === 'insertLineBreak' || t === 'insertParagraph' || t.startsWith('delete') || t.startsWith('history');

  function push(kind, text, cursor) {
    const bytes = encoder.encode(text || '');
    if (queue.length >= MAX_QUEUE) queue.shift();
    queue.push({ kind, cursor: cursor || 0, bytes });
  }

  function ensure() {
    if (ta) return ta;
    ta = document.createElement('textarea');
    ta.setAttribute('data-zunk-ime', '1');
    ta.setAttribute('aria-hidden', 'true');
    ta.setAttribute('autocomplete', 'off');
    ta.setAttribute('autocorrect', 'off');
    ta.setAttribute('autocapitalize', 'off');
    ta.spellcheck = false;
    ta.tabIndex = -1;
    // Invisible but laid out (so the browser anchors the IME window at its caret);
    // 16px keeps iOS from zooming on focus.
    ta.style.cssText = 'position:absolute;left:0;top:0;width:2px;height:20px;margin:0;padding:0;border:0;' +
      'outline:0;opacity:0;overflow:hidden;resize:none;background:transparent;color:transparent;' +
      'caret-color:transparent;font:16px sans-serif;white-space:pre;pointer-events:none;z-index:-1;';
    document.body.appendChild(ta);

    ta.addEventListener('compositionstart', () => { composing = true; push(1, '', 0); });
    ta.addEventListener('compositionupdate', e => {
      const text = e.data || '';
      // The caret inside the preedit (UTF-16 index of the selection end) in UTF-8 bytes.
      let idx = ta.selectionEnd;
      if (!(idx >= 0 && idx <= text.length)) idx = text.length;
      push(2, text, encoder.encode(text.slice(0, idx)).length);
    });
    ta.addEventListener('compositionend', e => {
      composing = false;
      push(3, e.data || '', 0);
      ta.value = '';
    });
    ta.addEventListener('input', e => {
      if (composing || e.isComposing || ignoredInput(e.inputType)) { if (!composing) ta.value = ''; return; }
      if (e.data) push(3, e.data, 0);
      ta.value = '';
    });
    // The textarea is a text field to the browser, so its keys would also drive the page
    // (Tab moves focus away; Backspace/arrows edit the hidden text). Keep what zunk's input
    // layer treats as app keys away from the field; composition keys must reach the IME.
    ta.addEventListener('keydown', e => {
      if (e.isComposing || e.keyCode === 229) return;
      const k = e.key;
      const chord = (e.ctrlKey || e.metaKey) && !e.getModifierState('AltGraph');
      if (['Tab', 'Escape', 'Enter', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', 'Backspace', 'Delete'].includes(k)) e.preventDefault();
      else if (chord && k.length === 1 && 'acxyz'.includes(k.toLowerCase())) e.preventDefault();
    });
    // A click on the canvas moves focus to the body; hand it straight back while a field is focused.
    window.addEventListener('mouseup', () => { if (active) refocus(); });
    return ta;
  }

  function refocus() {
    if (ta && document.activeElement !== ta) ta.focus({ preventScroll: true });
  }

  function set_active(on) {
    ensure();
    on = !!on;
    if (on === active) return;
    active = on;
    if (on) refocus();
    else { composing = false; ta.value = ''; ta.blur(); }
  }

  // Place the field at the caret: canvas-relative CSS px (x, y of the line's top-left, h its height).
  function set_spot(x, y, h) {
    ensure();
    const canvas = document.getElementById('app') || document.querySelector('canvas');
    const r = canvas && canvas.getBoundingClientRect ? canvas.getBoundingClientRect() : { left: 0, top: 0 };
    ta.style.left = (r.left + window.scrollX + x) + 'px';
    ta.style.top = (r.top + window.scrollY + y) + 'px';
    ta.style.height = Math.max(1, h) + 'px';
  }

  // Copy whole records into wasm memory at `ptr` (capacity `cap` bytes); returns bytes written.
  function poll(ptr, cap) {
    if (active) refocus();
    let off = 0;
    const dv = new DataView(memory.buffer);
    while (queue.length) {
      const r = queue[0];
      const need = 12 + ((r.bytes.length + 3) & ~3);
      if (off + need > cap) break;
      queue.shift();
      dv.setUint32(ptr + off, r.kind, true);
      dv.setUint32(ptr + off + 4, r.cursor, true);
      dv.setUint32(ptr + off + 8, r.bytes.length, true);
      new Uint8Array(memory.buffer, ptr + off + 12, r.bytes.length).set(r.bytes);
      off += need;
    }
    return off;
  }

  return { set_active, set_spot, poll };
})();
