const std = @import("std");
const wa = @import("wasm_analyze.zig");

pub const Resolution = struct {
    /// The JavaScript function body to generate
    js_body: []const u8,
    /// Whether this needs the handle table
    needs_handles: bool = false,
    /// Whether this needs the string helper (readStr)
    needs_string_helper: bool = false,
    /// Whether this needs the callback invoker
    needs_callbacks: bool = false,
    /// Whether this needs the memory view helper
    needs_memory_view: bool = false,
    /// Confidence level of the resolution
    confidence: Confidence,
    /// Human-readable description of what this binding does
    description: []const u8 = "",
    /// Category for grouping in generated JS
    category: Category = .unknown,
};

pub const Confidence = enum {
    /// Exact match to a known API -- will definitely work
    exact,
    /// Strong heuristic match -- very likely correct
    high,
    /// Inferred from signature/names -- probably correct
    medium,
    /// Best guess -- may need manual review
    low,
    /// No idea -- generates a stub
    stub,
};

pub const Category = enum {
    // Platform
    console,
    performance,
    dom,
    // Graphics
    canvas2d,
    webgpu,
    // Audio
    audio,
    // Input
    input,
    // Network
    fetch,
    websocket,
    // Assets
    asset,
    // Storage
    storage,
    clipboard,
    // Async host services (src/gen/js/fx.js): fetch, downloads, file picker,
    // storage, clock, query params, paste/drop
    fx,
    // IME bridge (src/gen/js/ime.js): hidden <textarea> for composition input
    ime,
    // UI
    ui,
    // Accessibility (hidden DOM mirror for screen readers)
    a11y,
    // Application
    lifecycle,
    timer,
    // Internal zunk plumbing
    zunk_internal,
    // Unknown -- needs manual binding or bridge.js
    unknown,
};

pub fn resolve(
    allocator: std.mem.Allocator,
    import: *const wa.Import,
    signature: ?wa.FuncType,
) !Resolution {
    const name = import.name;

    // Exact matches win over the `__` short-circuit. Without this, an
    // explicitly-registered `__zunk_*` import (e.g. teak's file-dialog
    // bridge) would silently fall through to the internal stub below.
    if (exactMatch(allocator, name)) |res| return res;

    if (std.mem.startsWith(u8, name, "__")) {
        return .{
            .js_body = try allocator.dupe(u8, "// internal"),
            .confidence = .exact,
            .category = .zunk_internal,
            .description = "Internal WASM symbol",
        };
    }

    if (try prefixMatch(allocator, name, signature)) |res| return res;
    if (try signatureInference(allocator, name, signature, import.param_names)) |res| return res;
    if (import.param_names.len > 0) {
        if (try paramNameInference(allocator, name, signature, import.param_names)) |res| return res;
    }
    return generateStub(allocator, name, signature);
}

const ExactEntry = struct {
    name: []const u8,
    js: []const u8,
    needs_handles: bool = false,
    needs_strings: bool = false,
    needs_callbacks: bool = false,
    needs_memory: bool = false,
    category: Category,
    desc: []const u8,
};

