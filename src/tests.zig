const std = @import("std");
const parser = @import("parser.zig");
const asm_generator = @import("asm_generator.zig");

pub const TestResult = struct {
    passed: usize = 0,
    failed: usize = 0,
};

pub const TestCase = struct {
    name: []const u8,
    input: []const u8,
    should_succeed: bool,
    expected_error: ?[]const u8 = null,
};

// ============================================================
// SUCCESSFUL COMPILATION TESTS
// ============================================================

pub const successful_tests = [_]TestCase{
    TestCase{
        .name = "01_int_arithmetic: Simple integer operations",
        .input = "x = 5\ny = 3\nz = x + y",
        .should_succeed = true,
    },

    TestCase{
        .name = "02_float_arithmetic: Float operations",
        .input = "x = 3.14\ny = 2.5\nz = x + y",
        .should_succeed = true,
    },

    TestCase{
        .name = "03_mixed_int_float: Mixed int and float",
        .input = "x = 5\ny = 3.14\nz = x + y",
        .should_succeed = true,
    },

    TestCase{
        .name = "04_comparisons: Comparison operators",
        .input = "x = 5\ny = x > 3\nz = x == 5\nw = x != 10",
        .should_succeed = true,
    },

    TestCase{
        .name = "05_booleans: Boolean values and operations",
        .input = "a = true\nb = false\nc = a and b\nd = a or b",
        .should_succeed = true,
    },

    TestCase{
        .name = "06_if_else: If-else statement",
        .input = "x = 5\nif (x > 3) {\n    y = 10\n} else {\n    y = 20\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "07_if_no_else: If without else",
        .input = "x = 5\nif (x > 10) {\n    y = 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "08_while_sum: Simple while loop",
        .input = "s = 0\ni = 0\nwhile (i < 5) {\n    s` = s + i\n    i` = i + 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "09_fibonacci: Fibonacci with prime variables",
        .input = "a = 1\nb = 0\ni = 0\nwhile (i < 10) {\n    a` = a + b\n    b` = a\n    i` = i + 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "10_precedence: Operator precedence",
        .input = "x = 2 + 3 * 4\ny = (2 + 3) * 4\nz = 2 ^ 3",
        .should_succeed = true,
    },

    TestCase{
        .name = "11_nested_while: Nested while loops",
        .input = "i = 0\nwhile (i < 3) {\n    j = 0\n    while (j < 2) {\n        j` = j + 1\n    }\n    i` = i + 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "12_geometric_series: Multiple primed vars with nested loop",
        .input = "a = 1\nb = 2\ni = 0\nwhile (i < 4) {\n    j = 0\n    while (j < 2) {\n        j` = j + 1\n    }\n    a` = a * b\n    i` = i + 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "13_float_while: Float iteration",
        .input = "x = 1.5\ni = 0\nwhile (i < 3) {\n    x` = x * 2.0\n    i` = i + 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "14_combined_logic: Complex boolean logic",
        .input = "x = 5\ny = 10\nz = (x > 3) and (y < 20)\nw = (x == 5) or (y == 15)",
        .should_succeed = true,
    },

    TestCase{
        .name = "Logical NOT operator",
        .input = "x = true\ny = !x",
        .should_succeed = true,
    },

    TestCase{
        .name = "Power operator",
        .input = "x = 2\ny = x ^ 3",
        .should_succeed = true,
    },

    TestCase{
        .name = "Right associative power",
        .input = "x = 2 ^ 3 ^ 2",
        .should_succeed = true,
    },

    TestCase{
        .name = "Complex nested expression",
        .input = "x = (2 + 3) * (4 - 1) ^ 2",
        .should_succeed = true,
    },

    TestCase{
        .name = "Nested if statements",
        .input = "x = 5\ny = 10\nif (x > 0) {\n    if (y > 5) {\n        z = 1\n    }\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "Multiple variable assignments",
        .input = "a = 1\nb = 2\nc = 3\nd = 4\ne = a + b + c + d",
        .should_succeed = true,
    },
};

// ============================================================
// SYNTAX ERROR TESTS
// ============================================================

