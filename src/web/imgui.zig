const input = @import("input.zig");
const rb = @import("render_backend.zig");

pub const Canvas2DBackend = rb.Canvas2DBackend;
pub const Rect = rb.Rect;
pub const Color = rb.Color;

pub const Id = u32;
pub const null_id: Id = 0;

pub const Theme = struct {
    bg: Color = .{ .r = 30, .g = 30, .b = 30, .a = 230 },
    bg_hover: Color = .{ .r = 50, .g = 50, .b = 50, .a = 230 },
    bg_active: Color = .{ .r = 70, .g = 70, .b = 70, .a = 230 },
    border: Color = .{ .r = 80, .g = 80, .b = 80, .a = 255 },
    text: Color = .{ .r = 220, .g = 220, .b = 220, .a = 255 },
    text_dim: Color = .{ .r = 140, .g = 140, .b = 140, .a = 255 },
    accent: Color = .{ .r = 70, .g = 130, .b = 230, .a = 255 },
    accent_hover: Color = .{ .r = 90, .g = 150, .b = 250, .a = 255 },
    slider_track: Color = .{ .r = 60, .g = 60, .b = 60, .a = 255 },
    slider_fill: Color = .{ .r = 70, .g = 130, .b = 230, .a = 255 },
    check_mark: Color = .{ .r = 70, .g = 130, .b = 230, .a = 255 },
    separator: Color = .{ .r = 60, .g = 60, .b = 60, .a = 255 },
    panel_title_bg: Color = .{ .r = 40, .g = 40, .b = 40, .a = 240 },

    row_height: f32 = 28,
    padding: f32 = 8,
    item_spacing: f32 = 4,
    border_width: f32 = 1,
    slider_height: f32 = 20,
    checkbox_size: f32 = 18,
    font_body: []const u8 = "14px monospace",
    font_title: []const u8 = "15px monospace",
};

pub const default_theme = Theme{};

const LayoutDir = enum { vertical, horizontal };

const LayoutEntry = struct {
    dir: LayoutDir,
    bounds: Rect,
    cursor_x: f32,
    cursor_y: f32,
    max_cross: f32,
};

const MAX_LAYOUT_DEPTH = 16;