pub const exact_db = [_]ExactEntry{
    .{ .name = "console_log", .js = "const s = readStr(arguments[0], arguments[1]); console.log(s);", .needs_strings = true, .category = .console, .desc = "console.log with string" },
    .{ .name = "console_error", .js = "const s = readStr(arguments[0], arguments[1]); console.error(s);", .needs_strings = true, .category = .console, .desc = "console.error with string" },
    .{ .name = "console_warn", .js = "const s = readStr(arguments[0], arguments[1]); console.warn(s);", .needs_strings = true, .category = .console, .desc = "console.warn with string" },
    .{ .name = "log_i32", .js = "console.log('[i32]', arguments[0]);", .category = .console, .desc = "Log an i32 value" },
    .{ .name = "log_f32", .js = "console.log('[f32]', arguments[0]);", .category = .console, .desc = "Log an f32 value" },
    .{ .name = "log_f64", .js = "console.log('[f64]', arguments[0]);", .category = .console, .desc = "Log an f64 value" },

    .{ .name = "performance_now", .js = "return performance.now();", .category = .performance, .desc = "High-resolution timestamp" },
    .{ .name = "random", .js = "return Math.random();", .category = .performance, .desc = "Math.random()" },
    .{ .name = "random_int", .js = "return (Math.random() * 0x7FFFFFFF) | 0;", .category = .performance, .desc = "Random i32" },
    .{ .name = "now", .js = "return Date.now();", .category = .performance, .desc = "Unix timestamp ms" },
    .{ .name = "date_now", .js = "return Date.now();", .category = .performance, .desc = "Date.now()" },

    .{ .name = "setTimeout", .js = "return setTimeout(() => exports.__zunk_invoke_callback(arguments[0], 0, 0, 0, 0), arguments[1]);", .needs_callbacks = true, .category = .timer, .desc = "setTimeout" },
    .{ .name = "setInterval", .js = "return setInterval(() => exports.__zunk_invoke_callback(arguments[0], 0, 0, 0, 0), arguments[1]);", .needs_callbacks = true, .category = .timer, .desc = "setInterval" },
    .{ .name = "clearTimeout", .js = "clearTimeout(arguments[0]);", .category = .timer, .desc = "clearTimeout" },
    .{ .name = "clearInterval", .js = "clearInterval(arguments[0]);", .category = .timer, .desc = "clearInterval" },
    .{ .name = "requestAnimationFrame", .js = "return requestAnimationFrame((t) => exports.__zunk_invoke_callback(arguments[0], t, 0, 0, 0));", .needs_callbacks = true, .category = .timer, .desc = "requestAnimationFrame" },
    .{ .name = "cancelAnimationFrame", .js = "cancelAnimationFrame(arguments[0]);", .category = .timer, .desc = "cancelAnimationFrame" },

    .{ .name = "clipboard_write", .js = "navigator.clipboard.writeText(readStr(arguments[0], arguments[1]));", .needs_strings = true, .category = .clipboard, .desc = "Write to clipboard" },

    .{ .name = "alert", .js = "window.alert(readStr(arguments[0], arguments[1]));", .needs_strings = true, .category = .dom, .desc = "window.alert" },

    .{ .name = "localStorage_set", .js = "localStorage.setItem(readStr(arguments[0], arguments[1]), readStr(arguments[2], arguments[3]));", .needs_strings = true, .category = .storage, .desc = "localStorage.setItem" },
    .{ .name = "localStorage_remove", .js = "localStorage.removeItem(readStr(arguments[0], arguments[1]));", .needs_strings = true, .category = .storage, .desc = "localStorage.removeItem" },

    // File dialog bridge for teak Host (see zunk GitHub issue #14). Wasm
    // calls `__zunk_request_file_dialog(id, mode, name*, name_len, pat*,
    // pat_len)`; we open the browser picker and feed the result back via
    // the wasm export `__zunk_file_dialog_result(id, path*, path_len)`,
    // using the shared 64 KB string buffer as the path-bytes carrier.
    // `mode`: 0 = open, 1 = save. `pattern` is a Win32-style ";"-joined
    // glob list (e.g. "*.zig;*.zon"). Browser File System Access APIs are
    // gesture-gated -- the picker promise must start inside the same
    // synchronous turn as the originating user input, which holds here
    // because teak dispatches the request from inside its update() Msg
    // handler driven by the same click/key event.
    .{ .name = "__zunk_request_file_dialog", .js = "const id=arguments[0],mode=arguments[1];" ++
        "const name=readStr(arguments[2],arguments[3]);" ++
        "const pattern=readStr(arguments[4],arguments[5]);" ++
        "const done=(n)=>{if(typeof exports.__zunk_file_dialog_result==='function')exports.__zunk_file_dialog_result(id,n?n[0]:0,n?n[1]:0);};" ++
        "const api=mode===0?window.showOpenFilePicker:window.showSaveFilePicker;" ++
        "if(typeof api!=='function'){console.warn('[zunk] file picker API unavailable in this browser; request',id,'cancelled');done(null);return;}" ++
        "const exts=pattern.split(';').map(p=>p.trim()).filter(p=>p.startsWith('*.')&&p.length>2).map(p=>p.slice(1));" ++
        "const types=exts.length?[{description:name||'Files',accept:{'application/octet-stream':exts}}]:undefined;" ++
        "const opts=types?(mode===0?{types,multiple:false}:{types}):{};" ++
        "let p;try{p=mode===0?window.showOpenFilePicker(opts):window.showSaveFilePicker(opts);}catch(e){console.warn('[zunk] file picker threw synchronously:',e);done(null);return;}" ++
        "p.then(r=>{const h=Array.isArray(r)?r[0]:r;const bytes=new TextEncoder().encode(h.name);const ptr=exports.__zunk_string_buf_ptr();const cap=exports.__zunk_string_buf_len();const len=Math.min(bytes.length,cap);new Uint8Array(memory.buffer,ptr,len).set(bytes.subarray(0,len));done([ptr,len]);})" ++
        ".catch(()=>{done(null);});", .needs_strings = true, .needs_memory = true, .category = .dom, .desc = "Browser file picker (open/save); resolves async via __zunk_file_dialog_result" },

    // A11y DOM mirror for Teak (see zunk GitHub issue #15). Wasm calls
    // `__zunk_publish_a11y_tree(records*, records_len, strings*, strings_len)`
    // once per frame with the current snapshot of interactive widgets.
    // Buffers live in wasm linear memory; both are stable for the duration
    // of the call only. The JS shim mirrors the tree into a hidden DOM
    // subtree so AT (NVDA/JAWS/VoiceOver) can announce widgets that are
    // otherwise just pixels in a wgpu-driven canvas. See
    // `docs/to_teak_team/v0.10.0-a11y-bridge.md` for the wire format.
    .{ .name = "__zunk_publish_a11y_tree", .js = "const rptr=arguments[0],rlen=arguments[1],sptr=arguments[2],slen=arguments[3];" ++
        "if(!zunkA11yRoot){zunkA11yRoot=document.createElement('div');zunkA11yRoot.id='zunk-a11y-root';zunkA11yRoot.style.cssText='position:absolute;left:-9999px;top:0;width:1px;height:1px;overflow:hidden;';document.body.appendChild(zunkA11yRoot);}" ++
        "const dv=new DataView(memory.buffer,rptr,rlen);" ++
        "const seen=new Set();" ++
        "const count=(rlen/40)|0;" ++
        "for(let i=0;i<count;i++){" ++
        "const off=i*40;" ++
        "const cmd=dv.getUint32(off,true),role=dv.getUint32(off+4,true);" ++
        "const lof=dv.getUint32(off+8,true),llen=dv.getUint32(off+12,true);" ++
        "const state=dv.getFloat32(off+32,true),flags=dv.getUint32(off+36,true);" ++
        "if(role>11)continue;" ++
        "const label=llen?readStr(sptr+lof,llen):'';" ++
        "seen.add(cmd);" ++
        "let el=zunkA11yElements.get(cmd);" ++
        "if(!el||el._zunkRole!==role){if(el)el.remove();el=document.createElement(zunkA11yTags[role]);el._zunkRole=role;zunkA11yElements.set(cmd,el);zunkA11yRoot.appendChild(el);}" ++
        "const aria=zunkA11yAria[role];" ++
        "if(aria)el.setAttribute('role',aria);else el.removeAttribute('role');" ++
        "if(llen)el.setAttribute('aria-label',label);else el.removeAttribute('aria-label');" ++
        "switch(role){" ++
        "case 4:el.tabIndex=0;if(flags&1)el.setAttribute('data-focused','');else el.removeAttribute('data-focused');break;" ++
        "case 5:el.setAttribute('aria-multiline','false');break;" ++
        "case 6:case 7:el.setAttribute('aria-checked',state>=0.5?'true':'false');break;" ++
        "case 8:el.setAttribute('aria-valuenow',String(state));el.setAttribute('aria-valuemin','0');el.setAttribute('aria-valuemax','1');break;" ++
        "case 10:if(llen)el.alt=label;break;" ++
        "case 11:el.setAttribute('aria-modal','true');break;" ++
        "}" ++
        "}" ++
        "zunkA11yElements.forEach((el,key)=>{if(!seen.has(key)){el.remove();zunkA11yElements.delete(key);}});", .needs_strings = true, .needs_memory = true, .category = .a11y, .desc = "Mirror Teak's per-frame a11y tree into a hidden DOM subtree for screen readers" },
};

fn exactMatch(allocator: std.mem.Allocator, name: []const u8) ?Resolution {
    for (exact_db) |entry| {
        if (std.mem.eql(u8, name, entry.name)) {
            return .{
                .js_body = allocator.dupe(u8, entry.js) catch return null,
                .needs_handles = entry.needs_handles,
                .needs_string_helper = entry.needs_strings,
                .needs_callbacks = entry.needs_callbacks,
                .needs_memory_view = entry.needs_memory,
                .confidence = .exact,
                .category = entry.category,
                .description = entry.desc,
            };
        }
    }
    return null;
}

const PrefixRule = struct {
    prefix: []const u8,
    category: Category,
    generator: *const fn (
        allocator: std.mem.Allocator,
        method_name: []const u8,
        sig: ?wa.FuncType,
    ) ?Resolution,
};

pub const prefix_rules = [_]PrefixRule{
    .{ .prefix = "zunk_canvas_", .category = .canvas2d, .generator = &genCanvas },
    .{ .prefix = "zunk_c2d_", .category = .canvas2d, .generator = &genCanvas2D },
    .{ .prefix = "zunk_dom_", .category = .dom, .generator = &genDom },
    .{ .prefix = "zunk_input_", .category = .input, .generator = &genInput },
    .{ .prefix = "zunk_audio_", .category = .audio, .generator = &genAudio },
    .{ .prefix = "zunk_app_", .category = .lifecycle, .generator = &genApp },
    .{ .prefix = "zunk_asset_", .category = .asset, .generator = &genAsset },
    .{ .prefix = "zunk_fetch", .category = .fetch, .generator = &genFetch },
    .{ .prefix = "zunk_fx_", .category = .fx, .generator = &genFx },
    .{ .prefix = "zunk_ime_", .category = .ime, .generator = &genIme },
    .{ .prefix = "zunk_gpu_", .category = .webgpu, .generator = &genWebGPU },
    .{ .prefix = "zunk_text_", .category = .webgpu, .generator = &genWebGPU },
    .{ .prefix = "zunk_ui_", .category = .ui, .generator = &genUI },
    .{ .prefix = "canvas_", .category = .canvas2d, .generator = &genCanvas },
    .{ .prefix = "ctx2d_", .category = .canvas2d, .generator = &genCanvas2D },
    .{ .prefix = "dom_", .category = .dom, .generator = &genDom },
    .{ .prefix = "audio_", .category = .audio, .generator = &genAudio },
    .{ .prefix = "input_", .category = .input, .generator = &genInput },
    .{ .prefix = "gpu_", .category = .webgpu, .generator = &genWebGPU },
    .{ .prefix = "ui_", .category = .ui, .generator = &genUI },
    .{ .prefix = "ws_", .category = .websocket, .generator = &genWebSocket },
    .{ .prefix = "fetch_", .category = .fetch, .generator = &genFetch },
    .{ .prefix = "asset_", .category = .asset, .generator = &genAsset },
    .{ .prefix = "storage_", .category = .storage, .generator = &genStorage },
};

