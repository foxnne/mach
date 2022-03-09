//! A GPUAdapter which identifies an implementation of WebGPU on the system.
//!
//! An adapter is both an instance of compute/rendering functionality on the platform, and an
//! instance of the WebGPU implementation on top of that functionality.
//!
//! Adapters do not uniquely represent underlying implementations: calling `requestAdapter()`
//! multiple times returns a different adapter object each time.
//!
//! An adapter object may become invalid at any time. This happens inside "lose the device" and
//! "mark adapters stale". An invalid adapter is unable to vend new devices.
//!
//! Note: This mechanism ensures that various adapter-creation scenarios look similar to
//! applications, so they can easily be robust to more scenarios with less testing: first
//! initialization, reinitialization due to an unplugged adapter, reinitialization due to a test
//! GPUDevice.destroy() call, etc. It also ensures applications use the latest system state to make
//! decisions about which adapter to use.
//!
//! https://gpuweb.github.io/gpuweb/#adapters
//! https://gpuweb.github.io/gpuweb/#gpuadapter
const std = @import("std");

const Feature = @import("enums.zig").Feature;
const Limits = @import("Limits.zig");
const Device = @import("Device.zig");

const Adapter = @This();

/// The features which can be used to create devices on this adapter.
features: []Feature,

/// The best limits which can be used to create devices on this adapter.
///
/// Each adapter limit will be the same or better than its default value in supported limits.
limits: Limits,

/// If set to true indicates that the adapter is a fallback adapter.
///
/// An adapter may be considered a fallback adapter if it has significant performance caveats in
/// exchange for some combination of wider compatibility, more predictable behavior, or improved
/// privacy. It is not guaranteed that a fallback adapter is available on every system.
///
/// Always false on native implementations of WebGPU (TODO: why is this not queryable in Dawn?)
fallback: bool,

// TODO: docs
properties: Properties,

/// The type erased pointer to the Adapter implementation
/// Equal to c.WGPUAdapter for NativeInstance.
ptr: *anyopaque,
vtable: *const VTable,

// The @frameSize(func) of the implementations requestDevice async function
request_device_frame_size: usize,

pub const VTable = struct {
    // TODO: is this method actually useful over requestDevice? Doesn't appear to be available in
    // web either:
    // WGPU_EXPORT WGPUDevice wgpuAdapterCreateDevice(WGPUAdapter adapter, WGPUDeviceDescriptor const * descriptor);
    reference: fn (ptr: *anyopaque) void,
    release: fn (ptr: *anyopaque) void,
    requestDevice: fn requestDevice(ptr: *anyopaque, descriptor: *const Device.Descriptor) callconv(.Async) RequestDeviceResponse,
};

pub inline fn reference(adapter: Adapter) void {
    adapter.vtable.reference(adapter.ptr);
}

pub inline fn release(adapter: Adapter) void {
    adapter.vtable.release(adapter.ptr);
}

/// Tests of the given feature can be used to create devices on this adapter.
pub fn hasFeature(adapter: Adapter, feature: Feature) bool {
    for (adapter.features) |f| {
        if (f == feature) return true;
    }
    return false;
}

// TODO: docs
pub const Properties = struct {
    vendor_id: u32,
    device_id: u32,
    name: []const u8,
    driver_description: []const u8,
    adapter_type: Type,
    backend_type: BackendType,
};

// TODO: docs
pub const Type = enum(u32) {
    discrete_gpu,
    integrated_gpu,
    cpu,
    unknown,
};

// TODO: docs
pub fn typeName(t: Type) []const u8 {
    return switch (t) {
        .discrete_gpu => "Discrete GPU",
        .integrated_gpu => "Integrated GPU",
        .cpu => "CPU",
        .unknown => "Unknown",
    };
}

// TODO: docs
pub const BackendType = enum(u32) {
    nul,
    webgpu,
    d3d11,
    d3d12,
    metal,
    vulkan,
    opengl,
    opengles,
};

// TODO: docs
pub fn backendTypeName(t: BackendType) []const u8 {
    return switch (t) {
        .nul => "Null",
        .webgpu => "WebGPU",
        .d3d11 => "D3D11",
        .d3d12 => "D3D12",
        .metal => "Metal",
        .vulkan => "Vulkan",
        .opengl => "OpenGL",
        .opengles => "OpenGLES",
    };
}

pub const RequestDeviceErrorCode = error{
    Error,
    Unknown,
};

// TODO: docs
pub const RequestDeviceError = struct {
    message: []const u8,
    code: RequestDeviceErrorCode,
};

pub const RequestDeviceResponseTag = enum {
    device,
    err,
};

pub const RequestDeviceResponse = union(RequestDeviceResponseTag) {
    // TODO: docs
    device: Device,
    err: RequestDeviceError,
};

// TODO: docs
pub fn requestDevice(adapter: Adapter, descriptor: *const Device.Descriptor) callconv(.Async) RequestDeviceResponse {
    var frame_buffer = std.heap.page_allocator.allocAdvanced(
        u8,
        16,
        adapter.request_device_frame_size,
        std.mem.Allocator.Exact.at_least,
    ) catch {
        return .{ .err = .{
            .message = "Out of memory",
            .code = RequestDeviceErrorCode.Error,
        } };
    };
    defer std.heap.page_allocator.free(frame_buffer);

    var result: RequestDeviceResponse = undefined;
    const f = @asyncCall(frame_buffer, &result, adapter.vtable.requestDevice, .{ adapter.ptr, descriptor });
    resume f;
    return result;
}

test "syntax" {
    _ = VTable;
    _ = hasFeature;
    _ = Properties;
    _ = Type;
    _ = BackendType;
    _ = RequestDeviceErrorCode;
    _ = RequestDeviceError;
    _ = RequestDeviceResponse;
    _ = requestDevice;
}
