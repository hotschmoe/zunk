/// A11y DOM-mirror demo (wire format v2, see src/gen/js/a11y.js).
///
/// Hand-builds the 64-byte records Teak's `Host.publishA11yTree` ships and
/// calls the same externs, to show the mirror end to end without Teak:
///   * a nested tree (toolbar > buttons, tablist > tabs, status live region);
///   * checkbox / slider / progressbar state updating in place;
///   * a textbox with a value and selection;
///   * actions coming back: click / focus / typed-value requests from the DOM
///     (assistive technology, or devtools `$0.click()`) are drained with
///     `__zunk_poll_a11y_actions` and counted on screen.
/// Inspect `#zunk-a11y-root` in devtools, or read the tree with a screen reader.
const std = @import("std");
const zunk = @import("zunk");
const canvas = zunk.web.canvas;
const input = zunk.web.input;
const app = zunk.web.app;

extern "env" fn __zunk_publish_a11y_tree(
    records_ptr: [*]const u8,
    records_len: u32,
    strings_ptr: [*]const u8,
    strings_len: u32,
) void;

extern "env" fn __zunk_poll_a11y_actions(
    records_ptr: [*]u8,
    records_cap: u32,
    strings_ptr: [*]u8,
    strings_cap: u32,
) u32;

const A11yRecord = extern struct {
    cmd_index: u32,
    role: u32,
    label_offset: u32,
    label_len: u32,
    bounds_x: i32,
    bounds_y: i32,
    bounds_w: i32,
    bounds_h: i32,
    state: f32,
    flags: u32,
    value_offset: u32,
    value_len: u32,
    sel_start: u32,
    sel_end: u32,
    parent: u32,
    level: u32,
};

comptime {
    if (@sizeOf(A11yRecord) != 64) @compileError("A11yRecord size drifted from wire format v2");
}

const ActionRecord = extern struct { kind: u32, cmd_index: u32, str_off: u32, str_len: u32 };

/// Wire role codes (a subset; the full table is in js/a11y.js).
const Role = enum(u32) {
    generic = 0,
    text = 2,
    button = 4,
    textbox = 5,
    checkbox = 6,
    slider = 8,
    img = 10,
    tablist = 18,
    tab = 19,
    progressbar = 25,
    status = 26,
    toolbar = 30,
};

const FLAG_FOCUSED: u32 = 1;
const FLAG_SELECTED: u32 = 4;
const FLAG_LIVE_POLITE: u32 = 64;
const NO_PARENT: u32 = 0xFFFFFFFF;

var records: [16]A11yRecord = undefined;
var strings: [512]u8 = undefined;
var actions: [8]ActionRecord = undefined;
var action_text: [128]u8 = undefined;
var ctx: canvas.Ctx2D = undefined;
var frame_count: u32 = 0;
var slider_value: f32 = 0.0;
var checkbox_on: bool = false;
var selected_tab: u32 = 0;
var clicks: u32 = 0;
var focus_requests: u32 = 0;
var value_requests: u32 = 0;
var status_buf: [64]u8 = undefined;
var status_len: usize = 0;

const bg = canvas.Color{ .r = 17, .g = 17, .b = 22 };
const white = canvas.Color{ .r = 220, .g = 220, .b = 220 };
const dim = canvas.Color{ .r = 110, .g = 110, .b = 120 };

export fn init() void {
    input.init();
    ctx = canvas.getContext2D("app");
    app.setTitle("zunk a11y-demo");
    canvas.setFont(ctx, "14px monospace");
}

export fn frame(_: f32) void {
    input.poll();

    // Tick a few values so the JS-side diff has something to update
    // each frame (aria-valuenow on the slider, aria-checked on the
    // checkbox). Demonstrates that the shim updates attributes in place
    // instead of rebuilding nodes.
    frame_count +%= 1;
    slider_value = @as(f32, @floatFromInt(frame_count % 240)) / 240.0;
    if (frame_count % 120 == 0) checkbox_on = !checkbox_on;

    pollActions();
    publishTree();
    draw();
}

export fn resize(w: u32, h: u32) void {
    canvas.setSize(ctx, w, h);
}