fn prefixMatch(allocator: std.mem.Allocator, name: []const u8, sig: ?wa.FuncType) !?Resolution {
    for (prefix_rules) |rule| {
        if (std.mem.startsWith(u8, name, rule.prefix)) {
            const method = name[rule.prefix.len..];
            if (rule.generator(allocator, method, sig)) |res| {
                return res;
            }
        }
    }
    return null;
}

fn genCanvas(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const js_map = .{
        .{ "get_2d", "const s = readStr(arguments[0], arguments[1]); const el = document.getElementById(s) || document.querySelector(s); return H.store(el.getContext('2d'));" },
        .{ "get_webgpu", "const s = readStr(arguments[0], arguments[1]); const el = document.getElementById(s) || document.querySelector(s); return H.store(el);" },
        .{ "set_size", "const c = H.get(arguments[0]).canvas || H.get(arguments[0]); c.width = arguments[1]; c.height = arguments[2];" },
        .{ "get_width", "return H.get(arguments[0]).width;" },
        .{ "get_height", "return H.get(arguments[0]).height;" },
        .{ "fullscreen", "H.get(arguments[0]).requestFullscreen();" },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_handles = std.mem.find(u8, entry[1], "H.") != null,
                .needs_string_helper = std.mem.find(u8, entry[1], "readStr") != null,
                .confidence = .exact,
                .category = .canvas2d,
                .description = "Canvas: " ++ entry[0],
            };
        }
    }
    return null;
}

fn genCanvas2D(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const js_map = .{
        .{ "fill_rect", "H.get(arguments[0]).fillRect(arguments[1], arguments[2], arguments[3], arguments[4]);" },
        .{ "stroke_rect", "H.get(arguments[0]).strokeRect(arguments[1], arguments[2], arguments[3], arguments[4]);" },
        .{ "clear_rect", "H.get(arguments[0]).clearRect(arguments[1], arguments[2], arguments[3], arguments[4]);" },
        .{ "fill_style_rgba", "H.get(arguments[0]).fillStyle = `rgba(${arguments[1]},${arguments[2]},${arguments[3]},${arguments[4]/255})`;" },
        .{ "stroke_style_rgba", "H.get(arguments[0]).strokeStyle = `rgba(${arguments[1]},${arguments[2]},${arguments[3]},${arguments[4]/255})`;" },
        .{ "line_width", "H.get(arguments[0]).lineWidth = arguments[1];" },
        .{ "begin_path", "H.get(arguments[0]).beginPath();" },
        .{ "close_path", "H.get(arguments[0]).closePath();" },
        .{ "move_to", "H.get(arguments[0]).moveTo(arguments[1], arguments[2]);" },
        .{ "line_to", "H.get(arguments[0]).lineTo(arguments[1], arguments[2]);" },
        .{ "arc", "H.get(arguments[0]).arc(arguments[1], arguments[2], arguments[3], arguments[4], arguments[5]);" },
        .{ "fill", "H.get(arguments[0]).fill();" },
        .{ "stroke", "H.get(arguments[0]).stroke();" },
        .{ "fill_text", "H.get(arguments[0]).fillText(readStr(arguments[1], arguments[2]), arguments[3], arguments[4]);" },
        .{ "set_font", "H.get(arguments[0]).font = readStr(arguments[1], arguments[2]);" },
        .{ "save", "H.get(arguments[0]).save();" },
        .{ "restore", "H.get(arguments[0]).restore();" },
        .{ "translate", "H.get(arguments[0]).translate(arguments[1], arguments[2]);" },
        .{ "rotate", "H.get(arguments[0]).rotate(arguments[1]);" },
        .{ "scale", "H.get(arguments[0]).scale(arguments[1], arguments[2]);" },
        .{ "draw_image", "H.get(arguments[0]).drawImage(H.get(arguments[1]), arguments[2], arguments[3]);" },
        .{ "set_global_alpha", "H.get(arguments[0]).globalAlpha = arguments[1];" },
        .{ "measure_text", "return H.get(arguments[0]).measureText(readStr(arguments[1], arguments[2])).width;" },
        .{ "clip", "H.get(arguments[0]).clip();" },
        .{ "set_text_baseline", "H.get(arguments[0]).textBaseline = readStr(arguments[1], arguments[2]);" },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            const needs_str = std.mem.find(u8, entry[1], "readStr") != null;
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_handles = true,
                .needs_string_helper = needs_str,
                .confidence = .exact,
                .category = .canvas2d,
            };
        }
    }
    return null;
}

fn genDom(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const js_map = .{
        .{ "set_text", "document.querySelector(readStr(arguments[0],arguments[1])).textContent = readStr(arguments[2],arguments[3]);" },
        .{ "set_html", "document.querySelector(readStr(arguments[0],arguments[1])).innerHTML = readStr(arguments[2],arguments[3]);" },
        .{ "set_attr", "document.querySelector(readStr(arguments[0],arguments[1])).setAttribute(readStr(arguments[2],arguments[3]), readStr(arguments[4],arguments[5]));" },
        .{ "query", "const el = document.querySelector(readStr(arguments[0],arguments[1])); return el ? H.store(el) : 0;" },
        .{ "create_element", "return H.store(document.createElement(readStr(arguments[0], arguments[1])));" },
        .{ "append_child", "H.get(arguments[0]).appendChild(H.get(arguments[1]));" },
        .{ "remove", "H.get(arguments[0]).remove();" },
        .{ "set_style", "H.get(arguments[0]).style[readStr(arguments[1],arguments[2])] = readStr(arguments[3],arguments[4]);" },
        .{ "add_class", "H.get(arguments[0]).classList.add(readStr(arguments[1],arguments[2]));" },
        .{ "remove_class", "H.get(arguments[0]).classList.remove(readStr(arguments[1],arguments[2]));" },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_handles = true,
                .needs_string_helper = true,
                .confidence = .exact,
                .category = .dom,
            };
        }
    }
    return null;
}

fn genInput(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const js_map = .{
        .{ "init", "zunkInput.init(arguments[0], arguments[1]);" },
        .{ "poll", "zunkInput.poll();" },
        .{ "set_key_callback", "zunkInput.onKey = arguments[0];" },
        .{ "set_mouse_callback", "zunkInput.onMouse = arguments[0];" },
        .{ "set_touch_callback", "zunkInput.onTouch = arguments[0];" },
        .{ "lock_pointer", "H.get(arguments[0]).requestPointerLock();" },
        .{ "unlock_pointer", "document.exitPointerLock();" },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_handles = std.mem.find(u8, entry[1], "H.get") != null,
                .needs_memory_view = std.mem.find(u8, entry[1], "zunkInput") != null,
                .confidence = .exact,
                .category = .input,
            };
        }
    }
    return null;
}