pub const syntax_error_tests = [_]TestCase{
    TestCase{
        .name = "Missing closing parenthesis",
        .input = "x = (5 + 3",
        .should_succeed = false,
        .expected_error = "UnmatchedParenthesis",
    },

    TestCase{
        .name = "Missing closing brace in while",
        .input = "while (x < 10) {\n    x` = x + 1",
        .should_succeed = false,
    },

    TestCase{
        .name = "Missing equals in assignment",
        .input = "x 42",
        .should_succeed = false,
    },

    TestCase{
        .name = "Invalid operator character",
        .input = "x = 5 $ 3",
        .should_succeed = false,
    },

    TestCase{
        .name = "Missing while condition",
        .input = "while () {\n    x = 1\n}",
        .should_succeed = false,
    },

    TestCase{
        .name = "Missing if condition",
        .input = "if {\n    x = 1\n}",
        .should_succeed = false,
        .expected_error = "Expected",
    },

    TestCase{
        .name = "Invalid operator usage - trailing operator",
        .input = "x = 5 +",
        .should_succeed = false,
    },

    TestCase{
        .name = "Unmatched closing paren",
        .input = "x = 5 + 3)",
        .should_succeed = false,
    },

    TestCase{
        .name = "Missing while body",
        .input = "while (x < 10)",
        .should_succeed = false,
    },

    TestCase{
        .name = "Missing if body",
        .input = "if (x > 5)",
        .should_succeed = false,
    },
};

// ============================================================
// SEMANTIC ERROR TESTS
// ============================================================

pub const semantic_error_tests = [_]TestCase{
    TestCase{
        .name = "Prime operator outside loop",
        .input = "x = 5\nx` = 10",
        .should_succeed = false,
    },

    TestCase{
        .name = "Undefined variable reference",
        .input = "x = undefined_var + 5",
        .should_succeed = false,
        .expected_error = "UndefinedVariable",
    },

    TestCase{
        .name = "Prime of undefined variable",
        .input = "while (i < 5) {\n    x` = 10\n}",
        .should_succeed = false,
        .expected_error = "UndefinedVariable",
    },

    TestCase{
        .name = "Double variable assignment (outside loop)",
        .input = "x = 5\nx = 10",
        .should_succeed = false,
        .expected_error = "VariableAlreadyDefined",
    },

    TestCase{
        .name = "Undefined variable in while condition",
        .input = "while (undefined_var < 10) {\n    x = 1\n}",
        .should_succeed = false,
        .expected_error = "UndefinedVariable",
    },

    TestCase{
        .name = "Undefined variable in if condition",
        .input = "if (undefined_var > 5) {\n    x = 1\n}",
        .should_succeed = false,
        .expected_error = "UndefinedVariable",
    },

    TestCase{
        .name = "Prime in if condition (outside loop body)",
        .input = "i = 0\nwhile (i < 5) {\n    if (i` > 0) {\n        x = 1\n    }\n}",
        .should_succeed = false,
    },
};

// ============================================================
// PRIME VARIABLE ENFORCEMENT TESTS
// ============================================================

pub const prime_enforcement_tests = [_]TestCase{
    TestCase{
        .name = "Double prime assignment in same loop",
        .input = "x = 1\ni = 0\nwhile (i < 5) {\n    x` = x + 1\n    x` = x * 2\n    i` = i + 1\n}",
        .should_succeed = false,
        .expected_error = "VariableAlreadyPrimed",
    },

    TestCase{
        .name = "Prime in both if/else branches (conflict with outer)",
        .input = "x = 1\ni = 0\nwhile (i < 5) {\n    if (i < 3) {\n        x` = x + 1\n    } else {\n        x` = x + 2\n    }\n    i` = i + 1\n}",
        .should_succeed = false,
        .expected_error = "VariableAlreadyPrimed",
    },

    TestCase{
        .name = "Variable primed in nested loop and outer loop",
        .input = "x = 1\ni = 0\nwhile (i < 2) {\n    j = 0\n    while (j < 2) {\n        x` = x + 1\n        j` = j + 1\n    }\n    x` = x * 2\n    i` = i + 1\n}",
        .should_succeed = false,
        .expected_error = "VariablePrimedInNestedLoop",
    },

    TestCase{
        .name = "Variable primed in outer then attempted in nested",
        .input = "x = 1\ni = 0\nwhile (i < 2) {\n    x` = x * 2\n    j = 0\n    while (j < 2) {\n        x` = x + 1\n        j` = j + 1\n    }\n    i` = i + 1\n}",
        .should_succeed = false,
        .expected_error = "VariablePrimedInNestedLoop",
    },

    TestCase{
        .name = "Three-level nesting with conflict",
        .input = "x = 1\ni = 0\nwhile (i < 2) {\n    j = 0\n    while (j < 2) {\n        k = 0\n        while (k < 2) {\n            x` = x + 1\n            k` = k + 1\n        }\n        x` = x * 2\n        j` = j + 1\n    }\n    i` = i + 1\n}",
        .should_succeed = false,
        .expected_error = "VariablePrimedInNestedLoop",
    },
};

// ============================================================
// NESTED LOOP PRIME VARIABLE TESTS
// ============================================================

