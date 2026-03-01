const bind = @import("../bind/bind.zig");

pub const Element = bind.Handle;
pub const Panel = bind.Handle;

extern "env" fn zunk_ui_create_panel(ptr: [*]const u8, len: u32) i32;
extern "env" fn zunk_ui_show_panel(id: i32) void;
extern "env" fn zunk_ui_hide_panel(id: i32) void;
extern "env" fn zunk_ui_toggle_panel(id: i32) void;
extern "env" fn zunk_ui_add_slider(panel: i32, ptr: [*]const u8, len: u32, min: f32, max: f32, value: f32, step: f32) i32;
extern "env" fn zunk_ui_add_checkbox(panel: i32, ptr: [*]const u8, len: u32, checked: i32) i32;
extern "env" fn zunk_ui_add_button(panel: i32, ptr: [*]const u8, len: u32) i32;
extern "env" fn zunk_ui_add_separator(panel: i32) i32;
extern "env" fn zunk_ui_get_float(id: i32) f32;
extern "env" fn zunk_ui_get_bool(id: i32) i32;
extern "env" fn zunk_ui_is_clicked(id: i32) i32;
extern "env" fn zunk_ui_set_label(id: i32, ptr: [*]const u8, len: u32) void;
extern "env" fn zunk_ui_set_status(ptr: [*]const u8, len: u32) void;
extern "env" fn zunk_ui_request_fullscreen() void;

pub fn createPanel(title: []const u8) Panel {
    return bind.Handle.fromInt(zunk_ui_create_panel(title.ptr, @intCast(title.len)));
}

pub fn showPanel(p: Panel) void {
    zunk_ui_show_panel(p.toInt());
}

pub fn hidePanel(p: Panel) void {
    zunk_ui_hide_panel(p.toInt());
}

pub fn togglePanel(p: Panel) void {
    zunk_ui_toggle_panel(p.toInt());
}

pub fn addSlider(p: Panel, label: []const u8, min: f32, max: f32, value: f32, step: f32) Element {
    return bind.Handle.fromInt(zunk_ui_add_slider(p.toInt(), label.ptr, @intCast(label.len), min, max, value, step));
}

pub fn addCheckbox(p: Panel, label: []const u8, checked: bool) Element {
    return bind.Handle.fromInt(zunk_ui_add_checkbox(p.toInt(), label.ptr, @intCast(label.len), @intFromBool(checked)));
}

pub fn addButton(p: Panel, label: []const u8) Element {
    return bind.Handle.fromInt(zunk_ui_add_button(p.toInt(), label.ptr, @intCast(label.len)));
}

pub fn addSeparator(p: Panel) Element {
    return bind.Handle.fromInt(zunk_ui_add_separator(p.toInt()));
}

pub fn getFloat(el: Element) f32 {
    return zunk_ui_get_float(el.toInt());
}

pub fn getBool(el: Element) bool {
    return zunk_ui_get_bool(el.toInt()) != 0;
}

pub fn isClicked(el: Element) bool {
    return zunk_ui_is_clicked(el.toInt()) != 0;
}

pub fn setLabel(el: Element, text: []const u8) void {
    zunk_ui_set_label(el.toInt(), text.ptr, @intCast(text.len));
}

pub fn setStatus(text: []const u8) void {
    zunk_ui_set_status(text.ptr, @intCast(text.len));
}

pub fn requestFullscreen() void {
    zunk_ui_request_fullscreen();
}