fn genAudio(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;

    const Entry = struct { []const u8, []const u8, bool, bool };
    const js_map = [_]Entry{
        .{ "init", "zunkAudioCtx = H.store(new AudioContext({sampleRate: arguments[0]})); return zunkAudioCtx;", false, false },
        .{ "resume", "H.get(zunkAudioCtx).resume();", false, false },
        .{ "suspend", "H.get(zunkAudioCtx).suspend();", false, false },
        .{ "load", "const url = readStr(arguments[0], arguments[1]); const h = H.nextId(); fetch(url).then(r=>r.arrayBuffer()).then(b=>H.get(zunkAudioCtx).decodeAudioData(b)).then(buf=>{H.set(h,buf);}); return h;", true, false },
        .{ "load_memory", "const bytes = new Uint8Array(memory.buffer, arguments[0], arguments[1]).slice(); const h = H.nextId(); H.get(zunkAudioCtx).decodeAudioData(bytes.buffer).then(buf=>{H.set(h,buf);}); return h;", false, true },
        .{ "is_ready", "return H.get(arguments[0]) !== undefined ? 1 : 0;", false, false },
        .{ "play", "const buf = H.get(arguments[0]); if(!buf) return; const ctx = H.get(zunkAudioCtx); const src = ctx.createBufferSource(); src.buffer = buf; if(zunkGain){src.connect(zunkGain);}else{src.connect(ctx.destination);} src.start();", false, false },
        .{ "decode_asset", "const buf = H.get(arguments[0]); if(!(buf instanceof ArrayBuffer)) return 0; const h = H.nextId(); H.get(zunkAudioCtx).decodeAudioData(buf.slice()).then(decoded=>{H.set(h,decoded);}); return h;", false, false },
        .{ "set_master_volume", "const ctx = H.get(zunkAudioCtx); if(!zunkGain){zunkGain=ctx.createGain();zunkGain.connect(ctx.destination);} zunkGain.gain.value = arguments[0];", false, false },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_handles = true,
                .needs_string_helper = entry[2],
                .needs_memory_view = entry[3],
                .confidence = .exact,
                .category = .audio,
            };
        }
    }
    return null;
}

fn genApp(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const js_map = .{
        .{ "request_frame", "requestAnimationFrame(zunkFrame);" },
        .{ "cancel_frame", "cancelAnimationFrame(zunkFrameId);" },
        .{ "performance_now", "return performance.now();" },
        .{ "set_title", "document.title = readStr(arguments[0], arguments[1]);" },
        .{ "open_url", "window.open(readStr(arguments[0], arguments[1]));" },
        .{ "log", "const msg = readStr(arguments[1], arguments[2]); [console.debug,console.log,console.warn,console.error][arguments[0]](msg);" },
        .{ "set_cursor", "document.body.style.cursor = readStr(arguments[0], arguments[1]);" },
        .{ "clipboard_write", "navigator.clipboard.writeText(readStr(arguments[0], arguments[1]));" },
        .{ "clipboard_read_len", "return zunkClipboardLen;" },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_string_helper = std.mem.find(u8, entry[1], "readStr") != null,
                .confidence = .exact,
                .category = .lifecycle,
            };
        }
    }
    return null;
}

fn genAsset(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const Entry = struct { []const u8, []const u8, bool, bool };
    const js_map = [_]Entry{
        .{ "fetch", "const url = readStr(arguments[0], arguments[1]); const h = H.nextId(); fetch(url).then(r=>r.arrayBuffer()).then(buf=>{H.set(h,buf);}); return h;", true, false },
        .{ "is_ready", "return H.get(arguments[0]) instanceof ArrayBuffer ? 1 : 0;", false, false },
        .{ "get_len", "const b=H.get(arguments[0]); return b instanceof ArrayBuffer ? b.byteLength : 0;", false, false },
        .{ "get_ptr", "const b=H.get(arguments[0]); if(!(b instanceof ArrayBuffer)) return 0; const src=new Uint8Array(b); new Uint8Array(memory.buffer,arguments[1],src.length).set(src); return src.length;", false, true },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_handles = true,
                .needs_string_helper = entry[2],
                .needs_memory_view = entry[3],
                .confidence = .exact,
                .category = .asset,
            };
        }
    }
    return null;
}