pub const nested_loop_tests = [_]TestCase{
    TestCase{
        .name = "Simple nested loop with inner prime only",
        .input = "i = 0\nwhile (i < 3) {\n    j = 0\n    while (j < 2) {\n        j` = j + 1\n    }\n    i` = i + 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "Nested loop where outer loop primes variable modified in inner loop",
        .input = "a = 1\nb = 0\ni = 0\nwhile (i < 3) {\n    j = 0\n    while (j < 2) {\n        b` = b + 1\n        j` = j + 1\n    }\n    a` = a + b\n    i` = i + 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "Three-level nested loops",
        .input = "i = 0\nwhile (i < 2) {\n    j = 0\n    while (j < 2) {\n        k = 0\n        while (k < 2) {\n            k` = k + 1\n        }\n        j` = j + 1\n    }\n    i` = i + 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "Prime same variable in both outer and inner loop (different assignments)",
        .input = "x = 1\ni = 0\nwhile (i < 2) {\n    j = 0\n    while (j < 2) {\n        x` = x + 1\n        j` = j + 1\n    }\n    x` = x * 2\n    i` = i + 1\n}",
        .should_succeed = false,
        .expected_error = "VariablePrimedInNestedLoop",
    },

    TestCase{
        .name = "Nested loop where inner loop has no primes",
        .input = "i = 0\nwhile (i < 3) {\n    j = 0\n    while (j < 2) {\n        x = j + 1\n    }\n    i` = i + 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "Multiple primed variables in outer loop with nested inner loop",
        .input = "a = 1\nb = 2\nc = 3\ni = 0\nwhile (i < 2) {\n    j = 0\n    while (j < 2) {\n        c` = c + 1\n        j` = j + 1\n    }\n    a` = a + b\n    b` = a\n    i` = i + 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "Primes collected at loop level, not nested context",
        .input = "x = 1\ni = 0\nwhile (i < 2) {\n    if (x > 0) {\n        x` = x + 1\n    }\n    i` = i + 1\n}",
        .should_succeed = true,
    },

    TestCase{
        .name = "Prime in nested if inside nested loop",
        .input = "x = 1\ni = 0\nwhile (i < 2) {\n    j = 0\n    while (j < 2) {\n        if (j > 0) {\n            x` = x + 1\n        }\n        j` = j + 1\n    }\n    i` = i + 1\n}",
        .should_succeed = true,
    },
};

// ============================================================
// MULTIPLE PRIME ASSIGNMENT TESTS
// ============================================================

pub const multiple_prime_tests = [_]TestCase{
    TestCase{
        .name = "Multiple primes to same variable (in different branches)",
        .input = "x = 1\ni = 0\nwhile (i < 2) {\n    if (i < 1) {\n        x` = x + 1\n    } else {\n        x` = x + 2\n    }\n    i` = i + 1\n}",
        .should_succeed = false,
        .expected_error = "VariableAlreadyPrimed",
    },

    TestCase{
        .name = "Multiple consecutive prime assignments to same variable",
        .input = "x = 1\ni = 0\nwhile (i < 2) {\n    x` = x + 1\n    x` = x * 2\n    i` = i + 1\n}",
        .should_succeed = false,
        .expected_error = "VariableAlreadyPrimed",
    },

    TestCase{
        .name = "Prime variable used in outer and inner loop (outer doesn`t prime, inner does)",
        .input = "x = 1\ni = 0\nwhile (i < 2) {\n    j = 0\n    while (j < 2) {\n        x` = x + 1\n        j` = j + 1\n    }\n    i` = i + 1\n}",
        .should_succeed = true,
    },
};

// ============================================================
// TEST RUNNER
// ============================================================

