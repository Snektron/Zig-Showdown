const std = @import("std");
const network = @import("network");
const args = @import("args");
const zwl = @import("zwl");

const Game = @import("Game.zig");
const Input = @import("Input.zig");

const Resources = @import("Resources.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const global_allocator = &gpa.allocator;

pub const WindowPlatform = zwl.Platform(.{
    .platforms_enabled = .{
        .x11 = (std.builtin.os.tag == .linux),
        .wayland = false,
        .windows = (std.builtin.os.tag == .windows),
    },
    .single_window = false,
    .render_software = true,
    .x11_use_xcb = false,
});

/// This is a type that abstracts rendering tasks into
/// a platform-independent matter
pub const Renderer = @import("Renderer.zig");

pub fn main() anyerror!u8 {
    defer _ = gpa.deinit();

    try network.init();
    defer network.deinit();

    var cli = args.parseForCurrentProcess(CliArgs, global_allocator) catch |err| switch (err) {
        error.EncounteredUnknownArgument => {
            try printUsage(std.io.getStdErr().writer());
            return 1;
        },
        else => |e| return e,
    };
    defer cli.deinit();

    if (cli.options.help) {
        try printUsage(std.io.getStdOut().writer());
        return 0;
    }

    // Do not init windowing before necessary. We don't need a window
    // for printing a help string.

    var platform = try WindowPlatform.init(global_allocator, .{});
    defer platform.deinit();

    var window = try platform.createWindow(.{
        .title = "Zig SHOWDOWN",
        .width = 1280,
        .height = 720,
        .resizeable = false,
        .track_damage = false,
        .visible = true,
        .decorations = true,
        .track_mouse = true,
        .track_keyboard = true,
    });
    defer window.deinit();

    var renderer = try Renderer.init(global_allocator, window);
    defer renderer.deinit();

    var resources = Resources.init(global_allocator, &renderer);
    defer resources.deinit();

    // TODO: This is a ugly hack in the design and should be resolved
    renderer.resources = &resources;

    var input = Input.init();

    var game = try Game.init(global_allocator, &resources);
    defer game.deinit();

    var update_timer = try std.time.Timer.start();
    var render_timer = try std.time.Timer.start();

    const stretch_factor = 1.0 / cli.options.@"time-stretch";

    main_loop: while (game.running) {
        const event = try platform.waitForEvent();

        switch (event) {
            .WindowResized => |win| {
                const size = win.getSize();
                std.log.debug("*notices size {}x{}* OwO what's this", .{ size[0], size[1] });
            },

            // someone closed the window, just stop the game:
            .WindowDestroyed, .ApplicationTerminated => break :main_loop,

            .WindowVBlank => {
                // Lockstep updates with renderer for now
                {
                    const update_delta = @intToFloat(f32, update_timer.lap()) / std.time.ns_per_s;
                    try game.update(input, stretch_factor * update_delta);
                }

                input.resetEvents();

                // After updating, render the game
                {
                    try renderer.beginFrame();
                    const render_delta = @intToFloat(f32, render_timer.lap()) / std.time.ns_per_s;
                    try game.render(&renderer, stretch_factor * render_delta);
                    try renderer.endFrame();
                }
            },

            .WindowDamaged => {}, // ignore this

            .KeyUp, .KeyDown => |ev| {
                // TODO: This is a horrible hack and requires
                // actual key codes from ZWL. Good enough to debug though
                const button: ?Input.Button = switch (ev.scancode) {
                    25, 111 => .up,
                    39, 116 => .down,
                    38, 113 => .left,
                    40, 114 => .right,
                    65 => .jump,
                    36 => .accept,
                    else => blk: {
                        std.log.scoped(.input).info("unknown scancode: {}", .{ev.scancode});
                        break :blk null;
                    },
                };

                if (button) |btn| {
                    input.updateButton(btn, event == .KeyDown);
                }

                if (event == .KeyDown)
                    input.any_button_was_pressed = true;
                if (event == .KeyUp)
                    input.any_button_was_released = false;
            },

            .MouseButtonDown, .MouseButtonUp => |ev| {
                switch (ev.button) {
                    .left => input.updateButton(.left_mouse, event == .MouseButtonDown),
                    else => {},
                }
            },

            .MouseMotion => |ev| {
                input.mouse_x = ev.x;
                input.mouse_y = ev.y;
            },
        }
    }

    return 0;
}

const CliArgs = struct {
    // In release mode, run the game in fullscreen by default,
    // otherwise use windowed mode
    fullscreen: bool = if (std.builtin.mode != .Debug)
        true
    else
        false,

    port: u16 = @import("build_options").default_port,

    help: bool = false,

    @"time-stretch": f32 = 1.0,

    pub const shorthands = .{
        .f = "fullscreen",
        .h = "help",
    };
};

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: showdown
        \\Starts Zig SHOWDOWN.
        \\
        \\  -h, --help               display this help and exit
        \\      --time-stretch=FAC   Stretches the game speed by FAC. FAC="2.0" means the game
        \\                           will run with half the speed.
        \\  -p, --port=PORT          Changes the port used for the game server to PORT.
        \\  -f, --fullscreen=FULL    Will run the game in fullscreen mode when FULL = true.
        \\
    );
}

test "" {
    _ = @import("resource_pool.zig");
    _ = @import("resources/Model.zig");
}
