const bind = @import("../bind/bind.zig");

extern "env" fn zunk_canvas_get_2d(sel_ptr: [*]const u8, sel_len: u32) i32;
extern "env" fn zunk_canvas_get_webgpu(sel_ptr: [*]const u8, sel_len: u32) i32;
extern "env" fn zunk_canvas_set_size(handle: i32, w: u32, h: u32) void;
extern "env" fn zunk_c2d_clear_rect(ctx: i32, x: f32, y: f32, w: f32, h: f32) void;
extern "env" fn zunk_c2d_fill_rect(ctx: i32, x: f32, y: f32, w: f32, h: f32) void;
extern "env" fn zunk_c2d_stroke_rect(ctx: i32, x: f32, y: f32, w: f32, h: f32) void;
extern "env" fn zunk_c2d_fill_style_rgba(ctx: i32, r: u32, g: u32, b: u32, a: u32) void;
extern "env" fn zunk_c2d_stroke_style_rgba(ctx: i32, r: u32, g: u32, b: u32, a: u32) void;
extern "env" fn zunk_c2d_line_width(ctx: i32, width: f32) void;
extern "env" fn zunk_c2d_begin_path(ctx: i32) void;
extern "env" fn zunk_c2d_close_path(ctx: i32) void;
extern "env" fn zunk_c2d_move_to(ctx: i32, x: f32, y: f32) void;
extern "env" fn zunk_c2d_line_to(ctx: i32, x: f32, y: f32) void;
extern "env" fn zunk_c2d_arc(ctx: i32, x: f32, y: f32, radius: f32, start: f32, end: f32) void;
extern "env" fn zunk_c2d_fill(ctx: i32) void;
extern "env" fn zunk_c2d_stroke(ctx: i32) void;
extern "env" fn zunk_c2d_fill_text(ctx: i32, txt_ptr: [*]const u8, txt_len: u32, x: f32, y: f32) void;
extern "env" fn zunk_c2d_set_font(ctx: i32, font_ptr: [*]const u8, font_len: u32) void;
extern "env" fn zunk_c2d_save(ctx: i32) void;
extern "env" fn zunk_c2d_restore(ctx: i32) void;
extern "env" fn zunk_c2d_translate(ctx: i32, x: f32, y: f32) void;
extern "env" fn zunk_c2d_rotate(ctx: i32, angle: f32) void;
extern "env" fn zunk_c2d_scale(ctx: i32, x: f32, y: f32) void;
extern "env" fn zunk_c2d_set_global_alpha(ctx: i32, alpha: f32) void;
extern "env" fn zunk_c2d_measure_text(ctx: i32, ptr: [*]const u8, len: u32) f32;
extern "env" fn zunk_c2d_clip(ctx: i32) void;
extern "env" fn zunk_c2d_set_text_baseline(ctx: i32, ptr: [*]const u8, len: u32) void;

pub const Ctx2D = bind.Handle;

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
};

pub fn getContext2D(selector: []const u8) Ctx2D {
    return bind.Handle.fromInt(zunk_canvas_get_2d(selector.ptr, @intCast(selector.len)));
}

pub fn getWebGPUSurface(selector: []const u8) bind.Handle {
    return bind.Handle.fromInt(zunk_canvas_get_webgpu(selector.ptr, @intCast(selector.len)));
}

pub fn setSize(handle: bind.Handle, w: u32, h: u32) void {
    zunk_canvas_set_size(handle.toInt(), w, h);
}

pub fn clearRect(ctx: Ctx2D, x: f32, y: f32, w: f32, h: f32) void {
    zunk_c2d_clear_rect(ctx.toInt(), x, y, w, h);
}

pub fn fillRect(ctx: Ctx2D, x: f32, y: f32, w: f32, h: f32) void {
    zunk_c2d_fill_rect(ctx.toInt(), x, y, w, h);
}

pub fn strokeRect(ctx: Ctx2D, x: f32, y: f32, w: f32, h: f32) void {
    zunk_c2d_stroke_rect(ctx.toInt(), x, y, w, h);
}

pub fn setFillColor(ctx: Ctx2D, color: Color) void {
    zunk_c2d_fill_style_rgba(ctx.toInt(), color.r, color.g, color.b, color.a);
}

pub fn setStrokeColor(ctx: Ctx2D, color: Color) void {
    zunk_c2d_stroke_style_rgba(ctx.toInt(), color.r, color.g, color.b, color.a);
}

pub fn setLineWidth(ctx: Ctx2D, width: f32) void {
    zunk_c2d_line_width(ctx.toInt(), width);
}

pub fn beginPath(ctx: Ctx2D) void {
    zunk_c2d_begin_path(ctx.toInt());
}

pub fn closePath(ctx: Ctx2D) void {
    zunk_c2d_close_path(ctx.toInt());
}

pub fn moveTo(ctx: Ctx2D, x: f32, y: f32) void {
    zunk_c2d_move_to(ctx.toInt(), x, y);
}

pub fn lineTo(ctx: Ctx2D, x: f32, y: f32) void {
    zunk_c2d_line_to(ctx.toInt(), x, y);
}

pub fn arc(ctx: Ctx2D, x: f32, y: f32, radius: f32, start_angle: f32, end_angle: f32) void {
    zunk_c2d_arc(ctx.toInt(), x, y, radius, start_angle, end_angle);
}

pub fn fill(ctx: Ctx2D) void {
    zunk_c2d_fill(ctx.toInt());
}

pub fn stroke(ctx: Ctx2D) void {
    zunk_c2d_stroke(ctx.toInt());
}

pub fn fillText(ctx: Ctx2D, text: []const u8, x: f32, y: f32) void {
    zunk_c2d_fill_text(ctx.toInt(), text.ptr, @intCast(text.len), x, y);
}

pub fn setFont(ctx: Ctx2D, font: []const u8) void {
    zunk_c2d_set_font(ctx.toInt(), font.ptr, @intCast(font.len));
}

pub fn save(ctx: Ctx2D) void {
    zunk_c2d_save(ctx.toInt());
}

pub fn restore(ctx: Ctx2D) void {
    zunk_c2d_restore(ctx.toInt());
}

pub fn translate(ctx: Ctx2D, x: f32, y: f32) void {
    zunk_c2d_translate(ctx.toInt(), x, y);
}

pub fn rotate(ctx: Ctx2D, angle: f32) void {
    zunk_c2d_rotate(ctx.toInt(), angle);
}

pub fn scale(ctx: Ctx2D, x: f32, y: f32) void {
    zunk_c2d_scale(ctx.toInt(), x, y);
}

pub fn setGlobalAlpha(ctx: Ctx2D, alpha: f32) void {
    zunk_c2d_set_global_alpha(ctx.toInt(), alpha);
}

pub fn measureText(ctx: Ctx2D, text: []const u8) f32 {
    return zunk_c2d_measure_text(ctx.toInt(), text.ptr, @intCast(text.len));
}

pub fn clip(ctx: Ctx2D) void {
    zunk_c2d_clip(ctx.toInt());
}

pub fn setTextBaseline(ctx: Ctx2D, baseline: []const u8) void {
    zunk_c2d_set_text_baseline(ctx.toInt(), baseline.ptr, @intCast(baseline.len));
}
