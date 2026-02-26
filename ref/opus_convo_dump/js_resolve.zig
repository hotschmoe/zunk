/// js_resolve.zig — Automatic JavaScript binding resolver.
///
/// Given a WASM import (name + type signature + optional param names),
/// determines what JavaScript to generate. Uses a multi-tier strategy:
///
///   Tier 1: EXACT MATCH — import name matches a known Web API pattern
///   Tier 2: PREFIX MATCH — name starts with a known namespace (canvas_, audio_, etc.)
///   Tier 3: SIGNATURE INFERENCE — (ptr,len) pairs → string, return i32 → handle, etc.
///   Tier 4: PARAM NAME INFERENCE — param names like "selector", "url", "volume" give hints
///   Tier 5: STUB — generate a warning stub, developer fills it in or ships a bridge.js
///
/// The knowledge base covers: DOM, Canvas 2D, WebGPU, Web Audio, Input Events,
/// Fetch, Clipboard, Performance, Storage, WebSocket, and more.

const std = @import("std");
const wa = @import("wasm_analyze.zig");

// ============================================================================
// Resolution result
// ============================================================================

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
    /// Exact match to a known API — will definitely work
    exact,
    /// Strong heuristic match — very likely correct
    high,
    /// Inferred from signature/names — probably correct
    medium,
    /// Best guess — may need manual review
    low,
    /// No idea — generates a stub
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
    // Storage
    storage,
    clipboard,
    // Application
    lifecycle,
    timer,
    // Internal zunk plumbing
    zunk_internal,
    // Unknown — needs manual binding or bridge.js
    unknown,
};

// ============================================================================
// Main resolver
// ============================================================================

pub fn resolve(
    allocator: std.mem.Allocator,
    import: *const wa.Import,
    signature: ?wa.FuncType,
) !Resolution {
    const name = import.name;

    // ---------------------------------------------------------------
    // Tier 0: Skip internal WASM imports
    // ---------------------------------------------------------------
    if (std.mem.startsWith(u8, name, "__")) {
        return .{
            .js_body = try allocator.dupe(u8, "// internal"),
            .confidence = .exact,
            .category = .zunk_internal,
            .description = "Internal WASM symbol",
        };
    }

    // ---------------------------------------------------------------
    // Tier 1: EXACT MATCH — known function names
    // ---------------------------------------------------------------
    if (exactMatch(allocator, name)) |res| return res;

    // ---------------------------------------------------------------
    // Tier 2: PREFIX MATCH — namespace-based resolution
    // ---------------------------------------------------------------
    if (try prefixMatch(allocator, name, signature)) |res| return res;

    // ---------------------------------------------------------------
    // Tier 3: SIGNATURE INFERENCE — deduce from param/return types
    // ---------------------------------------------------------------
    if (try signatureInference(allocator, name, signature, import.param_names)) |res| return res;

    // ---------------------------------------------------------------
    // Tier 4: PARAM NAME INFERENCE — use debug names as hints
    // ---------------------------------------------------------------
    if (import.param_names.len > 0) {
        if (try paramNameInference(allocator, name, signature, import.param_names)) |res| return res;
    }

    // ---------------------------------------------------------------
    // Tier 5: STUB — generate a warning placeholder
    // ---------------------------------------------------------------
    return generateStub(allocator, name, signature);
}

// ============================================================================
// Tier 1: Exact match database
// ============================================================================

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

