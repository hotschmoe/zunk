const std = @import("std");
const bind = @import("../bind/bind.zig");

extern "env" fn zunk_input_init(state_ptr: [*]u8, state_len: u32) void;
extern "env" fn zunk_input_poll() void;
extern "env" fn zunk_input_set_key_callback(callback_id: u32) void;
extern "env" fn zunk_input_set_mouse_callback(callback_id: u32) void;
extern "env" fn zunk_input_set_touch_callback(callback_id: u32) void;
extern "env" fn zunk_input_lock_pointer(canvas_handle: i32) void;
extern "env" fn zunk_input_unlock_pointer() void;

/// Layout must match the generated JS input flush routine.
pub const InputState = extern struct {
    keys_down: [32]u8 align(1),
    keys_pressed: [32]u8 align(1),
    keys_released: [32]u8 align(1),

    mouse_x: f32 align(1),
    mouse_y: f32 align(1),
    mouse_dx: f32 align(1),
    mouse_dy: f32 align(1),
    mouse_wheel: f32 align(1),
    mouse_buttons: u8 align(1),

    touch_count: u8 align(1),
    touch_x: [10]f32 align(1),
    touch_y: [10]f32 align(1),
    touch_id: [10]i32 align(1),

    gamepad_connected: u8 align(1),
    gamepad_axes: [4]f32 align(1),
    gamepad_buttons: u32 align(1),

    viewport_width: u32 align(1),
    viewport_height: u32 align(1),
    device_pixel_ratio: f32 align(1),
    has_focus: u8 align(1),
};

var input_state: InputState = std.mem.zeroes(InputState);

pub fn init() void {
    zunk_input_init(@ptrCast(&input_state), @sizeOf(InputState));
}

pub fn poll() void {
    zunk_input_poll();
}

pub const Key = enum(u8) {
    backspace = 8,
    tab = 9,
    enter = 13,
    shift = 16,
    ctrl = 17,
    alt = 18,
    escape = 27,
    space = 32,
    arrow_left = 37,
    arrow_up = 38,
    arrow_right = 39,
    arrow_down = 40,
    key_0 = 48,
    key_1 = 49,
    key_2 = 50,
    key_3 = 51,
    key_4 = 52,
    key_5 = 53,
    key_6 = 54,
    key_7 = 55,
    key_8 = 56,
    key_9 = 57,
    a = 65,
    b = 66,
    c = 67,
    d = 68,
    e = 69,
    f = 70,
    g = 71,
    h = 72,
    i = 73,
    j = 74,
    k = 75,
    l = 76,
    m = 77,
    n = 78,
    o = 79,
    p = 80,
    q = 81,
    r = 82,
    s = 83,
    t = 84,
    u = 85,
    v = 86,
    w = 87,
    x = 88,
    y = 89,
    z = 90,
    f1 = 112,
    f2 = 113,
    f3 = 114,
    f4 = 115,
    f5 = 116,
    f6 = 117,
    f7 = 118,
    f8 = 119,
    f9 = 120,
    f10 = 121,
    f11 = 122,
    f12 = 123,
    _,
};

fn testBit(bitmap: [32]u8, code: u8) bool {
    const byte_idx = code >> 3;
    const bit_idx: u3 = @intCast(code & 7);
    return (bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

pub fn isKeyDown(key: Key) bool {
    return testBit(input_state.keys_down, @intFromEnum(key));
}

pub fn isKeyPressed(key: Key) bool {
    return testBit(input_state.keys_pressed, @intFromEnum(key));
}

pub fn isKeyReleased(key: Key) bool {
    return testBit(input_state.keys_released, @intFromEnum(key));
}

pub const MouseButtons = struct {
    left: bool,
    right: bool,
    middle: bool,
};

pub const Mouse = struct {
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    wheel: f32,
    buttons: MouseButtons,
};

pub fn getMouse() Mouse {
    return .{
        .x = input_state.mouse_x,
        .y = input_state.mouse_y,
        .dx = input_state.mouse_dx,
        .dy = input_state.mouse_dy,
        .wheel = input_state.mouse_wheel,
        .buttons = .{
            .left = (input_state.mouse_buttons & 1) != 0,
            .right = (input_state.mouse_buttons & 2) != 0,
            .middle = (input_state.mouse_buttons & 4) != 0,
        },
    };
}

pub fn lockPointer(canvas: bind.Handle) void {
    zunk_input_lock_pointer(canvas.toInt());
}

pub fn unlockPointer() void {
    zunk_input_unlock_pointer();
}

pub const TouchPoint = struct {
    id: i32,
    x: f32,
    y: f32,
};

pub fn getTouchCount() u8 {
    return input_state.touch_count;
}

pub fn getTouch(index: u8) ?TouchPoint {
    if (index >= input_state.touch_count) return null;
    return .{
        .id = input_state.touch_id[index],
        .x = input_state.touch_x[index],
        .y = input_state.touch_y[index],
    };
}

pub const Gamepad = struct {
    connected: bool,
    left_stick_x: f32,
    left_stick_y: f32,
    right_stick_x: f32,
    right_stick_y: f32,
    buttons: u32,

    pub fn isButtonDown(self: Gamepad, button: u5) bool {
        return (self.buttons & (@as(u32, 1) << button)) != 0;
    }
};

pub fn getGamepad() Gamepad {
    return .{
        .connected = input_state.gamepad_connected != 0,
        .left_stick_x = input_state.gamepad_axes[0],
        .left_stick_y = input_state.gamepad_axes[1],
        .right_stick_x = input_state.gamepad_axes[2],
        .right_stick_y = input_state.gamepad_axes[3],
        .buttons = input_state.gamepad_buttons,
    };
}

pub fn getViewportSize() struct { w: u32, h: u32 } {
    return .{ .w = input_state.viewport_width, .h = input_state.viewport_height };
}

pub fn getDevicePixelRatio() f32 {
    return input_state.device_pixel_ratio;
}

pub fn hasFocus() bool {
    return input_state.has_focus != 0;
}

pub fn onKeyDown(cb: bind.CallbackFn) void {
    zunk_input_set_key_callback(bind.registerCallback(cb));
}

pub fn onMouseMove(cb: bind.CallbackFn) void {
    zunk_input_set_mouse_callback(bind.registerCallback(cb));
}

pub fn onTouch(cb: bind.CallbackFn) void {
    zunk_input_set_touch_callback(bind.registerCallback(cb));
}
