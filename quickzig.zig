const std = @import("std");
const testing = std.testing;
const print = std.debug.print;
const Random = std.rand.Random;
const Allocator = std.mem.Allocator;

pub const PropertyTestError = error{
    PropertyViolated,
    GenerationFailed,
    OutOfMemory,
};

pub const TestConfig = struct {
    iterations: u32 = 100,
    max_shrink_attempts: u32 = 100,
    seed: ?u64 = null,
    verbose: bool = false,
};

pub fn Generator(comptime T: type) type {
    return struct {
        const Self = @This();

        generateFn: *const fn (allocator: Allocator, rng: Random) anyerror!T,
        shrinkFn: ?*const fn (allocator: Allocator, value: T) anyerror!?T = null,

        pub fn generate(self: Self, allocator: Allocator, rng: Random) !T {
            return self.generateFn(allocator, rng);
        }

        pub fn shrink(self: Self, allocator: Allocator, value: T) !?T {
            if (self.shrinkFn) |shrink_fn| {
                return shrink_fn(allocator, value);
            }
            return null;
        }
    };
}

// Built-in generators with macro-like helpers
pub const Generators = struct {
    // Generic generator creator - reduces boilerplate
    fn makeGenerator(
        comptime T: type,
        comptime generateFn: *const fn (allocator: Allocator, rng: Random) anyerror!T,
        comptime shrinkFn: ?*const fn (allocator: Allocator, value: T) anyerror!?T,
    ) Generator(T) {
        return Generator(T){
            .generateFn = generateFn,
            .shrinkFn = shrinkFn,
        };
    }

    pub fn int(comptime T: type, comptime min: T, comptime max: T) Generator(T) {
        const GenerateFn = struct {
            fn generate(allocator: Allocator, rng: Random) anyerror!T {
                _ = allocator;
                return rng.intRangeAtMost(T, min, max);
            }
        };
        const ShrinkFn = struct {
            fn shrink(allocator: Allocator, value: T) anyerror!?T {
                _ = allocator;
                if (value == 0) return null;
                return @divFloor(value, 2);
            }
        };
        return makeGenerator(T, GenerateFn.generate, ShrinkFn.shrink);
    }

    pub fn boolean() Generator(bool) {
        const GenerateFn = struct {
            fn generate(allocator: Allocator, rng: Random) anyerror!bool {
                _ = allocator;
                return rng.boolean();
            }
        };
        return makeGenerator(bool, GenerateFn.generate, null);
    }

    // Range generators with default shrinking
    pub fn u32Range(comptime min: u32, comptime max: u32) Generator(u32) {
        return int(u32, min, max);
    }

    pub fn i32Range(comptime min: i32, comptime max: i32) Generator(i32) {
        return int(i32, min, max);
    }

    // Convenient aliases - fixed: these need to be function calls, not variables
    pub fn smallInt() Generator(i32) {
        return int(i32, -100, 100);
    }

    pub fn largeInt() Generator(i32) {
        return int(i32, -10000, 10000);
    }

    pub fn byte() Generator(u8) {
        return int(u8, 0, 255);
    }

    pub fn ascii() Generator(u8) {
        return int(u8, 32, 126);
    }

    pub fn @"bool"() Generator(bool) {
        return boolean();
    }

    pub fn slice(comptime T: type, comptime item_gen: Generator(T), comptime min_len: usize, comptime max_len: usize) Generator([]T) {
        const GenerateFn = struct {
            fn generate(allocator: Allocator, rng: Random) anyerror![]T {
                const len = rng.intRangeAtMost(usize, min_len, max_len);
                var result = try allocator.alloc(T, len);

                for (result) |*item| {
                    item.* = try item_gen.generate(allocator, rng);
                }

                return result;
            }
        };
        const ShrinkFn = struct {
            fn shrink(allocator: Allocator, value: []T) anyerror!?[]T {
                if (value.len <= min_len) return null;

                const new_len = @max(min_len, value.len / 2);
                var result = try allocator.alloc(T, new_len);
                @memcpy(result, value[0..new_len]);

                return result;
            }
        };
        return makeGenerator([]T, GenerateFn.generate, ShrinkFn.shrink);
    }

    pub fn string(comptime min_len: usize, comptime max_len: usize) Generator([]u8) {
        const GenerateFn = struct {
            fn generate(allocator: Allocator, rng: Random) anyerror![]u8 {
                const len = rng.intRangeAtMost(usize, min_len, max_len);
                var result = try allocator.alloc(u8, len);

                for (result) |*char| {
                    char.* = rng.intRangeAtMost(u8, 32, 126); // Printable ASCII
                }

                return result;
            }
        };
        const ShrinkFn = struct {
            fn shrink(allocator: Allocator, value: []u8) anyerror!?[]u8 {
                if (value.len <= min_len) return null;

                const new_len = @max(min_len, value.len / 2);
                var result = try allocator.alloc(u8, new_len);
                @memcpy(result, value[0..new_len]);

                return result;
            }
        };
        return makeGenerator([]u8, GenerateFn.generate, ShrinkFn.shrink);
    }

    // Convenient collection generators
    pub fn smallIntList(comptime max_len: usize) Generator([]i32) {
        return slice(i32, smallInt(), 0, max_len);
    }

    pub fn shortString(comptime max_len: usize) Generator([]u8) {
        return string(0, max_len);
    }

    pub fn nonEmptyString(comptime max_len: usize) Generator([]u8) {
        return string(1, max_len);
    }
};