pub fn runTests(allocator: std.mem.Allocator, output_writer: anytype) !TestResult {
    var results = TestResult{};

    try output_writer.print("\n════════════════════════════════════════════════════════════\n", .{});
    try output_writer.print("RUNNING COMPREHENSIVE TEST SUITE\n", .{});
    try output_writer.print("════════════════════════════════════════════════════════════\n\n", .{});

    // Run successful tests
    try output_writer.print("────────────────────────────────────────────────────────────\n", .{});
    try output_writer.print("SUCCESSFUL COMPILATION TESTS ({d} tests)\n", .{successful_tests.len});
    try output_writer.print("────────────────────────────────────────────────────────────\n", .{});
    const success_count = try runTestGroup(
        &successful_tests,
        allocator,
        output_writer,
    );
    results.passed += success_count;
    results.failed += successful_tests.len - success_count;

    // Run syntax error tests
    try output_writer.print("\n────────────────────────────────────────────────────────────\n", .{});
    try output_writer.print("SYNTAX ERROR TESTS ({d} tests)\n", .{syntax_error_tests.len});
    try output_writer.print("────────────────────────────────────────────────────────────\n", .{});
    const syntax_count = try runTestGroup(
        &syntax_error_tests,
        allocator,
        output_writer,
    );
    results.passed += syntax_count;
    results.failed += syntax_error_tests.len - syntax_count;

    // Run semantic error tests
    try output_writer.print("\n────────────────────────────────────────────────────────────\n", .{});
    try output_writer.print("SEMANTIC ERROR TESTS ({d} tests)\n", .{semantic_error_tests.len});
    try output_writer.print("────────────────────────────────────────────────────────────\n", .{});
    const semantic_count = try runTestGroup(
        &semantic_error_tests,
        allocator,
        output_writer,
    );
    results.passed += semantic_count;
    results.failed += semantic_error_tests.len - semantic_count;

    // Run nested loop tests
    try output_writer.print("\n────────────────────────────────────────────────────────────\n", .{});
    try output_writer.print("NESTED LOOP PRIME VARIABLE TESTS ({d} tests)\n", .{nested_loop_tests.len});
    try output_writer.print("────────────────────────────────────────────────────────────\n", .{});
    const nested_count = try runTestGroup(
        &nested_loop_tests,
        allocator,
        output_writer,
    );
    results.passed += nested_count;
    results.failed += nested_loop_tests.len - nested_count;

    // Run multiple prime assignment tests
    try output_writer.print("\n────────────────────────────────────────────────────────────\n", .{});
    try output_writer.print("MULTIPLE PRIME ASSIGNMENT TESTS ({d} tests)\n", .{multiple_prime_tests.len});
    try output_writer.print("────────────────────────────────────────────────────────────\n", .{});
    const multiple_count = try runTestGroup(
        &multiple_prime_tests,
        allocator,
        output_writer,
    );
    results.passed += multiple_count;
    results.failed += multiple_prime_tests.len - multiple_count;

    // Run prime enforcement tests
    try output_writer.print("\n────────────────────────────────────────────────────────────\n", .{});
    try output_writer.print("PRIME ENFORCEMENT TESTS ({d} tests)\n", .{prime_enforcement_tests.len});
    try output_writer.print("────────────────────────────────────────────────────────────\n", .{});
    const enforcement_count = try runTestGroup(
        &prime_enforcement_tests,
        allocator,
        output_writer,
    );
    results.passed += enforcement_count;
    results.failed += prime_enforcement_tests.len - enforcement_count;

    // Final summary
    try output_writer.print("\n════════════════════════════════════════════════════════════\n", .{});
    try output_writer.print("TEST SUMMARY\n", .{});
    try output_writer.print("════════════════════════════════════════════════════════════\n", .{});
    try output_writer.print("Passed: {d}\n", .{results.passed});
    try output_writer.print("Failed: {d}\n", .{results.failed});
    try output_writer.print("Total:  {d}\n", .{results.passed + results.failed});
    const pass_rate = @as(f32, @floatFromInt(results.passed)) / @as(f32, @floatFromInt(results.passed + results.failed)) * 100.0;
    try output_writer.print("Pass Rate: {d:.1}%\n\n", .{pass_rate});

    return results;
}

fn runTestGroup(tests: anytype, allocator: std.mem.Allocator, output_writer: anytype) !usize {
    var passed: usize = 0;

    for (tests) |tc| {
        if (try runSingleTest(tc, allocator)) {
            try output_writer.print("✓ PASS: {s}\n", .{tc.name});
            passed += 1;
        } else {
            try output_writer.print("✗ FAIL: {s}\n", .{tc.name});
        }
    }

    return passed;
}

fn runSingleTest(tc: TestCase, allocator: std.mem.Allocator) !bool {
    // Parse
    var parse_result = parser.programParse(tc.input, allocator) catch |err| {
        // Error during parsing
        if (!tc.should_succeed) {
            // Expected failure
            if (tc.expected_error) |expected| {
                const err_name = @errorName(err);
                return std.mem.containsAtLeast(u8, err_name, 1, expected);
            }
            return true;
        }
        return false;
    };

    // If we get here, parsing succeeded
    defer parse_result.deinit();

    if (!tc.should_succeed) {
        // Expected a failure, but parse/codegen succeeded.
        return false;
    }

    // Run code generation for successful tests.
    const null_file = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch {
        return false;
    };
    defer null_file.close();

    var out_buf: [4096]u8 = undefined;
    var out_writer = null_file.writer(&out_buf);
    const writer = &out_writer.interface;

    var gen = asm_generator.AsmGenerator.init(
        writer,
        allocator,
        tc.input,
        null,
    ) catch {
        return false;
    };
    defer gen.deinit();

    gen.generate(parse_result.root) catch {
        return false;
    };

    writer.flush() catch {
        return false;
    };

    return true;
}
