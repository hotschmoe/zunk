const std = @import("std");
const bind = @import("../bind/bind.zig");

extern "env" fn zunk_input_init(state_ptr: [*]u8, state_len: u32) void;
extern "env" fn zunk_input_poll() void;
extern "env" fn zunk_input_set_key_callback(callback_id: u32) void;
extern "env" fn zunk_input_set_mouse_callback(callback_id: u32) void;
extern "env" fn zunk_input_set_touch_callback(callback_id: u32) void;
extern "env" fn zunk_input_lock_pointer(canvas_handle: i32) void;
extern "env" fn zunk_input_unlock_pointer() void;

/// Layout must match the generated JS input flush routine (`emitInputSystem`
/// in `gen/js_gen.zig`).
///
/// Mouse wheel deltas are CSS pixels, positive = down / right (DOM
/// `WheelEvent` convention; line/page-mode wheels are scaled to pixels). A
/// trackpad pinch arrives as a wheel event with the Ctrl modifier set.
/// `modifiers` is the shift/ctrl/alt/meta state of the most recent input
/// event. `typed_chars` holds the UTF-8 encoding of typed text, whole code
/// points only; Ctrl/Cmd chords are keys, not text.
///
/// Coordinate space: all pointer/viewport fields (`mouse_x/y`, `mouse_dx/dy`,
/// `touch_x/y`, `viewport_width/height`) are in **CSS pixels**. This matches
/// the `w, h` passed to the optional `resize(w, h)` export. On HiDPI displays
/// the canvas backing store is sized to `w * device_pixel_ratio` by
/// `h * device_pixel_ratio` for crisp rendering; consumers who need that
/// device-pixel size (e.g. for a WebGPU viewport) should multiply by
/// `device_pixel_ratio` themselves.
pub const InputState = extern struct {
    keys_down: [32]u8 align(1),
    keys_pressed: [32]u8 align(1),
    keys_released: [32]u8 align(1),

    mouse_x: f32 align(1),
    mouse_y: f32 align(1),
    mouse_dx: f32 align(1),
    mouse_dy: f32 align(1),
    mouse_wheel: f32 align(1),
    mouse_wheel_x: f32 align(1),
    mouse_buttons: u8 align(1),
    mouse_buttons_pressed: u8 align(1),
    mouse_buttons_released: u8 align(1),
    modifiers: u8 align(1),

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

    typed_chars_len: u8 align(1),
    typed_chars: [64]u8 align(1),
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
    page_up = 33,
    page_down = 34,
    end = 35,
    home = 36,
    arrow_left = 37,
    arrow_up = 38,
    arrow_right = 39,
    arrow_down = 40,
    insert = 45,
    delete = 46,
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
    return testBit(input_state.keys_down, @backingInt(key));
}

pub fn isKeyPressed(key: Key) bool {
    return testBit(input_state.keys_pressed, @backingInt(key));
}

pub fn isKeyReleased(key: Key) bool {
    return testBit(input_state.keys_released, @backingInt(key));
}

pub const MouseButtons = struct {
    left: bool,
    right: bool,
    middle: bool,
};

pub const MouseButton = enum(u3) {
    left = 0,
    middle = 1,
    right = 2,
};

pub fn isMouseButtonPressed(btn: MouseButton) bool {
    return (input_state.mouse_buttons_pressed & (@as(u8, 1) << @backingInt(btn))) != 0;
}

pub fn isMouseButtonReleased(btn: MouseButton) bool {
    return (input_state.mouse_buttons_released & (@as(u8, 1) << @backingInt(btn))) != 0;
}

pub const Mouse = struct {
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    /// Vertical wheel pixels since the last poll (positive = down).
    wheel: f32,
    /// Horizontal wheel pixels since the last poll (positive = right).
    wheel_x: f32,
    buttons: MouseButtons,
};

/// Modifier keys held at the most recent input event.
pub const Modifiers = struct {
    shift: bool,
    ctrl: bool,
    alt: bool,
    /// Cmd on macOS / Win key elsewhere.
    meta: bool,
};

pub fn getModifiers() Modifiers {
    const m = input_state.modifiers;
    return .{
        .shift = (m & 1) != 0,
        .ctrl = (m & 2) != 0,
        .alt = (m & 4) != 0,
        .meta = (m & 8) != 0,
    };
}

pub fn getMouse() Mouse {
    return .{
        .x = input_state.mouse_x,
        .y = input_state.mouse_y,
        .dx = input_state.mouse_dx,
        .dy = input_state.mouse_dy,
        .wheel = input_state.mouse_wheel,
        .wheel_x = input_state.mouse_wheel_x,
        .buttons = .{
            .left = (input_state.mouse_buttons & 1) != 0,
            .middle = (input_state.mouse_buttons & 2) != 0,
            .right = (input_state.mouse_buttons & 4) != 0,
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

/// UTF-8 bytes typed since the last poll (whole code points; no control
/// codes, no Ctrl/Cmd chords).
pub fn getTypedChars() []const u8 {
    return input_state.typed_chars[0..input_state.typed_chars_len];
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

test "InputState layout matches the generated JS flush" {
    // keys (3 x 32) then mouse f32 x6, 4 bytes, touch, gamepad, viewport,
    // focus, typed chars — the offsets `emitInputSystem` writes.
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(InputState, "mouse_x"));
    try std.testing.expectEqual(@as(usize, 112), @offsetOf(InputState, "mouse_wheel"));
    try std.testing.expectEqual(@as(usize, 116), @offsetOf(InputState, "mouse_wheel_x"));
    try std.testing.expectEqual(@as(usize, 120), @offsetOf(InputState, "mouse_buttons"));
    try std.testing.expectEqual(@as(usize, 123), @offsetOf(InputState, "modifiers"));
    try std.testing.expectEqual(@as(usize, 124), @offsetOf(InputState, "touch_count"));
    try std.testing.expectEqual(@as(usize, 125 + 120), @offsetOf(InputState, "gamepad_connected"));
    try std.testing.expectEqual(@as(usize, 245 + 21), @offsetOf(InputState, "viewport_width"));
    try std.testing.expectEqual(@as(usize, 266 + 13), @offsetOf(InputState, "typed_chars_len"));
    try std.testing.expectEqual(@as(usize, 280), @offsetOf(InputState, "typed_chars"));
    try std.testing.expectEqual(@as(usize, 280 + 64), @sizeOf(InputState));
}

test "getModifiers decodes the modifier bits" {
    input_state.modifiers = 0b1010; // ctrl + meta
    defer input_state.modifiers = 0;
    const m = getModifiers();
    try std.testing.expect(!m.shift);
    try std.testing.expect(m.ctrl);
    try std.testing.expect(!m.alt);
    try std.testing.expect(m.meta);
}
