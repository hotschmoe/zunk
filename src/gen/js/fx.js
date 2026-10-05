// --- Host services (zunk.web.fx) ---
// The browser half of `src/web/fx.zig`; the protocol is written down in
// docs/ARCHITECTURE.md ("Host services"). Two directions:
//
//   wasm -> JS   imports `zunk_fx_<name>`: start work, copy any wasm bytes
//                synchronously (wasm memory may move later), never block.
//   JS -> wasm   every result is a completion record queued here and handed
//                over only when wasm calls `zunk_fx_pump`, which allocates
//                the record in wasm memory (`zunk_fx_alloc`) and passes it to
//                `zunk_fx_deliver`. JS never calls into wasm at any other
//                time, so wasm state is never touched mid-frame.
//
// Completion record, little endian:
//    0  u32 kind (KIND below)   4  u32 id (0 = unsolicited)
//    8  i32 a  12 i32 b  16 i32 c  20 i32 d      (meaning per kind)
//   24  u32 len0 .. 36 u32 len3                  (blob lengths)
//   40  blob0 blob1 blob2 blob3                  (concatenated, unpadded)
//
//   kind          a              b      c       d        blobs
//   http          status (0=err) -      -       -        body, err
//   file_opened   -              -      -       -        name, mime, bytes
//   file_cancelled -
//   downloaded    ok (0/1)
//   storage_value found (0/1)                            value
//   clock         utc offset min                          i64 unix ms (8 bytes)
//   dropped       0 file 1 image 2 text   width  height  thumb_w   name, mime, bytes, thumb RGBA
//   pasted_text   -                                       text
//   query_value   found (0/1)                             value
const zunkFx = (() => {
  const KIND = { http: 1, file_opened: 2, file_cancelled: 3, downloaded: 4, storage_value: 5, clock: 6, dropped: 7, pasted_text: 8, query_value: 9 };
  const HEADER = 40;
  const MAX_QUEUE = 64;            // unsolicited records beyond this drop the oldest
  const MAX_RESPONSE = 32 << 20;   // largest HTTP response body / dropped file taken
  const MAX_IMAGE_SIDE = 1568;     // dropped / pasted images are downscaled to this long side
  const THUMB_SIDE = 64;
  const METHODS = ['GET', 'POST', 'PUT', 'DELETE'];
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const str = (ptr, len) => decoder.decode(new Uint8Array(memory.buffer, ptr, len));
  const utf8 = s => encoder.encode(s);

  const queue = [];
  function push(kind, id, ints, blobs) {
    let total = HEADER;
    for (const b of blobs) if (b) total += b.length;
    const rec = new Uint8Array(total);
    const dv = new DataView(rec.buffer);
    dv.setUint32(0, kind, true);
    dv.setUint32(4, id, true);
    for (let i = 0; i < 4; i++) dv.setInt32(8 + 4 * i, ints[i] || 0, true);
    let off = HEADER;
    for (let i = 0; i < 4; i++) {
      const b = blobs[i];
      if (!b) continue;
      dv.setUint32(24 + 4 * i, b.length, true);
      rec.set(b, off);
      off += b.length;
    }
    if (queue.length >= MAX_QUEUE) queue.shift();
    queue.push(rec);
  }

  // ---- wasm -> JS --------------------------------------------------------

  // Hand at most `max` queued records to wasm.
  function pump(max) {
    for (let n = 0; n < max && queue.length > 0; n++) {
      const rec = queue.shift();
      const ptr = exports.zunk_fx_alloc(rec.length);
      if (!ptr) { console.warn('[zunk fx] out of wasm memory; dropped a completion'); continue; }
      // `alloc` may have grown memory: take the buffer only now.
      new Uint8Array(memory.buffer, ptr, rec.length).set(rec);
      exports.zunk_fx_deliver(ptr, rec.length);
    }
  }

  // fetch(). `headers` is "Name: value" lines. The body is read straight out
  // of wasm memory: fetch copies a BufferSource when the request is built.
  function http(id, method, urlPtr, urlLen, hdrPtr, hdrLen, bodyPtr, bodyLen, timeoutMs) {
    const url = str(urlPtr, urlLen);
    const headers = {};
    for (const line of str(hdrPtr, hdrLen).split('\n')) {
      const i = line.indexOf(':');
      if (i > 0) headers[line.slice(0, i).trim()] = line.slice(i + 1).trim();
    }
    const init = { method: METHODS[method] || 'GET', headers };
    if (bodyLen > 0) init.body = new Uint8Array(memory.buffer, bodyPtr, bodyLen);
    const ctl = new AbortController();
    init.signal = ctl.signal;
    let timedOut = false;
    const timer = timeoutMs > 0 ? setTimeout(() => { timedOut = true; ctl.abort(); }, timeoutMs) : 0;
    const fail = (err) => push(KIND.http, id, [0], [null, utf8(err)]);
    fetch(url, init)
      .then(r => r.arrayBuffer().then(buf => {
        if (buf.byteLength > MAX_RESPONSE) return fail('response too large (' + buf.byteLength + ' bytes)');
        push(KIND.http, id, [r.status], [new Uint8Array(buf), null]);
      }))
      .catch(e => fail(timedOut
        ? 'timeout after ' + timeoutMs + ' ms'
        : 'network error (offline, blocked or CORS): ' + (e && e.message || e)))
      .finally(() => clearTimeout(timer));
  }

  // Blob + temporary <a download>. Completes at once.
  function download(id, namePtr, nameLen, mimePtr, mimeLen, bytesPtr, bytesLen) {
    let ok = 1;
    try {
      // The Blob constructor snapshots the bytes, so the wasm view is safe.
      const blob = new Blob([new Uint8Array(memory.buffer, bytesPtr, bytesLen)], { type: str(mimePtr, mimeLen) });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = str(namePtr, nameLen);
      a.style.display = 'none';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 10000);
    } catch (e) {
      console.warn('[zunk fx] download failed:', e);
      ok = 0;
    }
    push(KIND.downloaded, id, [ok], []);
  }

  // ---- open_file ----------------------------------------------------------
  // Browsers only open a file picker from a user activation. The request is
  // issued by wasm a frame or more after the click that caused it, so: if an
  // activation is still live the picker opens now; otherwise the request is
  // ARMED and the picker opens on the next pointer press or key press. A new
  // request replaces (cancels) an armed or open one.
  let fileInput = null;
  let pick = null;   // { id, accept } of the request waiting for / showing a picker
  let armed = false;

  function ensureInput() {
    if (fileInput) return fileInput;
    fileInput = document.createElement('input');
    fileInput.type = 'file';
    fileInput.id = 'zunk-fx-file';
    fileInput.style.display = 'none';
    fileInput.addEventListener('change', () => {
      const p = pick, f = fileInput.files && fileInput.files[0];
      pick = null;
      if (!p) return;
      if (!f) return push(KIND.file_cancelled, p.id, [], []);
      f.arrayBuffer().then(buf => {
        if (buf.byteLength > MAX_RESPONSE) return push(KIND.file_cancelled, p.id, [], []);
        push(KIND.file_opened, p.id, [], [utf8(f.name), utf8(f.type || mimeFromName(f.name)), new Uint8Array(buf)]);
      }, () => push(KIND.file_cancelled, p.id, [], []));
    });
    fileInput.addEventListener('cancel', () => {
      const p = pick;
      pick = null;
      if (p) push(KIND.file_cancelled, p.id, [], []);
    });
    document.body.appendChild(fileInput);
    return fileInput;
  }

  function showPicker() {
    armed = false;
    const input = ensureInput();
    input.accept = pick.accept;
    input.value = '';
    input.click();
  }

  function armPicker() {
    if (armed) return;
    armed = true;
    const fire = () => {
      window.removeEventListener('pointerdown', fire, true);
      window.removeEventListener('keydown', fire, true);
      if (armed && pick) showPicker();
      armed = false;
    };
    window.addEventListener('pointerdown', fire, true);
    window.addEventListener('keydown', fire, true);
  }

  function open_file(id, acceptPtr, acceptLen) {
    if (pick) push(KIND.file_cancelled, pick.id, [], []);
    pick = { id, accept: str(acceptPtr, acceptLen) };
    if (navigator.userActivation && !navigator.userActivation.isActive) armPicker();
    else showPicker();
  }

  const MIME_BY_EXT = { json: 'application/json', txt: 'text/plain', md: 'text/markdown', csv: 'text/csv', dxf: 'image/vnd.dxf', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp', svg: 'image/svg+xml', pdf: 'application/pdf' };
  function mimeFromName(name) {
    const i = name.lastIndexOf('.');
    return (i >= 0 && MIME_BY_EXT[name.slice(i + 1).toLowerCase()]) || 'application/octet-stream';
  }

  // ---- storage, clock, query, clipboard ------------------------------------

  function storage_get(id, keyPtr, keyLen) {
    let v = null;
    try { v = localStorage.getItem(str(keyPtr, keyLen)); } catch (e) { console.warn('[zunk fx] localStorage unavailable:', e); }
    push(KIND.storage_value, id, [v === null ? 0 : 1], [v === null ? null : utf8(v)]);
  }

  // An empty value deletes the key.
  function storage_set(keyPtr, keyLen, valPtr, valLen) {
    try {
      if (valLen === 0) localStorage.removeItem(str(keyPtr, keyLen));
      else localStorage.setItem(str(keyPtr, keyLen), str(valPtr, valLen));
    } catch (e) { console.warn('[zunk fx] localStorage write failed:', e); }
  }

  function clock(id) {
    const ms = new Uint8Array(8);
    new DataView(ms.buffer).setBigInt64(0, BigInt(Date.now()), true);
    push(KIND.clock, id, [-new Date().getTimezoneOffset()], [ms]);
  }

  function query_param(id, namePtr, nameLen) {
    const v = new URLSearchParams(location.search).get(str(namePtr, nameLen));
    push(KIND.query_value, id, [v === null ? 0 : 1], [v === null ? null : utf8(v)]);
  }

  function clipboard_write(ptr, len) {
    const t = str(ptr, len);
    const fallback = () => {
      const prev = document.activeElement;
      const ta = document.createElement('textarea');
      ta.value = t;
      ta.style.cssText = 'position:fixed;left:-9999px;opacity:0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); } catch (e) { console.warn('[zunk fx] clipboard write failed:', e); }
      ta.remove();
      if (prev && prev.focus) prev.focus();
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(t).catch(fallback);
    else fallback();
  }

  // ---- paste and drop (JS -> wasm, unsolicited) ----------------------------

  const editable = t => !!t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));

  function canvasFor(w, h) {
    return typeof OffscreenCanvas === 'function' ? new OffscreenCanvas(w, h) : Object.assign(document.createElement('canvas'), { width: w, height: h });
  }
  function encodePng(canvas) {
    return canvas.convertToBlob ? canvas.convertToBlob({ type: 'image/png' }) : new Promise((ok, no) => canvas.toBlob(b => b ? ok(b) : no(new Error('toBlob failed')), 'image/png'));
  }

  // Decode, downscale to MAX_IMAGE_SIDE, re-encode (PNG; a JPEG that needed no
  // downscale keeps its bytes), and make a THUMB_SIDE RGBA preview.
  async function ingestImage(file) {
    const bmp = await createImageBitmap(file);
    const long = Math.max(bmp.width, bmp.height);
    const scale = long > MAX_IMAGE_SIDE ? MAX_IMAGE_SIDE / long : 1;
    const w = Math.max(1, Math.round(bmp.width * scale)), h = Math.max(1, Math.round(bmp.height * scale));
    let bytes, mime;
    if (scale === 1 && file.type === 'image/jpeg') {
      bytes = new Uint8Array(await file.arrayBuffer());
      mime = 'image/jpeg';
    } else {
      const c = canvasFor(w, h);
      c.getContext('2d').drawImage(bmp, 0, 0, w, h);
      bytes = new Uint8Array(await (await encodePng(c)).arrayBuffer());
      mime = 'image/png';
    }
    const ts = THUMB_SIDE / Math.max(w, h);
    const tw = Math.max(1, Math.round(w * Math.min(1, ts))), th = Math.max(1, Math.round(h * Math.min(1, ts)));
    const tc = canvasFor(tw, th);
    const tctx = tc.getContext('2d');
    tctx.drawImage(bmp, 0, 0, tw, th);
    const thumb = new Uint8Array(tctx.getImageData(0, 0, tw, th).data.buffer);
    bmp.close();
    push(KIND.dropped, 0, [1, w, h, tw], [utf8(file.name || ''), utf8(mime), bytes, thumb]);
  }

  async function ingestFile(file) {
    try {
      if (file.type.startsWith('image/')) return await ingestImage(file);
      if (file.size > MAX_RESPONSE) return console.warn('[zunk fx] dropped file too large:', file.name);
      const bytes = new Uint8Array(await file.arrayBuffer());
      push(KIND.dropped, 0, [0], [utf8(file.name), utf8(file.type || mimeFromName(file.name)), bytes]);
    } catch (e) {
      console.warn('[zunk fx] could not read dropped file', file.name, e);
    }
  }

  document.addEventListener('paste', e => {
    const cd = e.clipboardData;
    if (!cd || editable(e.target)) return;
    const files = Array.from(cd.files || []);
    if (files.length > 0) files.forEach(ingestFile);
    else {
      const t = cd.getData('text/plain');
      if (t) push(KIND.pasted_text, 0, [], [utf8(t)]);
    }
    e.preventDefault();
  });
  const hasFiles = e => e.dataTransfer && Array.from(e.dataTransfer.types || []).includes('Files');
  document.addEventListener('dragover', e => { if (hasFiles(e)) { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; } });
  document.addEventListener('drop', e => {
    if (!e.dataTransfer || editable(e.target)) return;
    e.preventDefault();
    const files = Array.from(e.dataTransfer.files || []);
    if (files.length > 0) files.forEach(ingestFile);
    else {
      const t = e.dataTransfer.getData('text/plain');
      if (t) push(KIND.dropped, 0, [2], [null, utf8('text/plain'), utf8(t)]);
    }
  });

  return { pump, http, download, open_file, storage_get, storage_set, clock, query_param, clipboard_write };
})();
