/// zunk/web/input -- Keyboard, mouse, touch, and gamepad input for Zig WASM.
///
/// Input works through a polling model: JS captures events and writes them
/// into shared state that Zig reads each frame. This avoids the complexity
/// of callback registration for most use cases.
///
/// For event-driven input, use the callback variants.
///
/// USAGE:
///   const input = @import("zunk").web.input;
///
///   // Polling (in your frame loop):
///   if (input.isKeyDown(.space)) player.jump();
///   const mouse = input.getMouse();
///   if (mouse.buttons.left) shoot(mouse.x, mouse.y);
///
///   // Event-driven:
///   input.onKeyDown(myKeyHandler);
///
const bind = @import("../bind/bind.zig");

// ============================================================================
// Low-level extern imports
// ============================================================================

// JS writes input state into a shared memory region each frame.
// These externs let us tell JS where that region is.
extern "env" fn zunk_input_init(state_ptr: [*]u8, state_len: u32) void;
extern "env" fn zunk_input_poll() void;
extern "env" fn zunk_input_set_key_callback(callback_id: u32) void;
extern "env" fn zunk_input_set_mouse_callback(callback_id: u32) void;
extern "env" fn zunk_input_set_touch_callback(callback_id: u32) void;
extern "env" fn zunk_input_lock_pointer(canvas_handle: i32) void;
extern "env" fn zunk_input_unlock_pointer() void;

// ============================================================================
// Shared input state (memory-mapped from JS)
// ============================================================================

/// Packed input state written by JS every frame.
/// This struct layout MUST match what the generated JS writes.
pub const InputState = extern struct {
    // Keyboard: 256 bits = 32 bytes, one bit per key code
    keys_down: [32]u8 align(1),
    keys_pressed: [32]u8 align(1), // pressed THIS frame (edge-triggered)
    keys_released: [32]u8 align(1),

    // Mouse
    mouse_x: f32 align(1),
    mouse_y: f32 align(1),
    mouse_dx: f32 align(1), // delta since last frame
    mouse_dy: f32 align(1),
    mouse_wheel: f32 align(1),
    mouse_buttons: u8 align(1), // bit 0=left, 1=right, 2=middle

    // Touch (up to 10 touch points)
    touch_count: u8 align(1),
    touch_x: [10]f32 align(1),
    touch_y: [10]f32 align(1),
    touch_id: [10]i32 align(1),

    // Gamepad (first connected gamepad)
    gamepad_connected: u8 align(1),
    gamepad_axes: [4]f32 align(1), // left stick x,y + right stick x,y
    gamepad_buttons: u32 align(1), // 32 buttons as bits

    // Viewport
    viewport_width: u32 align(1),
    viewport_height: u32 align(1),
    device_pixel_ratio: f32 align(1),
    has_focus: u8 align(1),
};

var input_state: InputState = std.mem.zeroes(InputState);

/// Initialize the input system. Call once at startup.
pub fn init() void {
    zunk_input_init(@ptrCast(&input_state), @sizeOf(InputState));
}

/// Poll for new input state. Call once per frame before reading input.
pub fn poll() void {
    zunk_input_poll();
}

// ============================================================================
// Key codes (matching JS KeyboardEvent.code numeric values)
// ============================================================================

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

// ============================================================================
// Keyboard queries
// ============================================================================

fn testBit(bitmap: [32]u8, code: u8) bool {
    const byte_idx = code >> 3;
    const bit_idx: u3 = @intCast(code & 7);
    return (bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

/// Is the key currently held down?
pub fn isKeyDown(key: Key) bool {
    return testBit(input_state.keys_down, @intFromEnum(key));
}

/// Was the key pressed this frame? (edge-triggered)
pub fn isKeyPressed(key: Key) bool {
    return testBit(input_state.keys_pressed, @intFromEnum(key));
}

/// Was the key released this frame?
pub fn isKeyReleased(key: Key) bool {
    return testBit(input_state.keys_released, @intFromEnum(key));
}

// ============================================================================
// Mouse queries
// ============================================================================

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

/// Lock the mouse pointer for FPS-style input
pub fn lockPointer(canvas: bind.Handle) void {
    zunk_input_lock_pointer(canvas.toInt());
}

pub fn unlockPointer() void {
    zunk_input_unlock_pointer();
}

// ============================================================================
// Touch queries
// ============================================================================

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

// ============================================================================
// Gamepad queries
// ============================================================================

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

// ============================================================================
// Viewport
// ============================================================================

pub fn getViewportSize() struct { w: u32, h: u32 } {
    return .{ .w = input_state.viewport_width, .h = input_state.viewport_height };
}

pub fn getDevicePixelRatio() f32 {
    return input_state.device_pixel_ratio;
}

pub fn hasFocus() bool {
    return input_state.has_focus != 0;
}

// ============================================================================
// Event-driven callbacks
// ============================================================================

pub fn onKeyDown(cb: bind.CallbackFn) void {
    zunk_input_set_key_callback(bind.registerCallback(cb));
}

pub fn onMouseMove(cb: bind.CallbackFn) void {
    zunk_input_set_mouse_callback(bind.registerCallback(cb));
}

pub fn onTouch(cb: bind.CallbackFn) void {
    zunk_input_set_touch_callback(bind.registerCallback(cb));
}

const std = @import("std");