/// Database of known Web API function names → JS implementations.
/// These are exact matches — if the Zig extern fn name matches, we know
/// exactly what JS to emit.
const exact_db = [_]ExactEntry{
    // --- Console ---
    .{ .name = "console_log", .js = "const s = readStr(arguments[0], arguments[1]); console.log(s);", .needs_strings = true, .category = .console, .desc = "console.log with string" },
    .{ .name = "console_error", .js = "const s = readStr(arguments[0], arguments[1]); console.error(s);", .needs_strings = true, .category = .console, .desc = "console.error with string" },
    .{ .name = "console_warn", .js = "const s = readStr(arguments[0], arguments[1]); console.warn(s);", .needs_strings = true, .category = .console, .desc = "console.warn with string" },
    .{ .name = "log_i32", .js = "console.log('[i32]', arguments[0]);", .category = .console, .desc = "Log an i32 value" },
    .{ .name = "log_f32", .js = "console.log('[f32]', arguments[0]);", .category = .console, .desc = "Log an f32 value" },
    .{ .name = "log_f64", .js = "console.log('[f64]', arguments[0]);", .category = .console, .desc = "Log an f64 value" },

    // --- Performance / Timing ---
    .{ .name = "performance_now", .js = "return performance.now();", .category = .performance, .desc = "High-resolution timestamp" },
    .{ .name = "random", .js = "return Math.random();", .category = .performance, .desc = "Math.random()" },
    .{ .name = "random_int", .js = "return (Math.random() * 0x7FFFFFFF) | 0;", .category = .performance, .desc = "Random i32" },
    .{ .name = "now", .js = "return Date.now();", .category = .performance, .desc = "Unix timestamp ms" },
    .{ .name = "date_now", .js = "return Date.now();", .category = .performance, .desc = "Date.now()" },

    // --- Timer ---
    .{ .name = "setTimeout", .js = "return setTimeout(() => exports.__zunk_invoke_callback(arguments[0], 0, 0, 0, 0), arguments[1]);", .needs_callbacks = true, .category = .timer, .desc = "setTimeout" },
    .{ .name = "setInterval", .js = "return setInterval(() => exports.__zunk_invoke_callback(arguments[0], 0, 0, 0, 0), arguments[1]);", .needs_callbacks = true, .category = .timer, .desc = "setInterval" },
    .{ .name = "clearTimeout", .js = "clearTimeout(arguments[0]);", .category = .timer, .desc = "clearTimeout" },
    .{ .name = "clearInterval", .js = "clearInterval(arguments[0]);", .category = .timer, .desc = "clearInterval" },
    .{ .name = "requestAnimationFrame", .js = "return requestAnimationFrame((t) => exports.__zunk_invoke_callback(arguments[0], t, 0, 0, 0));", .needs_callbacks = true, .category = .timer, .desc = "requestAnimationFrame" },
    .{ .name = "cancelAnimationFrame", .js = "cancelAnimationFrame(arguments[0]);", .category = .timer, .desc = "cancelAnimationFrame" },

    // --- Clipboard ---
    .{ .name = "clipboard_write", .js = "navigator.clipboard.writeText(readStr(arguments[0], arguments[1]));", .needs_strings = true, .category = .clipboard, .desc = "Write to clipboard" },

    // --- Alerts / Prompts ---
    .{ .name = "alert", .js = "window.alert(readStr(arguments[0], arguments[1]));", .needs_strings = true, .category = .dom, .desc = "window.alert" },

    // --- Storage ---
    .{ .name = "localStorage_set", .js = "localStorage.setItem(readStr(arguments[0], arguments[1]), readStr(arguments[2], arguments[3]));", .needs_strings = true, .category = .storage, .desc = "localStorage.setItem" },
    .{ .name = "localStorage_remove", .js = "localStorage.removeItem(readStr(arguments[0], arguments[1]));", .needs_strings = true, .category = .storage, .desc = "localStorage.removeItem" },
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

// ============================================================================
// Tier 2: Prefix/namespace match
// ============================================================================

const PrefixRule = struct {
    prefix: []const u8,
    category: Category,
    /// Function that generates JS body from the method name + signature
    generator: *const fn (
        allocator: std.mem.Allocator,
        method_name: []const u8,
        sig: ?wa.FuncType,
    ) ?Resolution,
};

const prefix_rules = [_]PrefixRule{
    // --- zunk_ namespaced (from the Layer 2 web modules) ---
    .{ .prefix = "zunk_canvas_", .category = .canvas2d, .generator = &genCanvas },
    .{ .prefix = "zunk_c2d_", .category = .canvas2d, .generator = &genCanvas2D },
    .{ .prefix = "zunk_dom_", .category = .dom, .generator = &genDom },
    .{ .prefix = "zunk_input_", .category = .input, .generator = &genInput },
    .{ .prefix = "zunk_audio_", .category = .audio, .generator = &genAudio },
    .{ .prefix = "zunk_app_", .category = .lifecycle, .generator = &genApp },
    .{ .prefix = "zunk_fetch", .category = .fetch, .generator = &genFetch },
    .{ .prefix = "zunk_gpu_", .category = .webgpu, .generator = &genWebGPU },
    // --- Raw Web API names (developer writes extern fn directly) ---
    .{ .prefix = "canvas_", .category = .canvas2d, .generator = &genCanvas },
    .{ .prefix = "ctx2d_", .category = .canvas2d, .generator = &genCanvas2D },
    .{ .prefix = "dom_", .category = .dom, .generator = &genDom },
    .{ .prefix = "audio_", .category = .audio, .generator = &genAudio },
    .{ .prefix = "input_", .category = .input, .generator = &genInput },
    .{ .prefix = "gpu_", .category = .webgpu, .generator = &genWebGPU },
    .{ .prefix = "ws_", .category = .websocket, .generator = &genWebSocket },
    .{ .prefix = "fetch_", .category = .fetch, .generator = &genFetch },
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

// ============================================================================
// Namespace generators — produce JS for each Web API domain
// ============================================================================

fn genCanvas(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const js_map = .{
        .{ "get_2d", "const el = document.querySelector(readStr(arguments[0], arguments[1])); return H.store(el.getContext('2d'));", true, true },
        .{ "get_webgpu", "const el = document.querySelector(readStr(arguments[0], arguments[1])); return H.store(el);", true, true },
        .{ "set_size", "const el = H.get(arguments[0]); el.width = arguments[1]; el.height = arguments[2];", true, false },
        .{ "get_width", "return H.get(arguments[0]).width;", true, false },
        .{ "get_height", "return H.get(arguments[0]).height;", true, false },
        .{ "fullscreen", "H.get(arguments[0]).requestFullscreen();", true, false },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_handles = entry[2],
                .needs_string_helper = entry[3],
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
    // Canvas2D methods all take a context handle as first arg
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
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            const needs_str = std.mem.indexOf(u8, entry[1], "readStr") != null;
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
                .needs_handles = std.mem.indexOf(u8, entry[1], "H.get") != null,
                .needs_memory_view = std.mem.indexOf(u8, entry[1], "zunkInput") != null,
                .confidence = .exact,
                .category = .input,
            };
        }
    }
    return null;
}