fn pollActions() void {
    const n = __zunk_poll_a11y_actions(@ptrCast(&actions), actions.len, &action_text, action_text.len);
    for (actions[0..n]) |a| {
        switch (a.kind) {
            0 => {
                clicks += 1;
                // A tab activation selects it (cmd_index 11 / 12).
                if (a.cmd_index == 11) selected_tab = 0;
                if (a.cmd_index == 12) selected_tab = 1;
                if (a.cmd_index == 2) checkbox_on = !checkbox_on;
            },
            1 => focus_requests += 1,
            2 => value_requests += 1,
            else => {},
        }
    }
    const out = std.fmt.bufPrint(&status_buf, "{d} clicks, {d} focus, {d} values", .{ clicks, focus_requests, value_requests }) catch status_buf[0..0];
    status_len = out.len;
}

fn publishTree() void {
    var used: u32 = 0;
    var n: usize = 0;
    n = add(n, &used, .{ .key = 0, .role = .toolbar, .label = "Main toolbar" });
    n = add(n, &used, .{ .key = 1, .role = .button, .label = "Open", .parent = 0 });
    n = add(n, &used, .{ .key = 2, .role = .checkbox, .label = "Enable feature", .state = if (checkbox_on) 1.0 else 0.0, .parent = 0 });
    n = add(n, &used, .{ .key = 3, .role = .slider, .label = "Volume", .state = slider_value, .parent = 0 });
    n = add(n, &used, .{ .key = 10, .role = .tablist, .label = "Views" });
    n = add(n, &used, .{ .key = 11, .role = .tab, .label = "Parts", .parent = 4, .flags = if (selected_tab == 0) FLAG_SELECTED else 0 });
    n = add(n, &used, .{ .key = 12, .role = .tab, .label = "Notes", .parent = 4, .flags = if (selected_tab == 1) FLAG_SELECTED else 0 });
    n = add(n, &used, .{ .key = 20, .role = .textbox, .label = "Name", .value = "zunk", .sel = .{ 1, 3 } });
    n = add(n, &used, .{ .key = 30, .role = .progressbar, .label = "Upload", .state = slider_value });
    n = add(n, &used, .{ .key = 40, .role = .status, .flags = FLAG_LIVE_POLITE });
    n = add(n, &used, .{ .key = 41, .role = .text, .label = status_buf[0..status_len], .parent = 9 });
    if ((frame_count / 60) % 2 == 0) {
        n = add(n, &used, .{ .key = 5, .role = .img, .label = "Decorative image" });
    }
    __zunk_publish_a11y_tree(@ptrCast(&records), @intCast(n * @sizeOf(A11yRecord)), &strings, used);
}

const Node = struct {
    key: u32,
    role: Role,
    label: []const u8 = "",
    value: []const u8 = "",
    sel: [2]u32 = .{ 0, 0 },
    state: f32 = 0,
    flags: u32 = 0,
    parent: u32 = NO_PARENT,
};

fn put(used: *u32, bytes: []const u8) [2]u32 {
    if (bytes.len == 0 or used.* + bytes.len > strings.len) return .{ 0, 0 };
    const off = used.*;
    @memcpy(strings[off..][0..bytes.len], bytes);
    used.* += @intCast(bytes.len);
    return .{ off, @intCast(bytes.len) };
}

fn add(count: usize, used: *u32, node: Node) usize {
    const label = put(used, node.label);
    const value = put(used, node.value);
    records[count] = .{
        .cmd_index = node.key,
        .role = @intFromEnum(node.role),
        .label_offset = label[0],
        .label_len = label[1],
        .bounds_x = @intCast(40 + count * 8),
        .bounds_y = @intCast(120 + count * 24),
        .bounds_w = 200,
        .bounds_h = 20,
        .state = node.state,
        .flags = node.flags,
        .value_offset = value[0],
        .value_len = value[1],
        .sel_start = node.sel[0],
        .sel_end = node.sel[1],
        .parent = node.parent,
        .level = 0,
    };
    return count + 1;
}

fn draw() void {
    const vp = input.getViewportSize();
    const w: f32 = @floatFromInt(vp.w);
    const h: f32 = @floatFromInt(vp.h);

    canvas.setFillColor(ctx, bg);
    canvas.fillRect(ctx, 0, 0, w, h);

    canvas.setFillColor(ctx, white);
    canvas.setFont(ctx, "22px monospace");
    canvas.fillText(ctx, "zunk a11y demo", 40, 50);

    canvas.setFont(ctx, "13px monospace");
    canvas.setFillColor(ctx, dim);
    canvas.fillText(ctx, "open devtools, inspect #zunk-a11y-root, watch attrs update", 40, 76);
    canvas.fillText(ctx, "screen readers see the mirror; canvas pixels stay opaque to them", 40, 96);
    canvas.fillText(ctx, status_buf[0..status_len], 40, 116);
}
