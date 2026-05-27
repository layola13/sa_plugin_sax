// SAX 模块主入口
// 整合 Parser、Lowerer、Airlock、Referee 规则

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const parser = @import("parser.zig");
pub const lowerer = @import("lowerer.zig");
pub const airlock_gen = @import("airlock_gen.zig");
pub const build = @import("build.zig");
pub const sax_rules = @import("sax_rules.zig");

pub const SaxCompiler = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) SaxCompiler {
        return .{ .allocator = allocator };
    }

    /// 完整编译流程：.sax → .sa → Referee → WASM
    pub fn compile(
        self: *SaxCompiler,
        sax_source: []const u8,
        component_name: []const u8,
    ) !struct {
        sa_code: std.ArrayList(u8),
        airlock_js: std.ArrayList(u8),
        index_html: std.ArrayList(u8),
    } {
        var sax_parser = parser.SaxParser.init(self.allocator, sax_source);
        var program = try sax_parser.parse();
        defer program.deinit();

        if (program.components.len == 0) return error.InvalidComponentBody;

        var sa_code = std.ArrayList(u8).init(self.allocator);
        errdefer sa_code.deinit();

        for (program.components, 0..) |component, idx| {
            var sax_lowerer = try lowerer.SaxLowerer.init(self.allocator, component);
            defer sax_lowerer.deinit();

            const opts: lowerer.LowerOptions = .{ .emit_shared_decls = idx == 0 };
            try sax_lowerer.lower(&sa_code, opts);

            if (idx + 1 < program.components.len) try sa_code.writer().writeByte('\n');
        }

        if (program.components.len != 0) {
            const root_name = try lowercaseName(self.allocator, program.components[0].name);
            defer self.allocator.free(root_name);
            try sa_code.writer().print("@export sax_app_init() -> ptr:\nL_ENTRY:\n  ctx = call @sax_{s}_init()\n  return ctx\n\n", .{root_name});
        }

        var airlock_generator = airlock_gen.AirlockGenerator.init(self.allocator);
        const airlock_js = try airlock_generator.generateAirlockJS();
        errdefer airlock_js.deinit();

        const index_html = try airlock_generator.generateIndexHTML(component_name, "app.wasm");
        errdefer index_html.deinit();

        return .{
            .sa_code = sa_code,
            .airlock_js = airlock_js,
            .index_html = index_html,
        };
    }
};

fn lowercaseName(allocator: Allocator, text: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, text);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const compiler = SaxCompiler.init(allocator);
    _ = compiler;
}
