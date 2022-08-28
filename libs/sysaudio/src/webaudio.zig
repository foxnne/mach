const std = @import("std");
const Mode = @import("main.zig").Mode;
const DeviceDescriptor = @import("main.zig").DeviceDescriptor;
const js = @import("sysjs");

const Audio = @This();

pub const DataCallback = if (@import("builtin").zig_backend == .stage1)
    fn (device: *Device, user_data: ?*anyopaque, buffer: []u8) void
else
    *const fn (device: *Device, user_data: ?*anyopaque, buffer: []u8) void;

pub const Device = struct {
    context: js.Object,

    pub fn deinit(device: Device) void {
        device.context.deinit();
    }

    pub fn setCallback(device: Device, callback: DataCallback, user_data: ?*anyopaque) void {
        device.context.set("device", js.createNumber(@intToFloat(f64, @ptrToInt(&device))));
        device.context.set("callback", js.createNumber(@intToFloat(f64, @ptrToInt(callback))));
        if (user_data) |ud|
            device.context.set("user_data", js.createNumber(@intToFloat(f64, @ptrToInt(ud))));
    }

    pub fn pause(device: Device) void {
        _ = device.context.call("suspend", &.{});
    }

    pub fn start(device: Device) void {
        _ = device.context.call("resume", &.{});
    }
};

pub const DeviceIterator = struct {
    ctx: *Audio,
    mode: Mode,

    pub fn next(_: DeviceIterator) IteratorError!?DeviceDescriptor {
        return null;
    }
};

pub const IteratorError = error{};

pub const Error = error{
    AudioUnsupported,
};

context_constructor: js.Function,

pub fn init() Error!Audio {
    const context = js.global().get("AudioContext");
    if (context.is(.undef))
        return error.AudioUnsupported;

    return Audio{ .context_constructor = context.view(.func) };
}

pub fn deinit(audio: Audio) void {
    audio.context_constructor.deinit();
}

pub fn waitEvents(_: Audio) void {}

const default_channel_count = 2;
const default_sample_rate = 48000;
const default_buffer_size = 1024; // 21.33ms

pub fn requestDevice(audio: Audio, config: DeviceDescriptor) Error!Device {
    // NOTE: WebAudio only supports F32 audio format, so config.format is unused
    const mode = config.mode orelse .output;
    const channels = config.channels orelse default_channel_count;
    const sample_rate = config.sample_rate orelse default_sample_rate;

    const context_options = js.createMap();
    defer context_options.deinit();
    context_options.set("sampleRate", js.createNumber(@intToFloat(f64, sample_rate)));

    const context = audio.context_constructor.construct(&.{context_options.toValue()});
    _ = context.call("suspend", &.{});

    const input_channels = if (mode == .input) js.createNumber(@intToFloat(f64, channels)) else js.createUndefined();
    const output_channels = if (mode == .output) js.createNumber(@intToFloat(f64, channels)) else js.createUndefined();

    const node = context.call("createScriptProcessor", &.{ js.createNumber(default_buffer_size), input_channels, output_channels }).view(.object);
    defer node.deinit();

    context.set("node", node.toValue());

    {
        // TODO(sysaudio): this capture leaks for now, we need a better way to pass captures via sysjs
        // that passes by value I think.
        const captures = std.heap.page_allocator.alloc(js.Value, 1) catch unreachable;
        captures[0] = context.toValue();
        const audio_process_event = js.createFunction(audioProcessEvent, captures);

        // TODO(sysaudio): this leaks, we need a good place to clean this up.
        // defer audio_process_event.deinit();
        node.set("onaudioprocess", audio_process_event.toValue());
    }

    {
        const destination = context.get("destination").view(.object);
        defer destination.deinit();
        _ = node.call("connect", &.{destination.toValue()});
    }

    return Device{ .context = context };
}

fn audioProcessEvent(args: js.Object, _: usize, captures: []js.Value) js.Value {
    const device_context = captures[0].view(.object);

    const audio_event = args.getIndex(0).view(.object);
    defer audio_event.deinit();
    const output_buffer = audio_event.get("outputBuffer").view(.object);
    defer output_buffer.deinit();

    const buffer_length = default_buffer_size * @sizeOf(f32);
    var buffer: [buffer_length]u8 = undefined;

    const callback = device_context.get("callback");
    if (!callback.is(.undef)) {
        // Do not deinit, we are not making a new device, just creating a view to the current one.
        var dev = Device{ .context = device_context };
        const cb = @intToPtr(DataCallback, @floatToInt(usize, callback.view(.num)));
        const user_data = device_context.get("user_data");
        const ud = if (user_data.is(.undef)) null else @intToPtr(*anyopaque, @floatToInt(usize, user_data.view(.num)));

        var channel: usize = 0;
        while (channel < @floatToInt(usize, output_buffer.get("numberOfChannels").view(.num))) : (channel += 1) {
            const source = js.constructType("Uint8Array", &.{js.createNumber(buffer_length)});
            defer source.deinit();

            cb(&dev, ud, buffer[0..]);
            source.copyBytes(buffer[0..]);

            const float_source = js.constructType("Float32Array", &.{
                source.get("buffer"),
                source.get("byteOffset"),
                js.createNumber(source.get("byteLength").view(.num) / 4),
            });
            defer float_source.deinit();

            js.global().set("source", source.toValue());
            js.global().set("float_source", float_source.toValue());
            js.global().set("output_buffer", output_buffer.toValue());

            // TODO: investigate if using copyToChannel would be better?
            //_ = output_buffer.call("copyToChannel", &.{ float_source.toValue(), js.createNumber(@intToFloat(f64, channel)) });
            const output_data = output_buffer.call("getChannelData", &.{js.createNumber(@intToFloat(f64, channel))}).view(.object);
            defer output_data.deinit();
            _ = output_data.call("set", &.{float_source.toValue()});
        }
    }

    return js.createUndefined();
}

pub fn outputDeviceIterator(audio: Audio) DeviceIterator {
    return .{ .audio = audio, .mode = .output };
}

pub fn inputDeviceIterator(audio: Audio) DeviceIterator {
    return .{ .audio = audio, .mode = .input };
}