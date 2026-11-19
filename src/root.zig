const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// TODO: Could be configurable at comptime?
const FileId = u32;

/// A (possibly markdown) documentation comment in a file.
const Document = struct {
    /// A read-only view into the relevant file.
    bytes: []const u8,
    /// The ID of the file to edit.
    file_id: FileId,
    /// `[start_offset, end_offset)` byte range in backing file.
    start_offset: u64,
    /// `[start_offset, end_offset)` byte range in backing file.
    end_offset: u64,
};

/// A generic file storage interface. Allows for reading from/writing to files by ID.
///
/// Registering/adding files at runtime should be done by the implementation.
///
/// ```zig
/// pub fn register(data_or_reference: []const u8) !FileId
/// ```
///
/// Is the recommended function prototype to achieve this.
const FileStore = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        readAll: *const fn (ctx: *anyopaque, allocator: Allocator, id: FileId) anyerror![]const u8,
        writeAll: *const fn (ctx: *anyopaque, allocator: Allocator, id: FileId, data: []const u8) anyerror!void,
    };

    /// Reads all the contents of a file into a slice. If required, you should
    /// dupe the returned bytes as these may be freed/clobbered after edits to
    /// the same `id`.
    ///
    /// # Safety
    ///
    /// The `allocator` should match the one used by the implementation, if used.
    pub fn readAll(self: FileStore, allocator: Allocator, id: FileId) anyerror![]const u8 {
        return self.vtable.readAll(self.ctx, allocator, id);
    }

    /// The file at `FileId` must exist before calling this function.
    ///
    /// Will clobber the current contents of `id`. If an error is returned,
    /// the contents at `id` shall not be clobbered.
    ///
    /// # Notes
    ///
    /// `data` may be duped to ensure validity, but the management of this memory will
    /// be handled by the `FileStore` implementation.
    ///
    /// # Safety
    ///
    /// The `allocator` should match the one used by the implementation, if used.
    pub fn writeAll(self: FileStore, allocator: Allocator, id: FileId, data: []const u8) anyerror!void {
        return self.vtable.writeAll(self.ctx, allocator, id, data);
    }
};

