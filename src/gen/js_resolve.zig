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
    // UI
    ui,
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

    if (std.mem.startsWith(u8, name, "__")) {
        return .{
            .js_body = try allocator.dupe(u8, "// internal"),
            .confidence = .exact,
            .category = .zunk_internal,
            .description = "Internal WASM symbol",
        };
    }

    if (exactMatch(allocator, name)) |res| return res;
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
    .{ .prefix = "zunk_gpu_", .category = .webgpu, .generator = &genWebGPU },
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

    // Shared vertex-buffer-layout decoder. Builds a JS snippet that reads a packed
    // VertexBufferLayout[]/VertexAttribute[] blob from wasm memory (arguments[ptr_idx],
    // arguments[len_idx]) and produces a `buffers` array consumable by GPUVertexState.
    const vbuf_decode = struct {
        fn snippet(comptime ptr_idx: []const u8, comptime len_idx: []const u8) []const u8 {
            return "const vfmts=['float32','float32x2','float32x3','float32x4','uint32','uint32x2','uint32x3','uint32x4','sint32','sint32x2','sint32x3','sint32x4'];" ++
                "const steps=['vertex','instance'];" ++
                "const buffers=[];" ++
                "if(arguments[" ++ len_idx ++ "]>0){const lv=new DataView(memory.buffer,arguments[" ++ ptr_idx ++ "],arguments[" ++ len_idx ++ "]*16);" ++
                "for(let i=0;i<arguments[" ++ len_idx ++ "];i++){const bo=i*16;" ++
                "const aPtr=lv.getUint32(bo+8,true),aLen=lv.getUint32(bo+12,true);" ++
                "const av=new DataView(memory.buffer,aPtr,aLen*16);const attrs=[];" ++
                "for(let j=0;j<aLen;j++){const ao=j*16;" ++
                "attrs.push({format:vfmts[av.getUint32(ao,true)],offset:av.getUint32(ao+4,true),shaderLocation:av.getUint32(ao+8,true)});}" ++
                "buffers.push({arrayStride:lv.getUint32(bo,true),stepMode:steps[lv.getUint32(bo+4,true)],attributes:attrs});}}";
        }
    };

    const js_map = [_]Entry{
        // Buffer
        .{ "create_buffer", "return H.store(H.get(1).createBuffer({size:arguments[0],usage:arguments[1],mappedAtCreation:false}));", false, false, true },
        .{ "buffer_write", "H.get(1).queue.writeBuffer(H.get(arguments[0]),arguments[1],new Uint8Array(memory.buffer,arguments[2],arguments[3]));", false, true, true },
        .{ "buffer_destroy", "H.get(arguments[0]).destroy();", false, false, true },
        .{ "copy_buffer_in_encoder", "H.get(arguments[0]).copyBufferToBuffer(H.get(arguments[1]),arguments[2],H.get(arguments[3]),arguments[4],arguments[5]);", false, false, true },

        .{ "create_shader_module", "return H.store(H.get(1).createShaderModule({code:readStr(arguments[0],arguments[1])}));", true, false, true },

        // Texture
        .{ "create_texture", "const fmts=['rgba16float','rgba32float','bgra8unorm','rgba8unorm','rgba8unorm-srgb','depth24plus','depth32float'];" ++
            "return H.store(H.get(1).createTexture({size:[arguments[0],arguments[1]],format:fmts[arguments[2]],usage:arguments[3]}));", false, false, true },
        .{ "create_texture_view", "return H.store(H.get(arguments[0]).createView());", false, false, true },
        .{ "destroy_texture", "H.get(arguments[0]).destroy();", false, false, true },

        // Bind group layout / bind group
        .{ "create_bind_group_layout", "const v=new DataView(memory.buffer,arguments[0],arguments[1]*40);" ++
            "const entries=[];for(let i=0;i<arguments[1];i++){const o=i*40;" ++
            "const e={binding:v.getUint32(o,true),visibility:v.getUint32(o+4,true)};" ++
            "const t=v.getUint32(o+8,true);" ++
            "if(t===0){e.buffer={type:['uniform','storage','read-only-storage'][v.getUint32(o+12,true)]," ++
            "hasDynamicOffset:!!v.getUint32(o+20,true)};" ++
            "if(v.getUint32(o+16,true))e.buffer.minBindingSize=Number(v.getBigUint64(o+24,true));}" ++
            "else if(t===1){e.texture={sampleType:'float'};}entries.push(e);}" ++
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

        .{ "create_render_pipeline", comptime vbuf_decode.snippet("6", "7") ++
            "return H.store(H.get(1).createRenderPipeline({layout:H.get(arguments[0])," ++
            "vertex:{module:H.get(arguments[1]),entryPoint:readStr(arguments[2],arguments[3]),buffers}," ++
            "fragment:{module:H.get(arguments[1]),entryPoint:readStr(arguments[4],arguments[5])," ++
            "targets:[{format:zunkGPUFormat,blend:{" ++
            "color:{srcFactor:'src-alpha',dstFactor:'one-minus-src-alpha'}," ++
            "alpha:{srcFactor:'one',dstFactor:'one-minus-src-alpha'}}}]}," ++
            "primitive:{topology:'triangle-list'}}));", true, true, true },

        .{ "create_render_pipeline_hdr", "const fmts=['rgba16float','rgba32float','bgra8unorm','rgba8unorm','rgba8unorm-srgb','depth24plus','depth32float'];" ++
            "const t={format:fmts[arguments[6]]};" ++
            "if(arguments[7]){t.blend={color:{srcFactor:'src-alpha',dstFactor:'one',operation:'add'}," ++
            "alpha:{srcFactor:'one',dstFactor:'one',operation:'add'}};}" ++
            comptime vbuf_decode.snippet("8", "9") ++
                "return H.store(H.get(1).createRenderPipeline({layout:H.get(arguments[0])," ++
                "vertex:{module:H.get(arguments[1]),entryPoint:readStr(arguments[2],arguments[3]),buffers}," ++
                "fragment:{module:H.get(arguments[1]),entryPoint:readStr(arguments[4],arguments[5])," ++
                "targets:[t]},primitive:{topology:'triangle-list'}}));", true, true, true },

        // Command encoder
        .{ "create_command_encoder", "return H.store(H.get(1).createCommandEncoder());", false, false, true },
        .{ "begin_compute_pass", "return H.store(H.get(arguments[0]).beginComputePass());", false, false, true },
        .{ "encoder_finish", "return H.store(H.get(arguments[0]).finish());", false, false, true },
        .{ "queue_submit", "H.get(1).queue.submit([H.get(arguments[0])]);", false, false, true },

        // Compute pass
        .{ "compute_pass_set_pipeline", "H.get(arguments[0]).setPipeline(H.get(arguments[1]));", false, false, true },
        .{ "compute_pass_set_bind_group", "H.get(arguments[0]).setBindGroup(arguments[1],H.get(arguments[2]));", false, false, true },
        .{ "compute_pass_set_bind_group_offset", "H.get(arguments[0]).setBindGroup(arguments[1],H.get(arguments[2]),[arguments[3]]);", false, false, true },
        .{ "compute_pass_dispatch", "H.get(arguments[0]).dispatchWorkgroups(arguments[1],arguments[2],arguments[3]);", false, false, true },
        .{ "compute_pass_end", "H.get(arguments[0]).end();", false, false, true },

        // Render pass
        .{ "begin_render_pass", "if(!zunkGPUEncoder)zunkGPUEncoder=H.get(1).createCommandEncoder();" ++
            "const v=zunkGPUContext.getCurrentTexture().createView();" ++
            "return H.store(zunkGPUEncoder.beginRenderPass({colorAttachments:[{view:v," ++
            "clearValue:{r:arguments[0],g:arguments[1],b:arguments[2],a:arguments[3]}," ++
            "loadOp:'clear',storeOp:'store'}]}));", false, false, true },

        .{ "begin_render_pass_hdr", "if(!zunkGPUEncoder)zunkGPUEncoder=H.get(1).createCommandEncoder();" ++
            "return H.store(zunkGPUEncoder.beginRenderPass({colorAttachments:[{view:H.get(arguments[0])," ++
            "clearValue:{r:arguments[1],g:arguments[2],b:arguments[3],a:arguments[4]}," ++
            "loadOp:'clear',storeOp:'store'}]}));", false, false, true },

        .{ "render_pass_set_pipeline", "H.get(arguments[0]).setPipeline(H.get(arguments[1]));", false, false, true },
        .{ "render_pass_set_bind_group", "H.get(arguments[0]).setBindGroup(arguments[1],H.get(arguments[2]));", false, false, true },
        .{ "render_pass_set_vertex_buffer", "const off=arguments[3]+arguments[4]*0x100000000;" ++
            "const sz=arguments[5]+arguments[6]*0x100000000;" ++
            "H.get(arguments[0]).setVertexBuffer(arguments[1],H.get(arguments[2]),off,sz);", false, false, true },
        .{ "render_pass_draw", "H.get(arguments[0]).draw(arguments[1],arguments[2],arguments[3],arguments[4]);", false, false, true },
        .{ "render_pass_end", "H.get(arguments[0]).end();", false, false, true },

        // Present
        .{ "present", "if(zunkGPUEncoder){H.get(1).queue.submit([zunkGPUEncoder.finish()]);zunkGPUEncoder=null;}", false, false, true },

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

test "prefix match webgpu create_buffer" {
    const res = (try prefixMatch(std.testing.allocator, "zunk_gpu_create_buffer", null)).?;
    defer std.testing.allocator.free(res.js_body);
    try std.testing.expect(res.category == .webgpu);
    try std.testing.expect(res.confidence == .exact);
    try std.testing.expect(res.needs_handles);
}