fn genAudio(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const js_map = .{
        .{ "init", "const ctx = new AudioContext({sampleRate: arguments[0]}); return H.store(ctx);" },
        .{ "resume", "H.get(zunkAudioCtx).resume();" },
        .{ "suspend", "H.get(zunkAudioCtx).suspend();" },
        .{ "load", "const url = readStr(arguments[0], arguments[1]); const h = H.nextId(); fetch(url).then(r=>r.arrayBuffer()).then(b=>H.get(zunkAudioCtx).decodeAudioData(b)).then(buf=>{H.set(h,buf);}); return h;" },
        .{ "play", "const src = H.get(zunkAudioCtx).createBufferSource(); src.buffer = H.get(arguments[0]); src.connect(H.get(zunkAudioCtx).destination); src.start();" },
        .{ "set_master_volume", "if(!zunkGain){zunkGain=H.get(zunkAudioCtx).createGain();zunkGain.connect(H.get(zunkAudioCtx).destination);} zunkGain.gain.value = arguments[0];" },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_handles = true,
                .needs_string_helper = std.mem.indexOf(u8, entry[1], "readStr") != null,
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
                .needs_string_helper = std.mem.indexOf(u8, entry[1], "readStr") != null,
                .confidence = .exact,
                .category = .lifecycle,
            };
        }
    }
    return null;
}

fn genWebGPU(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    const js_map = .{
        .{ "request_adapter", "const a = await navigator.gpu.requestAdapter(); return H.store(a);" },
        .{ "request_device", "const d = await H.get(arguments[0]).requestDevice(); return H.store(d);" },
        .{ "get_preferred_format", "return H.store(navigator.gpu.getPreferredCanvasFormat());" },
        .{ "configure_surface", "H.get(arguments[0]).getContext('webgpu').configure({device:H.get(arguments[1]),format:H.get(arguments[2])});" },
        .{ "create_shader", "return H.store(H.get(arguments[0]).createShaderModule({code:readStr(arguments[1],arguments[2])}));" },
        .{ "create_pipeline", "/* WebGPU pipeline — complex, see bridge.js */ return 0;" },
    };
    inline for (js_map) |entry| {
        if (std.mem.eql(u8, method, entry[0])) {
            return .{
                .js_body = allocator.dupe(u8, entry[1]) catch return null,
                .needs_handles = true,
                .needs_string_helper = std.mem.indexOf(u8, entry[1], "readStr") != null,
                .confidence = if (std.mem.indexOf(u8, entry[1], "bridge.js") != null) .medium else .exact,
                .category = .webgpu,
            };
        }
    }
    return null;
}

fn genFetch(allocator: std.mem.Allocator, method: []const u8, sig: ?wa.FuncType) ?Resolution {
    _ = sig;
    // For the bare "zunk_fetch" or "fetch_*" patterns
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
                .needs_callbacks = std.mem.indexOf(u8, entry[1], "invoke_callback") != null,
                .needs_memory_view = std.mem.indexOf(u8, entry[1], "memory.buffer") != null,
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
                .needs_memory_view = std.mem.indexOf(u8, entry[1], "memory.buffer") != null,
                .confidence = .exact,
                .category = .storage,
            };
        }
    }
    return null;
}

// ============================================================================
// Tier 3: Signature-based inference
// ============================================================================