pub fn Ui(comptime Backend: type) type {
    comptime {
        rb.validateBackend(Backend);
    }

    return struct {
        const Self = @This();

        backend: Backend,
        theme: Theme,

        hot: Id = null_id,
        active: Id = null_id,

        mouse_x: f32 = 0,
        mouse_y: f32 = 0,
        mouse_down: bool = false,
        was_mouse_down: bool = false,

        layout_stack: [MAX_LAYOUT_DEPTH]LayoutEntry = undefined,
        layout_depth: u32 = 0,

        pub fn init(backend: Backend) Self {
            return initWithTheme(backend, default_theme);
        }

        pub fn initWithTheme(backend: Backend, theme: Theme) Self {
            return .{
                .backend = backend,
                .theme = theme,
            };
        }

        pub fn begin(self: *Self, available_width: f32) void {
            const mouse = input.getMouse();
            self.was_mouse_down = self.mouse_down;
            self.mouse_x = mouse.x;
            self.mouse_y = mouse.y;
            self.mouse_down = mouse.buttons.left;
            self.hot = null_id;
            self.layout_depth = 0;
            self.pushLayout(.{
                .dir = .vertical,
                .bounds = .{ .x = 0, .y = 0, .w = available_width, .h = 100000 },
                .cursor_x = 0,
                .cursor_y = 0,
                .max_cross = 0,
            });
        }

        pub fn end(self: *Self) void {
            if (self.layout_depth > 0) {
                self.layout_depth = 0;
            }
            if (!self.mouse_down) {
                self.active = null_id;
            }
        }

        // -- ID system --

        fn hashId(label_str: []const u8) Id {
            // FNV-1a
            var h: u32 = 2166136261;
            for (label_str) |c| {
                h ^= c;
                h *%= 16777619;
            }
            return if (h == null_id) 1 else h;
        }

        fn displayLabel(label_str: []const u8) []const u8 {
            for (label_str, 0..) |c, i| {
                if (c == '#' and i + 1 < label_str.len and label_str[i + 1] == '#') {
                    return label_str[0..i];
                }
            }
            return label_str;
        }

        // -- Layout --

        fn pushLayout(self: *Self, entry: LayoutEntry) void {
            if (self.layout_depth < MAX_LAYOUT_DEPTH) {
                self.layout_stack[self.layout_depth] = entry;
                self.layout_depth += 1;
            }
        }

        fn popLayout(self: *Self) ?LayoutEntry {
            if (self.layout_depth > 0) {
                self.layout_depth -= 1;
                return self.layout_stack[self.layout_depth];
            }
            return null;
        }

        fn currentLayout(self: *Self) *LayoutEntry {
            return &self.layout_stack[self.layout_depth - 1];
        }

        fn allocRect(self: *Self, w: f32, h: f32) Rect {
            const lay = self.currentLayout();
            const rect = Rect{
                .x = lay.cursor_x,
                .y = lay.cursor_y,
                .w = w,
                .h = h,
            };
            switch (lay.dir) {
                .vertical => {
                    lay.cursor_y += h + self.theme.item_spacing;
                    if (w > lay.max_cross) lay.max_cross = w;
                },
                .horizontal => {
                    lay.cursor_x += w + self.theme.item_spacing;
                    if (h > lay.max_cross) lay.max_cross = h;
                },
            }
            return rect;
        }

        fn availableWidth(self: *Self) f32 {
            const lay = self.currentLayout();
            return lay.bounds.w - (lay.cursor_x - lay.bounds.x);
        }

        // -- Interaction helpers --

        fn mousePressed(self: *Self) bool {
            return self.mouse_down and !self.was_mouse_down;
        }

        fn mouseReleased(self: *Self) bool {
            return !self.mouse_down and self.was_mouse_down;
        }

        fn isHovered(self: *Self, rect: Rect) bool {
            return rect.contains(self.mouse_x, self.mouse_y);
        }

        fn updateHotActive(self: *Self, id: Id, rect: Rect) void {
            if (self.isHovered(rect)) {
                self.hot = id;
                if (self.active == null_id and self.mousePressed()) {
                    self.active = id;
                }
            }
        }

        fn widgetColor(self: *Self, id: Id) Color {
            if (self.active == id) return self.theme.bg_active;
            if (self.hot == id) return self.theme.bg_hover;
            return self.theme.bg;
        }

        // -- Widgets --

        pub fn label(self: *Self, text: []const u8) void {
            const w = self.availableWidth();
            const rect = self.allocRect(w, self.theme.row_height);
            self.backend.setFont(self.theme.font_body);
            self.backend.drawText(
                text,
                rect.x + self.theme.padding,
                rect.y + (self.theme.row_height - 14) / 2,
                self.theme.text,
            );
        }

        pub fn separator(self: *Self) void {
            const w = self.availableWidth();
            const rect = self.allocRect(w, self.theme.item_spacing * 2 + 1);
            const y = rect.y + self.theme.item_spacing;
            self.backend.drawFilledRect(
                .{ .x = rect.x, .y = y, .w = w, .h = 1 },
                self.theme.separator,
            );
        }

        pub fn button(self: *Self, label_str: []const u8) bool {
            const id = hashId(label_str);
            const display = displayLabel(label_str);

            const w = self.availableWidth();
            const rect = self.allocRect(w, self.theme.row_height);

            self.updateHotActive(id, rect);
            const clicked = self.hot == id and self.active == id and self.mouseReleased();

            self.backend.drawFilledRect(rect, self.widgetColor(id));
            self.backend.drawStrokedRect(rect, self.theme.border, self.theme.border_width);
            self.backend.setFont(self.theme.font_body);
            const tw = self.backend.measureText(display);
            self.backend.drawText(
                display,
                rect.x + (rect.w - tw) / 2,
                rect.y + (self.theme.row_height - 14) / 2,
                self.theme.text,
            );
            return clicked;
        }

        pub fn checkbox(self: *Self, label_str: []const u8, value: *bool) bool {
            const id = hashId(label_str);
            const display = displayLabel(label_str);

            const w = self.availableWidth();
            const rect = self.allocRect(w, self.theme.row_height);

            self.updateHotActive(id, rect);
            const toggled = self.hot == id and self.active == id and self.mouseReleased();
            if (toggled) value.* = !value.*;

            // checkbox box
            const box_y = rect.y + (self.theme.row_height - self.theme.checkbox_size) / 2;
            const box_rect = Rect{
                .x = rect.x + self.theme.padding,
                .y = box_y,
                .w = self.theme.checkbox_size,
                .h = self.theme.checkbox_size,
            };
            self.backend.drawFilledRect(box_rect, self.widgetColor(id));
            self.backend.drawStrokedRect(box_rect, self.theme.border, self.theme.border_width);

            if (value.*) {
                const inner = box_rect.shrink(4);
                self.backend.drawFilledRect(inner, self.theme.check_mark);
            }

            // label
            self.backend.setFont(self.theme.font_body);
            self.backend.drawText(
                display,
                rect.x + self.theme.padding + self.theme.checkbox_size + self.theme.padding,
                rect.y + (self.theme.row_height - 14) / 2,
                self.theme.text,
            );
            return toggled;
        }

        pub fn slider(self: *Self, label_str: []const u8, value: *f32, min_val: f32, max_val: f32) bool {
            const id = hashId(label_str);
            const display = displayLabel(label_str);

            const w = self.availableWidth();
            const rect = self.allocRect(w, self.theme.row_height + self.theme.slider_height);

            // label row
            self.backend.setFont(self.theme.font_body);
            self.backend.drawText(
                display,
                rect.x + self.theme.padding,
                rect.y + (self.theme.row_height - 14) / 2,
                self.theme.text,
            );

            // value display (right-aligned)
            var buf: [32]u8 = undefined;
            const val_str = formatFloat(buf[0..], value.*);
            const val_tw = self.backend.measureText(val_str);
            self.backend.drawText(
                val_str,
                rect.x + rect.w - self.theme.padding - val_tw,
                rect.y + (self.theme.row_height - 14) / 2,
                self.theme.text_dim,
            );

            // track
            const track_x = rect.x + self.theme.padding;
            const track_y = rect.y + self.theme.row_height;
            const track_w = rect.w - self.theme.padding * 2;
            const track_rect = Rect{
                .x = track_x,
                .y = track_y,
                .w = track_w,
                .h = self.theme.slider_height,
            };

            self.updateHotActive(id, track_rect);

            var changed = false;
            if (self.active == id) {
                const range = max_val - min_val;
                var t = (self.mouse_x - track_x) / track_w;
                if (t < 0) t = 0;
                if (t > 1) t = 1;
                const new_val = min_val + t * range;
                if (new_val != value.*) {
                    value.* = new_val;
                    changed = true;
                }
            }

            // draw track background
            self.backend.drawFilledRect(track_rect, self.theme.slider_track);

            // draw fill
            const range = max_val - min_val;
            const fill_t = if (range > 0) (value.* - min_val) / range else 0;
            if (fill_t > 0) {
                self.backend.drawFilledRect(
                    .{ .x = track_x, .y = track_y, .w = track_w * fill_t, .h = self.theme.slider_height },
                    self.theme.slider_fill,
                );
            }

            // draw track border
            self.backend.drawStrokedRect(track_rect, self.theme.border, self.theme.border_width);

            return changed;
        }

        // -- Containers --

        pub fn beginPanel(self: *Self, title: []const u8) void {
            const w = self.availableWidth();
            const outer_rect = self.allocRect(w, 0);

            self.backend.pushState();

            // title bar
            const title_rect = Rect{
                .x = outer_rect.x,
                .y = outer_rect.y,
                .w = w,
                .h = self.theme.row_height,
            };
            self.backend.drawFilledRect(title_rect, self.theme.panel_title_bg);
            self.backend.setFont(self.theme.font_title);
            self.backend.drawText(
                title,
                title_rect.x + self.theme.padding,
                title_rect.y + (self.theme.row_height - 15) / 2,
                self.theme.text,
            );

            // push inner layout below title
            self.pushLayout(.{
                .dir = .vertical,
                .bounds = .{
                    .x = outer_rect.x + self.theme.padding,
                    .y = outer_rect.y + self.theme.row_height + self.theme.padding,
                    .w = w - self.theme.padding * 2,
                    .h = 100000,
                },
                .cursor_x = outer_rect.x + self.theme.padding,
                .cursor_y = outer_rect.y + self.theme.row_height + self.theme.padding,
                .max_cross = 0,
            });
        }

        pub fn endPanel(self: *Self) void {
            if (self.popLayout()) |inner| {
                // total height consumed by panel content
                const content_h = inner.cursor_y - inner.bounds.y + self.theme.padding;
                const panel_h = self.theme.row_height + self.theme.padding + content_h;

                // draw panel background behind content
                const bg_rect = Rect{
                    .x = inner.bounds.x - self.theme.padding,
                    .y = inner.bounds.y - self.theme.row_height - self.theme.padding,
                    .w = inner.bounds.w + self.theme.padding * 2,
                    .h = panel_h,
                };

                self.backend.popState();
                // re-draw background first, then we need to re-render...
                // Since immediate mode draws in order, panel bg was already behind.
                // We adjust the parent layout cursor to account for actual panel height.
                if (self.layout_depth > 0) {
                    const parent = self.currentLayout();
                    // the allocRect for beginPanel gave h=0, so fix cursor
                    // cursor_y was advanced by 0 + item_spacing, we need panel_h total
                    _ = bg_rect;
                    parent.cursor_y = parent.cursor_y - self.theme.item_spacing + panel_h + self.theme.item_spacing;
                }
            }
        }

        pub fn beginHorizontal(self: *Self) void {
            const lay = self.currentLayout();
            self.pushLayout(.{
                .dir = .horizontal,
                .bounds = .{
                    .x = lay.cursor_x,
                    .y = lay.cursor_y,
                    .w = self.availableWidth(),
                    .h = 100000,
                },
                .cursor_x = lay.cursor_x,
                .cursor_y = lay.cursor_y,
                .max_cross = 0,
            });
        }

        pub fn endHorizontal(self: *Self) void {
            if (self.popLayout()) |inner| {
                if (self.layout_depth > 0) {
                    const parent = self.currentLayout();
                    const h = if (inner.max_cross > 0) inner.max_cross else self.theme.row_height;
                    parent.cursor_y += h + self.theme.item_spacing;
                }
            }
        }

        // -- Float formatting (no allocator) --

        fn formatFloat(buf: []u8, val: f32) []const u8 {
            if (val != val) {
                const nan = "NaN";
                if (buf.len >= nan.len) {
                    @memcpy(buf[0..nan.len], nan);
                    return buf[0..nan.len];
                }
                return "?";
            }
            const negative = val < 0;
            const v: f32 = if (negative) -val else val;

            // two decimal places
            var scaled: u32 = @intFromFloat(v * 100 + 0.5);
            var pos: usize = buf.len;

            // fractional part (2 digits)
            const d1: u8 = @intCast(scaled % 10);
            scaled /= 10;
            const d0: u8 = @intCast(scaled % 10);
            scaled /= 10;

            if (pos > 0) {
                pos -= 1;
                buf[pos] = '0' + d1;
            }
            if (pos > 0) {
                pos -= 1;
                buf[pos] = '0' + d0;
            }
            if (pos > 0) {
                pos -= 1;
                buf[pos] = '.';
            }

            // integer part
            if (scaled == 0) {
                if (pos > 0) {
                    pos -= 1;
                    buf[pos] = '0';
                }
            } else {
                while (scaled > 0 and pos > 0) {
                    pos -= 1;
                    buf[pos] = '0' + @as(u8, @intCast(scaled % 10));
                    scaled /= 10;
                }
            }

            if (negative and pos > 0) {
                pos -= 1;
                buf[pos] = '-';
            }

            return buf[pos..];
        }
    };
}