fn genWebGPU(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const Entry = struct { []const u8, []const u8, bool, bool, bool };

    const js_map = [_]Entry{
        // Handles / frame-scoped objects (see zunkGPU in js_gen.zig)
        .{ "release", "H.release(arguments[0]);", false, false, true },
        .{ "canvas_format", "return zunkGPU.textureFormats.indexOf(zunkGPUFormat);", false, false, true },
        .{ "canvas_size", "const c=zunkGPUContext.canvas,dv=new DataView(memory.buffer,arguments[0],8);" ++
            "dv.setUint32(0,c.width,true);dv.setUint32(4,c.height,true);", false, true, true },
        .{ "canvas_view", "return zunkGPU.canvasView();", false, false, true },
        .{ "frame_encoder", "return zunkGPU.encoder();", false, false, true },

        // Buffer
        .{ "create_buffer", "return H.store(H.get(1).createBuffer({size:arguments[0],usage:arguments[1],mappedAtCreation:false}));", false, false, true },
        .{ "buffer_write", "H.get(1).queue.writeBuffer(H.get(arguments[0]),arguments[1],new Uint8Array(memory.buffer,arguments[2],arguments[3]));", false, true, true },
        .{ "buffer_destroy", "H.get(arguments[0]).destroy();zunkGPU.maps.delete(arguments[0]);H.release(arguments[0]);", false, false, true },
        .{ "buffer_map_read", "zunkGPU.mapRead(arguments[0]);", false, false, true },
        .{ "buffer_map_state", "return zunkGPU.mapState(arguments[0]);", false, false, true },
        .{ "buffer_read_mapped", "zunkGPU.readMapped(arguments[0],arguments[1],arguments[2]);", false, true, true },
        .{ "buffer_unmap", "zunkGPU.unmap(arguments[0]);", false, false, true },
        .{ "copy_buffer_in_encoder", "H.get(arguments[0]).copyBufferToBuffer(H.get(arguments[1]),arguments[2],H.get(arguments[3]),arguments[4],arguments[5]);", false, false, true },
        .{ "copy_texture_to_buffer", "H.get(arguments[0]).copyTextureToBuffer({texture:H.get(arguments[1])}," ++
            "{buffer:H.get(arguments[2]),bytesPerRow:arguments[3]},{width:arguments[4],height:arguments[5]});", false, false, true },

        .{ "copy_texture_region_to_buffer", "H.get(arguments[0]).copyTextureToBuffer({texture:H.get(arguments[1]),origin:[arguments[4],arguments[5]]}," ++
            "{buffer:H.get(arguments[2]),bytesPerRow:arguments[3]},{width:arguments[6],height:arguments[7]});", false, false, true },

        .{ "create_shader_module", "return H.store(H.get(1).createShaderModule({code:readStr(arguments[0],arguments[1])}));", true, false, true },

        // Texture
        .{ "create_texture", "return H.store(H.get(1).createTexture({size:[arguments[0],arguments[1]]," ++
            "format:zunkGPU.textureFormats[arguments[2]],usage:arguments[3],sampleCount:arguments[4]}));", false, false, true },
        .{ "create_texture_view", "return H.store(H.get(arguments[0]).createView());", false, false, true },
        .{ "destroy_texture", "H.get(arguments[0]).destroy();H.release(arguments[0]);", false, false, true },
        .{ "write_texture_region", "const tex=H.get(arguments[0]);" ++
            "const src=new Uint8Array(memory.buffer,arguments[1],arguments[2]);" ++
            "H.get(1).queue.writeTexture({texture:tex,origin:[arguments[4],arguments[5]]},src," ++
            "{bytesPerRow:arguments[3]},{width:arguments[6],height:arguments[7]});", false, true, true },
        .{ "write_texture", "const tex=H.get(arguments[0]);" ++
            "const src=new Uint8Array(memory.buffer,arguments[1],arguments[2]);" ++
            "H.get(1).queue.writeTexture({texture:tex},src," ++
            "{bytesPerRow:arguments[3]}," ++
            "{width:arguments[4],height:arguments[5]});", false, false, true },

        // Sampler
        .{ "create_sampler", "const fm=['nearest','linear'],am=['clamp-to-edge','repeat','mirror-repeat'];" ++
            "const v=new DataView(memory.buffer,arguments[0],24);" ++
            "return H.store(H.get(1).createSampler({" ++
            "magFilter:fm[v.getUint32(0,true)],minFilter:fm[v.getUint32(4,true)]," ++
            "addressModeU:am[v.getUint32(8,true)],addressModeV:am[v.getUint32(12,true)]," ++
            "addressModeW:am[v.getUint32(16,true)]}));", false, true, true },
        .{ "destroy_sampler", "H.release(arguments[0]);", false, false, true },

        // Bind group layout / bind group
        .{ "create_bind_group_layout", "const sampleTypes=['float','unfilterable-float','depth','sint','uint'];" ++
            "const samplerTypes=['filtering','non-filtering','comparison'];" ++
            "const v=new DataView(memory.buffer,arguments[0],arguments[1]*40);" ++
            "const entries=[];for(let i=0;i<arguments[1];i++){const o=i*40;" ++
            "const e={binding:v.getUint32(o,true),visibility:v.getUint32(o+4,true)};" ++
            "const t=v.getUint32(o+8,true),tv=v.getUint32(o+12,true);" ++
            "if(t===0){e.buffer={type:['uniform','storage','read-only-storage'][tv]," ++
            "hasDynamicOffset:!!v.getUint32(o+20,true)};" ++
            "if(v.getUint32(o+16,true))e.buffer.minBindingSize=Number(v.getBigUint64(o+24,true));}" ++
            "else if(t===1){e.texture={sampleType:sampleTypes[tv]};}" ++
            "else if(t===2){e.sampler={type:samplerTypes[tv]};}" ++
            "entries.push(e);}" ++
            "return H.store(H.get(1).createBindGroupLayout({entries}));", false, true, true },

        .{ "create_bind_group", "const v=new DataView(memory.buffer,arguments[1],arguments[2]*32);" ++
            "const entries=[];for(let i=0;i<arguments[2];i++){const o=i*32;" ++
            "const e={binding:v.getUint32(o,true)};" ++
            "const t=v.getUint32(o+4,true);" ++
            "if(t===0){e.resource={buffer:H.get(v.getUint32(o+8,true))," ++
            "offset:Number(v.getBigUint64(o+16,true)),size:Number(v.getBigUint64(o+24,true))};" ++
            "}else{e.resource=H.get(v.getUint32(o+8,true));}entries.push(e);}" ++
            "return H.store(H.get(1).createBindGroup({layout:H.get(arguments[0]),entries}));", false, true, true },

        // Pipeline layout / pipelines
        .{ "create_pipeline_layout", "const v=new DataView(memory.buffer,arguments[0],arguments[1]*4);" ++
            "const layouts=[];for(let i=0;i<arguments[1];i++)layouts.push(H.get(v.getInt32(i*4,true)));" ++
            "return H.store(H.get(1).createPipelineLayout({bindGroupLayouts:layouts}));", false, true, true },

        .{ "create_compute_pipeline", "return H.store(H.get(1).createComputePipeline({layout:H.get(arguments[0])," ++
            "compute:{module:H.get(arguments[1]),entryPoint:readStr(arguments[2],arguments[3])}}));", true, false, true },

        .{ "create_render_pipeline", "return zunkGPU.createPipeline(arguments[0]);", true, true, true },

        // Command encoder
        .{ "create_command_encoder", "return H.store(H.get(1).createCommandEncoder());", false, false, true },
        .{ "begin_compute_pass", "return H.store(H.get(arguments[0]).beginComputePass());", false, false, true },
        .{ "encoder_finish", "const cb=H.get(arguments[0]).finish();H.release(arguments[0]);return H.store(cb);", false, false, true },
        .{ "queue_submit", "H.get(1).queue.submit([H.get(arguments[0])]);H.release(arguments[0]);", false, false, true },

        // Compute pass
        .{ "compute_pass_set_pipeline", "H.get(arguments[0]).setPipeline(H.get(arguments[1]));", false, false, true },
        .{ "compute_pass_set_bind_group", "H.get(arguments[0]).setBindGroup(arguments[1],H.get(arguments[2]));", false, false, true },
        .{ "compute_pass_set_bind_group_offset", "H.get(arguments[0]).setBindGroup(arguments[1],H.get(arguments[2]),[arguments[3]]);", false, false, true },
        .{ "compute_pass_dispatch", "H.get(arguments[0]).dispatchWorkgroups(arguments[1],arguments[2],arguments[3]);", false, false, true },
        .{ "compute_pass_end", "H.get(arguments[0]).end();H.release(arguments[0]);", false, false, true },

        // Render pass
        .{ "begin_render_pass", "return zunkGPU.beginPass(arguments[0]);", false, true, true },

        .{ "render_pass_set_pipeline", "H.get(arguments[0]).setPipeline(H.get(arguments[1]));", false, false, true },
        .{ "render_pass_set_bind_group", "H.get(arguments[0]).setBindGroup(arguments[1],H.get(arguments[2]));", false, false, true },
        .{ "render_pass_set_vertex_buffer", "const off=arguments[3]+arguments[4]*0x100000000;" ++
            "const sz=arguments[5]+arguments[6]*0x100000000;" ++
            "H.get(arguments[0]).setVertexBuffer(arguments[1],H.get(arguments[2]),off,sz);", false, false, true },
        .{ "render_pass_set_index_buffer", "const off=arguments[3]+arguments[4]*0x100000000;" ++
            "const sz=arguments[5]+arguments[6]*0x100000000;" ++
            "H.get(arguments[0]).setIndexBuffer(H.get(arguments[1]),['uint16','uint32'][arguments[2]],off,sz);", false, false, true },
        .{ "render_pass_set_viewport", "H.get(arguments[0]).setViewport(arguments[1],arguments[2],arguments[3],arguments[4],arguments[5],arguments[6]);", false, false, true },
        .{ "render_pass_set_stencil_reference", "H.get(arguments[0]).setStencilReference(arguments[1]);", false, false, true },
        .{ "render_pass_set_scissor_rect", "H.get(arguments[0]).setScissorRect(arguments[1],arguments[2],arguments[3],arguments[4]);", false, false, true },
        .{ "render_pass_draw", "H.get(arguments[0]).draw(arguments[1],arguments[2],arguments[3],arguments[4]);", false, false, true },
        .{ "render_pass_draw_indexed", "H.get(arguments[0]).drawIndexed(arguments[1],arguments[2],arguments[3],arguments[4],arguments[5]);", false, false, true },
        .{ "render_pass_end", "H.get(arguments[0]).end();H.release(arguments[0]);", false, false, true },

        // Present
        .{ "present", "zunkGPU.present();", false, false, true },

        // Asset texture
        .{ "create_texture_from_asset", "const buf=H.get(arguments[0]);" ++
            "if(!(buf instanceof ArrayBuffer))return 0;" ++
            "const h=H.nextId();" ++
            "createImageBitmap(new Blob([buf]),{colorSpaceConversion:'none'})" ++
            ".then(bmp=>{" ++
            "const tex=H.get(1).createTexture({format:'rgba8unorm'," ++
            "size:[bmp.width,bmp.height],usage:0x16});" ++
            "H.get(1).queue.copyExternalImageToTexture(" ++
            "{source:bmp},{texture:tex},{width:bmp.width,height:bmp.height});" ++
            "H.set(h,tex);});return h;", false, false, true },
        .{ "is_texture_ready", "const t=H.get(arguments[0]);return(t instanceof GPUTexture)?1:0;", false, false, true },

        // Text-to-texture (workstream 2). Uses an offscreen <canvas> 2D
        // context to shape and rasterize text via the browser's built-in
        // text engine, then uploads the pixels into a GPUTexture.
        .{ "measure_text", "if(!zunkTextCanvas){zunkTextCanvas=document.createElement('canvas');zunkTextCtx=zunkTextCanvas.getContext('2d',{willReadFrequently:true});}" ++
            "const text=readStr(arguments[0],arguments[1]),font=readStr(arguments[2],arguments[3]);" ++
            "zunkTextCtx.font=font;zunkTextCtx.letterSpacing=arguments[5]+'px';const m=zunkTextCtx.measureText(text);" ++
            "const w=Math.max(1,Math.ceil(m.width));" ++
            "const h=Math.max(1,Math.ceil((m.actualBoundingBoxAscent||0)+(m.actualBoundingBoxDescent||0)));" ++
            "const dv=new DataView(memory.buffer,arguments[4],8);" ++
            "dv.setUint32(0,w,true);dv.setUint32(4,h,true);", false, true, true },

        // One cluster -> r8 coverage bitmap in wasm memory (CJK / emoji
        // fallback). Args: text ptr/len, font ptr/len, size_px, out ptr/cap,
        // metrics ptr {u32 w,u32 h,i32 bearing_x,i32 bearing_y,f32 advance}.
        // Returns bytes written (0 = no ink or `out` too small; metrics valid).
        .{ "raster_cluster", "if(!zunkTextCanvas){zunkTextCanvas=document.createElement('canvas');zunkTextCtx=zunkTextCanvas.getContext('2d',{willReadFrequently:true});}" ++
            "const text=readStr(arguments[0],arguments[1]);let font=readStr(arguments[2],arguments[3]);const size=arguments[4];" ++
            "font=/[\\d.]+px/.test(font)?font.replace(/[\\d.]+px/,size+'px'):size+'px '+font;" ++
            "const cx=zunkTextCtx;cx.font=font;cx.letterSpacing='0px';cx.textBaseline='alphabetic';" ++
            "const m=cx.measureText(text);" ++
            "const mv=new DataView(memory.buffer,arguments[7],20);" ++
            "const left=Math.ceil(m.actualBoundingBoxLeft)+1,asc=Math.ceil(m.actualBoundingBoxAscent)+1;" ++
            "const w=left+Math.ceil(m.actualBoundingBoxRight)+1,h=asc+Math.ceil(m.actualBoundingBoxDescent)+1;" ++
            "const ink=m.actualBoundingBoxRight+m.actualBoundingBoxLeft>0&&m.actualBoundingBoxAscent+m.actualBoundingBoxDescent>0;" ++
            "mv.setUint32(0,ink?w:0,true);mv.setUint32(4,ink?h:0,true);mv.setInt32(8,-left,true);mv.setInt32(12,asc,true);mv.setFloat32(16,m.width,true);" ++
            "if(!ink||w*h>arguments[6])return 0;" ++
            "zunkTextCanvas.width=w;zunkTextCanvas.height=h;cx.clearRect(0,0,w,h);" ++
            "cx.font=font;cx.letterSpacing='0px';cx.textBaseline='alphabetic';cx.fillStyle='#fff';cx.fillText(text,left,asc);" ++
            "const d=cx.getImageData(0,0,w,h).data;const o=new Uint8Array(memory.buffer,arguments[5],w*h);" ++
            "for(let i=0;i<w*h;i++)o[i]=d[i*4+3];return w*h;", true, true, true },
        .{ "rasterize_text", "if(!zunkTextCanvas){zunkTextCanvas=document.createElement('canvas');zunkTextCtx=zunkTextCanvas.getContext('2d',{willReadFrequently:true});}" ++
            "const text=readStr(arguments[0],arguments[1]),font=readStr(arguments[2],arguments[3]);" ++
            "const r=arguments[4],g=arguments[5],b=arguments[6],a=arguments[7];" ++
            "const w=arguments[8],h=arguments[9];" ++
            "zunkTextCanvas.width=w;zunkTextCanvas.height=h;" ++
            "zunkTextCtx.clearRect(0,0,w,h);" ++
            "zunkTextCtx.font=font;zunkTextCtx.letterSpacing=arguments[10]+'px';zunkTextCtx.textBaseline='top';" ++
            "zunkTextCtx.fillStyle=`rgba(${Math.round(r*255)},${Math.round(g*255)},${Math.round(b*255)},${a})`;" ++
            "zunkTextCtx.fillText(text,0,0);" ++
            "const img=zunkTextCtx.getImageData(0,0,w,h);" ++
            "const tex=H.get(1).createTexture({size:[w,h],format:'rgba8unorm',usage:0x06});" ++
            "H.get(1).queue.writeTexture({texture:tex},img.data,{bytesPerRow:w*4},{width:w,height:h});" ++
            "return H.store(tex);", false, true, true },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_handles = entry[4],
                .needs_string_helper = entry[2],
                .needs_memory_view = entry[3],
                .confidence = .exact,
                .category = .webgpu,
            };
        }
    }
    return null;
}

