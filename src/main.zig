const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer if (gpa.deinit() == .leak) @panic("LEAK");
    const allocator = gpa.allocator();

    const cwd = std.fs.cwd();

    var repo_dir = cwd.openDir("repos", .{}) catch |err| blk: {
        if (err == std.fs.Dir.OpenError.FileNotFound) {
            try cwd.makeDir("repos");
        }

        break :blk try cwd.openDir("repos", .{});
    };
    defer repo_dir.close();

    const org = "LittleBigRefresh";
    const repos: []const []const u8 = &.{
        "Refresh",
        "Bunkum",
        "FreshPresence",
        "Docs",
        "MarkdownToDiscord",
        "refresh-web",
        "refresh-api-zig",
        "Refresh.GopherFrontend",
        "AttribDoc",
        "Refresher",
        "Infrastructure",
        "GenderFluid",
        "Allefresher",
        "Sackbot",
        "SCEToolSharp",
        "NPTicket",
    };

    const RepoInfo = struct {
        files: std.StringHashMap(FileCounts),
        types: std.StringHashMap(FileCounts),
    };

    var map = std.StringHashMap(RepoInfo).init(allocator);
    defer map.deinit();

    var global_type_map = std.StringArrayHashMap(FileCounts).init(allocator);
    defer global_type_map.deinit();

    for (repos) |repo| {
        try cloneRepo(allocator, repo_dir, org, repo);

        var iter = try repo_dir.openIterableDir(repo, .{});
        defer iter.close();

        const ret = try cloc(allocator, iter);

        const info: RepoInfo = .{
            .files = ret.files,
            .types = ret.types,
        };

        try map.put(repo, info);
    }

    var iter = map.iterator();
    while (iter.next()) |repo| {
        const info = repo.value_ptr.*;

        var file_iter = info.files.iterator();
        var code: usize = 0;
        var blank: usize = 0;
        var scope: usize = 0;
        while (file_iter.next()) |file| {
            code += file.value_ptr.code;
            scope += file.value_ptr.scope;
            blank += file.value_ptr.blank;
        }
        std.debug.print("{s}/{s} has {d} lines ({d} blank, {d} scope)\n", .{ org, repo.key_ptr.*, code, blank, scope });
        var type_iter = info.types.iterator();
        while (type_iter.next()) |file_type| {
            std.debug.print(" ({s}) => {d} lines ({d} blank, {d} scope)\n", .{ file_type.key_ptr.*, file_type.value_ptr.code, file_type.value_ptr.blank, file_type.value_ptr.scope });

            var res = try global_type_map.getOrPut(file_type.key_ptr.*);
            if (!res.found_existing) res.value_ptr.* = .{
                .code = 0,
                .scope = 0,
                .blank = 0,
            };
            res.value_ptr.code += file_type.value_ptr.code;
            res.value_ptr.blank += file_type.value_ptr.blank;
            res.value_ptr.scope += file_type.value_ptr.scope;
        }
    }

    std.debug.print("\nTotal line counts:\n", .{});

    var sorted_entries = std.ArrayList(SortableEntry).init(allocator);
    defer sorted_entries.deinit();

    var type_iter = global_type_map.iterator();
    while (type_iter.next()) |file_type| {
        try sorted_entries.append(.{ .name = file_type.key_ptr.*, .counts = file_type.value_ptr.* });
    }

    std.sort.block(SortableEntry, sorted_entries.items, {}, SortableEntry.sort);

    for (sorted_entries.items) |entry| {
        std.debug.print("  {s} => {d} lines ({d} blank, {d} scope)\n", .{ entry.name, entry.counts.code, entry.counts.blank, entry.counts.scope });
    }
}

const SortableEntry = struct {
    name: []const u8,
    counts: FileCounts,

    pub fn sort(context: void, lhs: SortableEntry, rhs: SortableEntry) bool {
        _ = context;
        return lhs.counts.code > rhs.counts.code;
    }
};

const FileCounts = struct {
    code: usize,
    blank: usize,
    scope: usize,
};