fn signatureInference(
    allocator: std.mem.Allocator,
    name: []const u8,
    sig: ?wa.FuncType,
    param_names: []const []const u8,
) !?Resolution {
    _ = param_names;
    const ft = sig orelse return null;

    // Pattern: (i32, i32) → void with name containing "log" or "print" or "write"
    // Very likely: string output function
    if (ft.params.len == 2 and
        ft.params[0] == .i32 and ft.params[1] == .i32 and
        ft.returns.len == 0)
    {
        if (containsAny(name, &.{ "log", "print", "write", "output", "trace", "debug" })) {
            return .{
                .js_body = try std.fmt.allocPrint(allocator,
                    "console.log('[{s}]', readStr(arguments[0], arguments[1]));",
                    .{name},
                ),
                .needs_string_helper = true,
                .confidence = .high,
                .category = .console,
                .description = "Inferred: string → console output",
            };
        }
    }

    // Pattern: (i32, i32) → i32 with name containing "query", "get", "find", "select"
    // Likely: DOM query returning a handle
    if (ft.params.len == 2 and
        ft.params[0] == .i32 and ft.params[1] == .i32 and
        ft.returns.len == 1 and ft.returns[0] == .i32)
    {
        if (containsAny(name, &.{ "query", "select", "find", "get_element", "get_el" })) {
            return .{
                .js_body = try std.fmt.allocPrint(allocator,
                    "const el = document.querySelector(readStr(arguments[0], arguments[1])); return el ? H.store(el) : 0;",
                    .{},
                ),
                .needs_handles = true,
                .needs_string_helper = true,
                .confidence = .high,
                .category = .dom,
                .description = "Inferred: string → DOM query → handle",
            };
        }
    }

    // Pattern: () → f64 with name containing "time", "now", "perf"
    if (ft.params.len == 0 and ft.returns.len == 1 and ft.returns[0] == .f64) {
        if (containsAny(name, &.{ "time", "now", "perf", "timestamp", "clock" })) {
            return .{
                .js_body = try allocator.dupe(u8, "return performance.now();"),
                .confidence = .high,
                .category = .performance,
                .description = "Inferred: void → f64 timestamp",
            };
        }
    }

    // Pattern: () → f64 with name containing "random"
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

    // Pattern: (i32) → void with name containing "free", "release", "destroy", "drop"
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

// ============================================================================
// Tier 4: Parameter name inference
// ============================================================================

fn paramNameInference(
    allocator: std.mem.Allocator,
    name: []const u8,
    sig: ?wa.FuncType,
    param_names: []const []const u8,
) !?Resolution {
    _ = sig;

    // If we see (selector_ptr, selector_len, text_ptr, text_len) → likely a DOM setter
    if (param_names.len >= 4) {
        if (hasParamLike(param_names[0], &.{ "sel", "selector", "query", "el" }) and
            hasParamLike(param_names[2], &.{ "text", "txt", "html", "content", "val", "value" }))
        {
            const is_html = hasParamLike(param_names[2], &.{"html"});
            const prop = if (is_html) "innerHTML" else "textContent";
            return .{
                .js_body = try std.fmt.allocPrint(allocator,
                    "document.querySelector(readStr(arguments[0],arguments[1])).{s} = readStr(arguments[2],arguments[3]);",
                    .{prop},
                ),
                .needs_string_helper = true,
                .confidence = .medium,
                .category = .dom,
                .description = try std.fmt.allocPrint(allocator, "Inferred from param names: {s} → DOM setter", .{name}),
            };
        }
    }

    // If we see (url_ptr, url_len, ...) → likely a network/fetch call
    if (param_names.len >= 2) {
        if (hasParamLike(param_names[0], &.{ "url", "uri", "href", "path", "endpoint" })) {
            if (containsAny(name, &.{ "fetch", "request", "get", "load", "http" })) {
                return .{
                    .js_body = try std.fmt.allocPrint(allocator,
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

// ============================================================================
// Tier 5: Stub generation
// ============================================================================

fn generateStub(allocator: std.mem.Allocator, name: []const u8, sig: ?wa.FuncType) !Resolution {
    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    const w = body.writer();

    try w.print("console.warn('[zunk] unresolved import: {s}", .{name});

    if (sig) |ft| {
        try w.print("(", .{});
        for (ft.params, 0..) |p, i| {
            if (i > 0) try w.print(", ", .{});
            try w.print("{s}", .{@tagName(p)});
        }
        try w.print(") → ", .{});
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

    // If it returns a value, return 0
    if (sig) |ft| {
        if (ft.returns.len > 0) {
            try w.print(" return 0;", .{});
        }
    }

    return .{
        .js_body = try body.toOwnedSlice(),
        .confidence = .stub,
        .category = .unknown,
        .description = "Unresolved — provide a bridge.js or use zunk naming conventions",
    };
}

// ============================================================================
// Utility
// ============================================================================

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn hasParamLike(param_name: []const u8, hints: []const []const u8) bool {
    for (hints) |hint| {
        if (std.mem.indexOf(u8, param_name, hint) != null) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

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
    try std.testing.expect(std.mem.indexOf(u8, res.js_body, "unresolved") != null);
}