fn genUI(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const Entry = struct { []const u8, []const u8, bool };
    const js_map = [_]Entry{
        // Panel management
        .{ "create_panel", "return zunkUI.createPanel(readStr(arguments[0],arguments[1]));", true },
        .{ "show_panel", "zunkUI.showPanel(arguments[0]);", false },
        .{ "hide_panel", "zunkUI.hidePanel(arguments[0]);", false },
        .{ "toggle_panel", "zunkUI.togglePanel(arguments[0]);", false },
        // Control creation
        .{ "add_slider", "return zunkUI.addSlider(arguments[0],readStr(arguments[1],arguments[2]),arguments[3],arguments[4],arguments[5],arguments[6]);", true },
        .{ "add_checkbox", "return zunkUI.addCheckbox(arguments[0],readStr(arguments[1],arguments[2]),arguments[3]);", true },
        .{ "add_button", "return zunkUI.addButton(arguments[0],readStr(arguments[1],arguments[2]));", true },
        .{ "add_separator", "return zunkUI.addSeparator(arguments[0]);", false },
        // Value reading
        .{ "get_float", "return zunkUI.getFloat(arguments[0]);", false },
        .{ "get_bool", "return zunkUI.getBool(arguments[0]);", false },
        .{ "is_clicked", "return zunkUI.isClicked(arguments[0]);", false },
        // Label / status
        .{ "set_label", "zunkUI.setLabel(arguments[0],readStr(arguments[1],arguments[2]));", true },
        .{ "set_status", "zunkUI.setStatus(readStr(arguments[0],arguments[1]));", true },
        // Fullscreen
        .{ "request_fullscreen", "document.documentElement.requestFullscreen();", false },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_string_helper = entry[2],
                .confidence = .exact,
                .category = .ui,
                .description = "UI: " ++ entry[0],
            };
        }
    }
    return null;
}

fn genFetch(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    if (method.len == 0 or std.mem.eql(u8, method, "get") or std.mem.eql(u8, method, "request")) {
        return .{
            .js_body = allocator.dupe(u8, "const url=readStr(arguments[0],arguments[1]); fetch(url).then(r=>r.arrayBuffer()).then(buf=>{zunkFetchBuf=new Uint8Array(buf); exports.__zunk_invoke_callback(arguments[2],200,zunkFetchBuf.length,0,0);}).catch(()=>{exports.__zunk_invoke_callback(arguments[2],-1,0,0,0);});") catch return null,
            .needs_string_helper = true,
            .needs_callbacks = true,
            .confidence = .exact,
            .category = .fetch,
        };
    }
    if (std.mem.eql(u8, method, "get_response_ptr")) {
        return .{
            .js_body = allocator.dupe(u8, "if(zunkFetchBuf){const ptr=exports.__zunk_string_buf_ptr(); new Uint8Array(memory.buffer,ptr,zunkFetchBuf.length).set(zunkFetchBuf); return ptr;} return 0;") catch return null,
            .needs_memory_view = true,
            .confidence = .exact,
            .category = .fetch,
        };
    }
    if (std.mem.eql(u8, method, "get_response_len")) {
        return .{
            .js_body = allocator.dupe(u8, "return zunkFetchBuf ? zunkFetchBuf.length : 0;") catch return null,
            .confidence = .exact,
            .category = .fetch,
        };
    }
    return null;
}