pub const InMemoryStore = struct {
    const FileMap = std.AutoHashMap(FileId, []const u8);

    /// Simple mapping from `FileId` to a slice with the contents of said file.
    file_map: FileMap,
    /// The `FileStore` interface. The `allocator` should be the same one used
    /// for the implementation, if required.
    interface: FileStore,

    const impl = FileStore.VTable{
        .readAll = readAll,
        .writeAll = writeAll,
    };

    pub const InitError = error{DuplicateFileId} || Allocator.Error;
    pub const Error = error{InvalidFileId} || Allocator.Error;

    /// Takes a list of `(file_id, contents)` to store.
    ///
    /// Duplicate `file_id`'s will return a `DuplicateFileId` error.
    ///
    /// Each file slice is duped, hence the `allocator`.
    ///
    /// Allocation lifetimes are managed by this implementation, so long as
    /// you pass the __same__ `allocator` to `deinit` and other methods.
    pub fn init(
        files: []const struct { FileId, []const u8 },
        allocator: Allocator,
    ) InitError!*InMemoryStore {
        var file_map = FileMap.init(allocator);

        errdefer cleanupFileMap(&file_map, allocator);

        for (files) |insert| {
            const id, const f = insert;
            const duped = try allocator.dupe(u8, f);

            // Duplicate `id` should be an error.
            if (try file_map.fetchPut(id, duped)) |old| {
                allocator.free(old.value);

                return error.DuplicateFileId;
            }
        }

        const self = try allocator.create(InMemoryStore);
        self.* = .{
            .file_map = file_map,
            .interface = .{
                .ctx = self,
                .vtable = &impl,
            },
        };

        return self;
    }

    pub fn deinit(self: *InMemoryStore, allocator: Allocator) void {
        cleanupFileMap(&self.file_map, allocator);
        allocator.destroy(self);
    }

    /// Frees any previous dupes and deinit the map.
    fn cleanupFileMap(
        file_map: *FileMap,
        allocator: Allocator,
    ) void {
        var iter = file_map.valueIterator();
        while (iter.next()) |slice| allocator.free(slice.*);

        file_map.deinit();
    }

    fn getSelf(ctx: *anyopaque) *InMemoryStore {
        return @ptrCast(@alignCast(ctx));
    }

    pub fn readAll(ctx: *anyopaque, _: Allocator, id: FileId) Error![]const u8 {
        const self = getSelf(ctx);

        return self.file_map.get(id) orelse return error.InvalidFileId;
    }

    pub fn writeAll(ctx: *anyopaque, allocator: Allocator, id: FileId, data: []const u8) Error!void {
        const self = getSelf(ctx);

        const ptr = self.file_map.getPtr(id) orelse return error.InvalidFileId;
        const duped = try allocator.dupe(u8, data);

        allocator.free(ptr.*);
        ptr.* = duped;
    }

    /// Pairs of (file_id, contents).
    const test_files = &.{
        .{ 0, "# Lorem ipsum set amet dolor" },
        .{ 1, "This is a file too!" },
        .{
            2,
            \\"This one has newlines?", asked the test runner.
            \\"Why yes, of course", replied the test case
        },
    };

    test "init" {
        const allocator = std.testing.allocator;

        var in_mem_store = try InMemoryStore.init(test_files, allocator);
        defer in_mem_store.deinit(allocator);
    }

    test "empty init works" {
        const allocator = std.testing.allocator;

        var in_mem_store = try InMemoryStore.init(&.{}, allocator);
        defer in_mem_store.deinit(allocator);

        const store = in_mem_store.interface;

        // We expect any input ID should fail, let's try a few.
        try std.testing.expectError(
            error.InvalidFileId,
            store.readAll(allocator, 0),
        );

        try std.testing.expectError(
            error.InvalidFileId,
            store.readAll(allocator, 1234),
        );
    }

    test "init fails gracefully" {
        var allocator = std.heap.SafeAllocator.init(
            Allocator.failing,
            .{},
        );

        const in_mem_store = InMemoryStore.init(test_files, allocator.allocator());

        try std.testing.expectError(error.OutOfMemory, in_mem_store);
        try std.testing.expect(allocator.deinit() == 0);
    }

    test "init fails gracefully mid-init" {
        // Fail after some allocations.
        var allocator = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = 2 },
        );

        const in_mem_store = InMemoryStore.init(test_files, allocator.allocator());

        try std.testing.expectError(error.OutOfMemory, in_mem_store);
    }

    test "init does not accept duplicates" {
        const allocator = std.testing.allocator;

        // Same `id` twice should give us an error.
        const dupes = &.{
            .{ 0, "First" },
            .{ 1, "Second" },
            .{ 0, "First\nEDIT: tysm for all the likes guys!!!!!!11111" },
        };

        const store_or_error = InMemoryStore.init(dupes, allocator);
        try std.testing.expectError(error.DuplicateFileId, store_or_error);
    }

    test "readAll fails for non-existent file" {
        const allocator = std.testing.allocator;

        var in_mem_store = try InMemoryStore.init(test_files, allocator);
        defer in_mem_store.deinit(allocator);

        const store = in_mem_store.interface;

        const bytes_or_error = store.readAll(allocator, 456);

        try std.testing.expectError(error.InvalidFileId, bytes_or_error);
    }

    test "readAll" {
        const allocator = std.testing.allocator;

        var in_mem_store = try InMemoryStore.init(test_files, allocator);
        defer in_mem_store.deinit(allocator);

        const store = in_mem_store.interface;

        inline for (test_files) |case| {
            const id, const expected = case;

            try std.testing.expectEqualStrings(
                expected,
                try store.readAll(allocator, id),
            );
        }
    }

    test "writeAll fails for non-existent file" {
        const allocator = std.testing.allocator;

        var in_mem_store = try InMemoryStore.init(test_files, allocator);
        defer in_mem_store.deinit(allocator);

        const store = in_mem_store.interface;

        const void_or_error = store.writeAll(
            allocator,
            1234,
            "Hello, world!",
        );

        try std.testing.expectError(error.InvalidFileId, void_or_error);

        // The file should also not be created.
        try std.testing.expectError(
            error.InvalidFileId,
            store.readAll(allocator, 1234),
        );
    }

    test "writeAll clobbers file at `id` (w/o leaked memory)" {
        const initial_expected = test_files[0][1];
        const expected = test_files[1][1];

        const allocator = std.testing.allocator;

        var in_mem_store = try InMemoryStore.init(test_files, allocator);
        defer in_mem_store.deinit(allocator);

        const store = in_mem_store.interface;

        const initially_got = try store.readAll(allocator, 0);
        try std.testing.expectEqualStrings(initial_expected, initially_got);

        try store.writeAll(
            allocator,
            0,
            expected,
        );

        const got = try store.readAll(allocator, 0);
        try std.testing.expectEqualStrings(expected, got);
    }

    test "writeAll fails" {
        // Fail after some allocations.
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            // I found this empirically, why would I use my brain when typing
            // works just as well!
            .{ .fail_index = 5 },
        );
        const allocator = failing.allocator();

        var in_mem_store = try InMemoryStore.init(test_files, allocator);
        defer in_mem_store.deinit(allocator);

        try std.testing.expectError(error.OutOfMemory, in_mem_store.interface.writeAll(
            allocator,
            test_files[0][0],
            "Hello, world!\n",
        ));

        // Content should not be clobbered on OOM.
        try std.testing.expectEqualStrings(test_files[0][1], try in_mem_store.interface.readAll(
            allocator,
            test_files[0][0],
        ));
    }
};

test {
    std.testing.refAllDecls(@This());
}
