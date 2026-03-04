const std = @import("std");

const CallFrame = struct {
    n: u64,
    stage: u32,
    left_result: u64,
};

pub fn fib(n: u64) u64 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // In modern Zig, Unmanaged is the preferred way to handle collections
    var call_stack = std.ArrayListUnmanaged(CallFrame){};
    defer call_stack.deinit(allocator);

    var result_stack = std.ArrayListUnmanaged(u64){};
    defer result_stack.deinit(allocator);

    call_stack.append(allocator, .{ .n = n, .stage = 0, .left_result = 0 }) catch unreachable;

    while (call_stack.items.len > 0) {
        // Use .? to unwrap the optional returned by pop()
        const frame = call_stack.pop().?;

        if (frame.n <= 1) {
            result_stack.append(allocator, frame.n) catch unreachable;
        } else if (frame.stage == 0) {
            // Push Stage 1 (save state) and then the next recursion (n-1)
            call_stack.append(allocator, .{ .n = frame.n, .stage = 1, .left_result = 0 }) catch unreachable;
            call_stack.append(allocator, .{ .n = frame.n - 1, .stage = 0, .left_result = 0 }) catch unreachable;
        } else if (frame.stage == 1) {
            // n-1 completed, pop its result and push n-2
            const left_res = result_stack.pop().?;
            call_stack.append(allocator, .{ .n = frame.n, .stage = 2, .left_result = left_res }) catch unreachable;
            call_stack.append(allocator, .{ .n = frame.n - 2, .stage = 0, .left_result = 0 }) catch unreachable;
        } else {
            // n-2 completed, pop result and sum with left_result
            const right_res = result_stack.pop().?;
            result_stack.append(allocator, frame.left_result + right_res) catch unreachable;
        }
    }

    return result_stack.items[0];
}

pub fn main() void {
    const n = 10;
    const result = fib(n);
    std.debug.print("fib({d}) = {d}\n", .{ n, result });
}