pub fn Property(comptime Args: type) type {
    return struct {
        const Self = @This();

        testFn: *const fn (args: Args) bool,

        pub fn init(test_fn: *const fn (args: Args) bool) Self {
            return Self{
                .testFn = test_fn,
            };
        }

        pub fn checkWith(self: Self, allocator: Allocator, config: TestConfig, generators: anytype) !void {
            const seed = config.seed orelse @as(u64, @intCast(std.time.timestamp()));
            var prng = std.rand.DefaultPrng.init(seed);
            const rng = prng.random();

            if (config.verbose) {
                print("Running property test with seed: {}\n", .{seed});
            }

            var iteration: u32 = 0;
            while (iteration < config.iterations) : (iteration += 1) {
                // Generate test data
                var args: Args = undefined;
                inline for (std.meta.fields(Args), 0..) |field, i| {
                    @field(args, field.name) = try generators[i].generate(allocator, rng);
                }

                // Run the test
                const test_passed = self.testFn(args);

                // Free generated data if needed
                inline for (std.meta.fields(Args), 0..) |field, i| {
                    _ = i;
                    if (field.type == []u8 or field.type == []i32) {
                        const value = @field(args, field.name);
                        allocator.free(value);
                    }
                }

                if (!test_passed) {
                    if (config.verbose) {
                        print("Property violated on iteration {}\n", .{iteration});
                    }

                    print("Property test failed!\n", .{});
                    return PropertyTestError.PropertyViolated;
                }
            }

            if (config.verbose) {
                print("Property test passed after {} iterations\n", .{config.iterations});
            }
        }

        pub fn check(self: Self, allocator: Allocator, generators: anytype) !void {
            return self.checkWith(allocator, .{}, generators);
        }
    };
}

// Super short generator aliases
pub const g = struct {
    pub fn i() Generator(i32) {
        return Generators.smallInt();
    }

    pub fn I() Generator(i32) {
        return Generators.largeInt();
    }

    pub fn b() Generator(bool) {
        return Generators.bool();
    }

    pub fn s(comptime max_len: usize) Generator([]u8) {
        return Generators.shortString(max_len);
    }

    pub fn S(comptime max_len: usize) Generator([]u8) {
        return Generators.nonEmptyString(max_len);
    }

    pub fn list(comptime max_len: usize) Generator([]i32) {
        return Generators.smallIntList(max_len);
    }

    pub fn range(comptime min: i32, comptime max: i32) Generator(i32) {
        return Generators.int(i32, min, max);
    }
};

// Helper function to extract argument type from function
fn extractArgsType(comptime func_type: type) type {
    const type_info = @typeInfo(func_type);
    if (type_info != .Fn) {
        @compileError("Expected function type");
    }
    if (type_info.Fn.params.len != 1) {
        @compileError("Function must have exactly one parameter");
    }
    return type_info.Fn.params[0].type.?;
}

// Simplified property creation helper
pub fn prop(comptime test_fn: anytype) PropertyBuilder(extractArgsType(@TypeOf(test_fn))) {
    const Args = extractArgsType(@TypeOf(test_fn));
    return PropertyBuilder(Args).init(test_fn);
}

pub fn PropertyBuilder(comptime Args: type) type {
    return struct {
        const Self = @This();

        property: Property(Args),

        pub fn init(test_fn: *const fn (args: Args) bool) Self {
            return Self{
                .property = Property(Args).init(test_fn),
            };
        }

        pub fn forAll(self: Self, generators: anytype) ForAllBuilder(Args, @TypeOf(generators)) {
            return ForAllBuilder(Args, @TypeOf(generators)){
                .property = self.property,
                .generators = generators,
            };
        }
    };
}

pub fn ForAllBuilder(comptime Args: type, comptime GeneratorsTuple: type) type {
    return struct {
        const Self = @This();

        property: Property(Args),
        generators: GeneratorsTuple,

        pub fn check(self: Self, allocator: Allocator) !void {
            return self.property.checkWith(allocator, .{}, self.generators);
        }

        pub fn checkWith(self: Self, allocator: Allocator, config: TestConfig) !void {
            return self.property.checkWith(allocator, config, self.generators);
        }
    };
}