/// Imports of the host-services bridge (`src/gen/js/fx.js`, Zig side
/// `src/web/fx.zig`). Each `zunk_fx_<name>` forwards to `zunkFx.<name>`.
pub const fx_methods = [_][]const u8{
    "pump",            "http",        "download", "open_file",
    "storage_get",     "storage_set", "clock",    "query_param",
    "clipboard_write",
};

fn genFx(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    for (fx_methods) |name| {
        if (!std.mem.eql(u8, method, name)) continue;
        return .{
            .js_body = std.fmt.allocPrint(allocator, "return zunkFx.{s}(...arguments);", .{name}) catch return null,
            .needs_memory_view = true,
            .confidence = .exact,
            .category = .fx,
            .description = "Host services bridge (src/gen/js/fx.js)",
        };
    }
    return null;
}

/// Imports of the IME bridge (`src/gen/js/ime.js`, Zig side `src/web/ime.zig`).
pub const ime_methods = [_][]const u8{ "set_active", "set_spot", "poll" };

fn genIme(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    for (ime_methods) |name| {
        if (!std.mem.eql(u8, method, name)) continue;
        return .{
            .js_body = std.fmt.allocPrint(allocator, "return zunkIme.{s}(...arguments);", .{name}) catch return null,
            .needs_memory_view = true,
            .confidence = .exact,
            .category = .ime,
            .description = "IME bridge (src/gen/js/ime.js)",
        };
    }
    return null;
}

fn genWebSocket(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const js_map = .{
        .{ "connect", "return H.store(new WebSocket(readStr(arguments[0],arguments[1])));" },
        .{ "send", "H.get(arguments[0]).send(readStr(arguments[1],arguments[2]));" },
        .{ "close", "H.get(arguments[0]).close();" },
        .{ "on_message", "H.get(arguments[0]).onmessage=(e)=>{const b=new TextEncoder().encode(e.data); const ptr=exports.__zunk_string_buf_ptr(); new Uint8Array(memory.buffer,ptr,b.length).set(b); exports.__zunk_invoke_callback(arguments[1],b.length,0,0,0);};" },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_handles = true,
                .needs_string_helper = true,
                .needs_callbacks = std.mem.find(u8, entry[1], "invoke_callback") != null,
                .needs_memory_view = std.mem.find(u8, entry[1], "memory.buffer") != null,
                .confidence = .exact,
                .category = .websocket,
            };
        }
    }
    return null;
}

fn genStorage(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const js_map = .{
        .{ "set", "localStorage.setItem(readStr(arguments[0],arguments[1]),readStr(arguments[2],arguments[3]));" },
        .{ "get", "const v=localStorage.getItem(readStr(arguments[0],arguments[1])); if(v){const b=new TextEncoder().encode(v); const ptr=exports.__zunk_string_buf_ptr(); new Uint8Array(memory.buffer,ptr,b.length).set(b); return b.length;} return -1;" },
        .{ "remove", "localStorage.removeItem(readStr(arguments[0],arguments[1]));" },
        .{ "clear", "localStorage.clear();" },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_string_helper = true,
                .needs_memory_view = std.mem.find(u8, entry[1], "memory.buffer") != null,
                .confidence = .exact,
                .category = .storage,
            };
        }
    }
    return null;
}

fn signatureInference(
    allocator: std.mem.Allocator,
    name: []const u8,
    sig: ?wa.FuncType,
    param_names: []const []const u8,
) !?Resolution {
    _ = param_names;
    const ft = sig orelse return null;

    if (ft.params.len == 2 and
        ft.params[0] == .i32 and ft.params[1] == .i32 and
        ft.returns.len == 0)
    {
        if (containsAny(name, &.{ "log", "print", "write", "output", "trace", "debug" })) {
            return .{
                .js_body = try std.fmt.allocPrint(
                    allocator,
                    "console.log('[{s}]', readStr(arguments[0], arguments[1]));",
                    .{name},
                ),
                .needs_string_helper = true,
                .confidence = .high,
                .category = .console,
                .description = "Inferred: string -> console output",
            };
        }
    }

    if (ft.params.len == 2 and
        ft.params[0] == .i32 and ft.params[1] == .i32 and
        ft.returns.len == 1 and ft.returns[0] == .i32)
    {
        if (containsAny(name, &.{ "query", "select", "find", "get_element", "get_el" })) {
            return .{
                .js_body = try std.fmt.allocPrint(
                    allocator,
                    "const el = document.querySelector(readStr(arguments[0], arguments[1])); return el ? H.store(el) : 0;",
                    .{},
                ),
                .needs_handles = true,
                .needs_string_helper = true,
                .confidence = .high,
                .category = .dom,
                .description = "Inferred: string -> DOM query -> handle",
            };
        }
    }

    if (ft.params.len == 0 and ft.returns.len == 1 and ft.returns[0] == .f64) {
        if (containsAny(name, &.{ "time", "now", "perf", "timestamp", "clock" })) {
            return .{
                .js_body = try allocator.dupe(u8, "return performance.now();"),
                .confidence = .high,
                .category = .performance,
                .description = "Inferred: void -> f64 timestamp",
            };
        }
    }

    if (ft.params.len == 0 and ft.returns.len == 1 and
        (ft.returns[0] == .f64 or ft.returns[0] == .f32))
    {
        if (containsAny(name, &.{ "random", "rand" })) {
            return .{
                .js_body = try allocator.dupe(u8, "return Math.random();"),
                .confidence = .high,
                .category = .performance,
                .description = "Inferred: random number",
            };
        }
    }

    if (ft.params.len == 1 and ft.params[0] == .i32 and ft.returns.len == 0) {
        if (containsAny(name, &.{ "free", "release", "destroy", "drop", "dispose", "close" })) {
            return .{
                .js_body = try allocator.dupe(u8, "H.release(arguments[0]);"),
                .needs_handles = true,
                .confidence = .high,
                .category = .lifecycle,
                .description = "Inferred: release handle",
            };
        }
    }

    return null;
}

fn paramNameInference(
    allocator: std.mem.Allocator,
    name: []const u8,
    sig: ?wa.FuncType,
    param_names: []const []const u8,
) !?Resolution {
    _ = sig;

    if (param_names.len >= 4) {
        if (containsAny(param_names[0], &.{ "sel", "selector", "query", "el" }) and
            containsAny(param_names[2], &.{ "text", "txt", "html", "content", "val", "value" }))
        {
            const is_html = containsAny(param_names[2], &.{"html"});
            const prop = if (is_html) "innerHTML" else "textContent";
            return .{
                .js_body = try std.fmt.allocPrint(
                    allocator,
                    "document.querySelector(readStr(arguments[0],arguments[1])).{s} = readStr(arguments[2],arguments[3]);",
                    .{prop},
                ),
                .needs_string_helper = true,
                .confidence = .medium,
                .category = .dom,
                .description = try std.fmt.allocPrint(allocator, "Inferred from param names: {s} -> DOM setter", .{name}),
            };
        }
    }

    if (param_names.len >= 2) {
        if (containsAny(param_names[0], &.{ "url", "uri", "href", "path", "endpoint" })) {
            if (containsAny(name, &.{ "fetch", "request", "get", "load", "http" })) {
                return .{
                    .js_body = try std.fmt.allocPrint(
                        allocator,
                        "fetch(readStr(arguments[0],arguments[1])).then(r=>r.text()).then(t=>console.log('[{s}]',t));",
                        .{name},
                    ),
                    .needs_string_helper = true,
                    .confidence = .medium,
                    .category = .fetch,
                    .description = "Inferred from 'url' param: fetch request",
                };
            }
        }
    }

    return null;
}

