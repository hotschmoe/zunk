const canvas = @import("canvas.zig");

pub const Color = canvas.Color;

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }

    pub fn shrink(self: Rect, amount: f32) Rect {
        return .{
            .x = self.x + amount,
            .y = self.y + amount,
            .w = self.w - amount * 2,
            .h = self.h - amount * 2,
        };
    }
};

pub fn validateBackend(comptime B: type) void {
    const required = .{
        .{ "drawFilledRect", fn (Rect, Color) void },
        .{ "drawStrokedRect", fn (Rect, Color, f32) void },
        .{ "drawText", fn ([]const u8, f32, f32, Color) void },
        .{ "measureText", fn ([]const u8) f32 },
        .{ "setClipRect", fn (Rect) void },
        .{ "clearClipRect", fn () void },
        .{ "pushState", fn () void },
        .{ "popState", fn () void },
        .{ "setFont", fn ([]const u8) void },
    };
    inline for (required) |entry| {
        if (!@hasDecl(B, entry[0])) {
            @compileError("Render backend missing required method: " ++ entry[0]);
        }
    }
}

pub const Canvas2DBackend = struct {
    ctx: canvas.Ctx2D,

    pub fn init(ctx: canvas.Ctx2D) Canvas2DBackend {
        return .{ .ctx = ctx };
    }

    pub fn drawFilledRect(self: Canvas2DBackend, rect: Rect, color: Color) void {
        canvas.setFillColor(self.ctx, color);
        canvas.fillRect(self.ctx, rect.x, rect.y, rect.w, rect.h);
    }

    pub fn drawStrokedRect(self: Canvas2DBackend, rect: Rect, color: Color, line_width: f32) void {
        canvas.setStrokeColor(self.ctx, color);
        canvas.setLineWidth(self.ctx, line_width);
        canvas.strokeRect(self.ctx, rect.x, rect.y, rect.w, rect.h);
    }

    pub fn drawText(self: Canvas2DBackend, text: []const u8, x: f32, y: f32, color: Color) void {
        canvas.setFillColor(self.ctx, color);
        canvas.fillText(self.ctx, text, x, y);
    }

    pub fn measureText(self: Canvas2DBackend, text: []const u8) f32 {
        return canvas.measureText(self.ctx, text);
    }

    pub fn setClipRect(self: Canvas2DBackend, rect: Rect) void {
        canvas.beginPath(self.ctx);
        canvas.moveTo(self.ctx, rect.x, rect.y);
        canvas.lineTo(self.ctx, rect.x + rect.w, rect.y);
        canvas.lineTo(self.ctx, rect.x + rect.w, rect.y + rect.h);
        canvas.lineTo(self.ctx, rect.x, rect.y + rect.h);
        canvas.closePath(self.ctx);
        canvas.clip(self.ctx);
    }

    pub fn clearClipRect(_: Canvas2DBackend) void {
        // clip clearing is handled via save/restore
    }

    pub fn pushState(self: Canvas2DBackend) void {
        canvas.save(self.ctx);
    }

    pub fn popState(self: Canvas2DBackend) void {
        canvas.restore(self.ctx);
    }

    pub fn setFont(self: Canvas2DBackend, font: []const u8) void {
        canvas.setFont(self.ctx, font);
        canvas.setTextBaseline(self.ctx, "top");
    }

    comptime {
        validateBackend(Canvas2DBackend);
    }
};

test "Rect.contains" {
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    const std = @import("std");
    try std.testing.expect(r.contains(50, 40));
    try std.testing.expect(!r.contains(5, 40));
    try std.testing.expect(!r.contains(50, 5));
    try std.testing.expect(!r.contains(111, 40));
}

test "Rect.shrink" {
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    const s = r.shrink(5);
    const std = @import("std");
    try std.testing.expectApproxEqAbs(@as(f32, 15), s.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 25), s.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 90), s.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), s.h, 0.001);
}