// Example usage with simplified syntax
test "property-based testing with new syntax" {
    const allocator = testing.allocator;

    // Define argument types first
    const AddArgs = struct { a: i32, b: i32 };
    const StringArgs = struct { s: []u8 };

    // Test functions that use the same types
    const TestFunctions = struct {
        fn testCommutative(args: AddArgs) bool {
            return args.a + args.b == args.b + args.a;
        }

        fn testStringLength(args: StringArgs) bool {
            return args.s.len <= 10;
        }
    };

    const add_prop = Property(AddArgs).init(TestFunctions.testCommutative);
    try add_prop.checkWith(allocator, .{}, .{ Generators.smallInt(), Generators.smallInt() });

    // Test string length
    const string_prop = Property(StringArgs).init(TestFunctions.testStringLength);

    try string_prop.checkWith(allocator, .{}, .{Generators.shortString(10)});
}

// Alternative concise syntax
test "ultra-concise syntax" {
    const allocator = testing.allocator;

    // Define Args type first, then use it in the test function
    const Args = struct { a: i32 };

    // Define test functions in a struct using the same Args type
    const Tests = struct {
        fn addIdentity(args: Args) bool {
            return args.a + 0 == args.a;
        }
    };

    const identity_prop = Property(Args).init(Tests.addIdentity);

    try identity_prop.checkWith(allocator, .{}, .{Generators.largeInt()});
}

// Original examples for comparison
test "property-based testing example" {
    const allocator = testing.allocator;

    // Test that reverse of reverse is identity
    const ReverseArgs = struct { list: []i32 };

    const reverse_property = Property(ReverseArgs).init(struct {
        fn test_reverse(args: ReverseArgs) bool {
            var list_copy = std.heap.page_allocator.alloc(i32, args.list.len) catch return false;
            defer std.heap.page_allocator.free(list_copy);

            @memcpy(list_copy, args.list);
            std.mem.reverse(i32, list_copy);
            std.mem.reverse(i32, list_copy);

            return std.mem.eql(i32, args.list, list_copy);
        }
    }.test_reverse);

    try reverse_property.checkWith(
        allocator,
        TestConfig{ .iterations = 50, .verbose = false },
        .{Generators.smallIntList(10)},
    );
}

test "addition commutative property" {
    const allocator = testing.allocator;

    const AddArgs = struct { a: i32, b: i32 };

    const commutative_property = Property(AddArgs).init(struct {
        fn test_commutative(args: AddArgs) bool {
            return args.a + args.b == args.b + args.a;
        }
    }.test_commutative);

    try commutative_property.checkWith(
        allocator,
        TestConfig{ .iterations = 100 },
        .{ Generators.int(i32, -1000, 1000), Generators.int(i32, -1000, 1000) },
    );
}

test "string length property" {
    const allocator = testing.allocator;

    const StringArgs = struct { s: []u8 };

    const length_property = Property(StringArgs).init(struct {
        fn test_length(args: StringArgs) bool {
            return args.s.len >= 5 and args.s.len <= 20;
        }
    }.test_length);

    try length_property.checkWith(
        allocator,
        TestConfig{ .iterations = 30 },
        .{Generators.string(5, 20)},
    );
}

// Example main function for standalone compilation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("Running Property-Based Tests...\n\n");

    // Test 1: Addition commutative property
    print("Testing addition commutativity...\n");
    const AddArgs = struct { a: i32, b: i32 };

    const commutative_property = Property(AddArgs).init(struct {
        fn test_commutative(args: AddArgs) bool {
            return args.a + args.b == args.b + args.a;
        }
    }.test_commutative);

    commutative_property.checkWith(
        allocator,
        TestConfig{ .iterations = 100, .verbose = true },
        .{ Generators.int(i32, -1000, 1000), Generators.int(i32, -1000, 1000) },
    ) catch |err| {
        print("Test failed: {}\n", .{err});
        return;
    };

    // Test 2: List reverse property
    print("\nTesting list reverse property...\n");
    const ReverseArgs = struct { list: []i32 };

    const reverse_property = Property(ReverseArgs).init(struct {
        fn test_reverse(args: ReverseArgs) bool {
            var list_copy = std.heap.page_allocator.alloc(i32, args.list.len) catch return false;
            defer std.heap.page_allocator.free(list_copy);

            @memcpy(list_copy, args.list);
            std.mem.reverse(i32, list_copy);
            std.mem.reverse(i32, list_copy);

            return std.mem.eql(i32, args.list, list_copy);
        }
    }.test_reverse);

    reverse_property.checkWith(
        allocator,
        TestConfig{ .iterations = 50, .verbose = true },
        .{Generators.slice(i32, Generators.int(i32, -100, 100), 0, 10)},
    ) catch |err| {
        print("Test failed: {}\n", .{err});
        return;
    };

    print("\nAll property tests passed!\n");
}