fn cloc(allocator: std.mem.Allocator, dir: std.fs.IterableDir) !struct { files: std.StringHashMap(FileCounts), types: std.StringHashMap(FileCounts) } {
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var counts = std.StringHashMap(FileCounts).init(allocator);
    errdefer counts.deinit();

    var types = std.StringHashMap(FileCounts).init(allocator);
    errdefer types.deinit();

    walk: while (try walker.next()) |entry| {
        //Skip non-files
        if (entry.kind != .file)
            continue;

        if (std.mem.indexOf(u8, entry.path, ".git") != null)
            continue;
        if (std.mem.indexOf(u8, entry.path, "obj/") != null)
            continue;
        if (std.mem.indexOf(u8, entry.path, "bin/") != null)
            continue;
        if (std.mem.indexOf(u8, entry.path, ".idea") != null)
            continue;

        var file = try dir.dir.openFile(entry.path, .{});
        defer file.close();

        var buffered_reader = std.io.bufferedReader(file.reader());
        const reader = buffered_reader.reader();

        const scope_chars: []const u8 = &.{ '{', '}', '[', ']', '(', ')' };

        var line_count: usize = 0;
        var blank_count: usize = 0;
        var scope_count: usize = 0;
        var found_non_whitespace = false;
        var found_non_scope = false;
        var line_length: usize = 0;
        var b: [1]u8 = .{0};
        while (try reader.read(&b) > 0) {
            //Skip the BOMs
            if (b[0] == 0xFE or b[0] == 0xFF or b[0] == 0xEF or b[0] == 0xBF or b[0] == 0xBB) continue;

            if (!std.ascii.isASCII(b[0])) {
                // std.debug.print("{d}\n", .{b[0]});
                // std.debug.print("skipping {s}\n", .{entry.path});
                continue :walk;
            }

            //Skip carriage returns
            if (b[0] == '\r') continue;

            if (b[0] == '\n') {
                // std.debug.print("::: found line with length {d} {} {}\n", .{ line_length, found_non_whitespace, found_non_scope });

                if (found_non_scope and found_non_whitespace) {
                    line_count += 1;
                }

                if (!found_non_scope and found_non_whitespace) {
                    scope_count += 1;
                }

                if (!found_non_whitespace) {
                    blank_count += 1;
                }

                line_length = 0;

                found_non_scope = false;
                found_non_whitespace = false;
            } else {
                if (!std.ascii.isWhitespace(b[0])) {
                    if (std.mem.indexOf(u8, scope_chars, &.{b[0]}) == null) {
                        found_non_scope = true;
                    }

                    found_non_whitespace = true;

                    //Increment the line length
                    line_length += 1;
                }
            }
        }

        var res = try counts.getOrPut(try allocator.dupe(u8, entry.path));
        res.value_ptr.* = .{
            .code = line_count,
            .blank = blank_count,
            .scope = scope_count,
        };

        const period_count = std.mem.count(u8, entry.basename, ".");
        const extension = try allocator.dupe(u8, if ((period_count == 1 and entry.basename[0] == '.') or period_count == 0) entry.basename else std.fs.path.extension(entry.basename));

        // std.debug.print("basename: {s}\n", .{entry.basename});

        var type_res = try types.getOrPut(extension);
        if (!type_res.found_existing)
            type_res.value_ptr.* = .{
                .code = 0,
                .blank = 0,
                .scope = 0,
            };
        type_res.value_ptr.code += line_count;
        type_res.value_ptr.blank += blank_count;
        type_res.value_ptr.scope += scope_count;
    }

    return .{
        .files = counts,
        .types = types,
    };
}

fn cloneRepo(allocator: std.mem.Allocator, folder: std.fs.Dir, org: []const u8, repo: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}", .{ org, repo });
    defer allocator.free(url);

    var child = std.process.Child.init(&.{ "git", "clone", url, "--depth", "1" }, allocator);
    child.cwd_dir = folder;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = try child.spawnAndWait();
}