fn generateStub(allocator: std.mem.Allocator, name: []const u8, sig: ?wa.FuncType) !Resolution {
    var body_aw: std.Io.Writer.Allocating = .init(allocator);
    defer body_aw.deinit();
    const w = &body_aw.writer;

    try w.print("console.warn('[zunk] unresolved import: {s}", .{name});

    if (sig) |ft| {
        try w.print("(", .{});
        for (ft.params, 0..) |p, i| {
            if (i > 0) try w.print(", ", .{});
            try w.print("{s}", .{@tagName(p)});
        }
        try w.print(") -> ", .{});
        if (ft.returns.len == 0) {
            try w.print("void", .{});
        } else {
            for (ft.returns, 0..) |r, i| {
                if (i > 0) try w.print(", ", .{});
                try w.print("{s}", .{@tagName(r)});
            }
        }
    }

    try w.print("', arguments);", .{});

    if (sig) |ft| {
        if (ft.returns.len > 0) {
            try w.print(" return 0;", .{});
        }
    }

    return .{
        .js_body = try body_aw.toOwnedSlice(),
        .confidence = .stub,
        .category = .unknown,
        .description = "Unresolved -- provide a bridge.js or use zunk naming conventions",
    };
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.find(u8, haystack, needle) != null) return true;
    }
    return false;
}

test "exact match console_log" {
    const res = exactMatch(std.testing.allocator, "console_log").?;
    defer std.testing.allocator.free(res.js_body);
    try std.testing.expect(res.confidence == .exact);
    try std.testing.expect(res.needs_string_helper);
}

test "prefix match canvas" {
    const res = (try prefixMatch(std.testing.allocator, "zunk_c2d_fill_rect", null)).?;
    defer std.testing.allocator.free(res.js_body);
    try std.testing.expect(res.category == .canvas2d);
    try std.testing.expect(res.confidence == .exact);
}

test "stub for unknown" {
    const res = try generateStub(std.testing.allocator, "some_custom_thing", null);
    defer std.testing.allocator.free(res.js_body);
    try std.testing.expect(res.confidence == .stub);
    try std.testing.expect(std.mem.find(u8, res.js_body, "unresolved") != null);
}

test "file dialog request resolves to exact match" {
    // Exact match must win even though the name starts with `__` (which
    // would otherwise short-circuit to the internal stub).
    const res = exactMatch(std.testing.allocator, "__zunk_request_file_dialog").?;
    defer std.testing.allocator.free(res.js_body);
    try std.testing.expect(res.confidence == .exact);
    try std.testing.expect(res.needs_string_helper);
    try std.testing.expect(res.needs_memory_view);
    try std.testing.expect(std.mem.find(u8, res.js_body, "showOpenFilePicker") != null);
    try std.testing.expect(std.mem.find(u8, res.js_body, "showSaveFilePicker") != null);
    try std.testing.expect(std.mem.find(u8, res.js_body, "__zunk_file_dialog_result") != null);
}

test "double-underscore import still falls through to internal stub when no exact match" {
    var imp: wa.Import = .{
        .module = "env",
        .name = "__unknown_internal",
        .type_idx = 0,
        .func_type = null,
        .param_names = &.{},
    };
    const res = try resolve(std.testing.allocator, &imp, null);
    defer std.testing.allocator.free(res.js_body);
    try std.testing.expect(res.category == .zunk_internal);
    try std.testing.expectEqualStrings("// internal", res.js_body);
}

test "prefix match webgpu create_buffer" {
    const res = (try prefixMatch(std.testing.allocator, "zunk_gpu_create_buffer", null)).?;
    defer std.testing.allocator.free(res.js_body);
    try std.testing.expect(res.category == .webgpu);
    try std.testing.expect(res.confidence == .exact);
    try std.testing.expect(res.needs_handles);
}

test "zunk_fx_ imports resolve to the host-services bridge, unknown ones do not" {
    const res = (try prefixMatch(std.testing.allocator, "zunk_fx_open_file", null)).?;
    defer std.testing.allocator.free(res.js_body);
    try std.testing.expect(res.category == .fx);
    try std.testing.expect(res.confidence == .exact);
    try std.testing.expectEqualStrings("return zunkFx.open_file(...arguments);", res.js_body);
    try std.testing.expect((try prefixMatch(std.testing.allocator, "zunk_fx_nope", null)) == null);
}

test "every fx import has a method in fx.js, and every method is listed" {
    const js = @embedFile("js/fx.js");
    for (fx_methods) |name| {
        const decl = try std.fmt.allocPrint(std.testing.allocator, "function {s}(", .{name});
        defer std.testing.allocator.free(decl);
        try std.testing.expect(std.mem.find(u8, js, decl) != null);
    }
    const ret = std.mem.find(u8, js, "return { pump").?;
    const line = js[ret..std.mem.findScalarPos(u8, js, ret, '\n').?];
    var listed: usize = 0;
    for (fx_methods) |name| {
        if (std.mem.find(u8, line, name) != null) listed += 1;
    }
    try std.testing.expectEqual(fx_methods.len, listed);
}

test "zunk_ime_ imports resolve to the IME bridge, and every one has a JS method" {
    const res = (try prefixMatch(std.testing.allocator, "zunk_ime_poll", null)).?;
    defer std.testing.allocator.free(res.js_body);
    try std.testing.expect(res.category == .ime);
    try std.testing.expectEqualStrings("return zunkIme.poll(...arguments);", res.js_body);
    try std.testing.expect((try prefixMatch(std.testing.allocator, "zunk_ime_nope", null)) == null);
    const js = @embedFile("js/ime.js");
    for (ime_methods) |name| {
        const decl = try std.fmt.allocPrint(std.testing.allocator, "function {s}(", .{name});
        defer std.testing.allocator.free(decl);
        try std.testing.expect(std.mem.find(u8, js, decl) != null);
    }
    try std.testing.expect(std.mem.find(u8, js, "return { set_active, set_spot, poll }") != null);
}

test "every zunk_gpu_* extern in web/gpu.zig resolves exactly" {
    const src = @embedFile("../web/gpu.zig");
    const decl = "extern \"env\" fn zunk_gpu_";
    var seen: usize = 0;
    var it = std.mem.tokenizeScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, decl)) continue;
        const name_end = std.mem.indexOfScalar(u8, line, '(').?;
        const name = line["extern \"env\" fn ".len..name_end];
        const res = (try prefixMatch(std.testing.allocator, name, null)) orelse {
            std.debug.print("unresolved import: {s}\n", .{name});
            return error.UnresolvedGpuImport;
        };
        defer std.testing.allocator.free(res.js_body);
        try std.testing.expect(res.confidence == .exact);
        seen += 1;
    }
    try std.testing.expect(seen > 40);
}

test "zunk_text_raster_cluster and write_texture_region resolve exactly" {
    const gpa = std.testing.allocator;
    inline for (.{ "zunk_text_raster_cluster", "zunk_gpu_write_texture_region" }) |name| {
        const res = (try prefixMatch(gpa, name, null)).?;
        defer gpa.free(res.js_body);
        try std.testing.expect(res.confidence == .exact);
        try std.testing.expect(res.needs_memory_view);
    }
    // The old canvas rasterizer is still wired.
    const old = (try prefixMatch(gpa, "zunk_gpu_rasterize_text", null)).?;
    defer gpa.free(old.js_body);
    try std.testing.expect(old.confidence == .exact);
}
