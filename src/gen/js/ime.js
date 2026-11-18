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
    queue.push({ kind, cursor: cursor || 0, bytes, text: kind === 2 ? text : null });
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
    // Layout anchors the IME window; 16px prevents iOS focus zoom.
    ta.style.cssText = 'position:absolute;left:0;top:0;width:2px;height:20px;margin:0;padding:0;border:0;' +
      'outline:0;opacity:0;overflow:hidden;resize:none;background:transparent;color:transparent;' +
      'caret-color:transparent;font:16px sans-serif;white-space:pre;pointer-events:none;z-index:-1;';
    document.body.appendChild(ta);

    ta.addEventListener('compositionstart', () => { composing = true; push(1, '', 0); });
    ta.addEventListener('compositionupdate', e => {
      const text = e.data || '';
      // The browser updates selection after this event; read it during poll.
      push(2, text, encoder.encode(text).length);
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
    // App keys must not edit the hidden field; composition keys must reach the IME.
    ta.addEventListener('keydown', e => {
      if (e.isComposing || e.keyCode === 229) return;
      const k = e.key;
      const chord = (e.ctrlKey || e.metaKey) && !e.getModifierState('AltGraph');
      if (['Tab', 'Escape', 'Enter', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', 'Backspace', 'Delete'].includes(k)) e.preventDefault();
      else if (chord && k.length === 1 && 'acxyz'.includes(k.toLowerCase())) e.preventDefault();
    });
    // A canvas click moves focus away from the hidden field.
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

  function set_spot(x, y, h) {
    ensure();
    const canvas = document.getElementById('app') || document.querySelector('canvas');
    const r = canvas && canvas.getBoundingClientRect ? canvas.getBoundingClientRect() : { left: 0, top: 0 };
    ta.style.left = (r.left + window.scrollX + x) + 'px';
    ta.style.top = (r.top + window.scrollY + y) + 'px';
    ta.style.height = Math.max(1, h) + 'px';
  }

  function poll(ptr, cap) {
    if (active) refocus();
    const last = queue[queue.length - 1];
    if (composing && last && last.kind === 2) {
      let idx = ta.selectionEnd;
      if (!(idx >= 0 && idx <= last.text.length)) idx = last.text.length;
      last.cursor = encoder.encode(last.text.slice(0, idx)).length;
    }
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