pub const CanvasUi = Ui(Canvas2DBackend);

test "hashId deterministic" {
    const std = @import("std");
    const TestUi = Ui(Canvas2DBackend);
    const a = TestUi.hashId("hello");
    const b = TestUi.hashId("hello");
    const c = TestUi.hashId("world");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}

test "displayLabel strips ## suffix" {
    const std = @import("std");
    const TestUi = Ui(Canvas2DBackend);
    try std.testing.expectEqualStrings("Speed", TestUi.displayLabel("Speed##slider1"));
    try std.testing.expectEqualStrings("Label", TestUi.displayLabel("Label"));
}

test "formatFloat basic" {
    const std = @import("std");
    const TestUi = Ui(Canvas2DBackend);
    var buf: [32]u8 = undefined;
    const result = TestUi.formatFloat(&buf, 1.5);
    try std.testing.expectEqualStrings("1.50", result);
}

test "formatFloat negative" {
    const std = @import("std");
    const TestUi = Ui(Canvas2DBackend);
    var buf: [32]u8 = undefined;
    const result = TestUi.formatFloat(&buf, -3.14);
    try std.testing.expectEqualStrings("-3.14", result);
}

test "formatFloat zero" {
    const std = @import("std");
    const TestUi = Ui(Canvas2DBackend);
    var buf: [32]u8 = undefined;
    const result = TestUi.formatFloat(&buf, 0.0);
    try std.testing.expectEqualStrings("0.00", result);
}
