// SAX Referee 规则扩展
// 在现有 Referee 基础上新增 5 条 SAX 专属验证规则

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SaxTrap = enum {
    SaxStateLeak,
    SaxEventEscape,
    SaxRenderOutsideHandler,
    SaxInvalidInterpolation,
    SaxStateWriteFromOutside,
    SaxUnknownTag,
    SaxUnknownEvent,
};

pub const SaxRefereeRules = struct {
    allocator: Allocator,
    component_name: []const u8,
    state_vars: std.StringHashMap(void),
    handler_names: std.StringHashMap(void),
    current_handler: ?[]const u8 = null,

    pub fn init(allocator: Allocator, component_name: []const u8) SaxRefereeRules {
        return .{
            .allocator = allocator,
            .component_name = component_name,
            .state_vars = std.StringHashMap(void).init(allocator),
            .handler_names = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *SaxRefereeRules) void {
        self.state_vars.deinit();
        self.handler_names.deinit();
    }

    /// 注册状态变量
    pub fn registerStateVar(self: *SaxRefereeRules, var_name: []const u8) !void {
        try self.state_vars.put(var_name, {});
    }

    /// 注册事件处理函数
    pub fn registerHandler(self: *SaxRefereeRules, handler_name: []const u8) !void {
        try self.handler_names.put(handler_name, {});
    }

    /// 进入处理函数上下文
    pub fn enterHandler(self: *SaxRefereeRules, handler_name: []const u8) !void {
        if (!self.handler_names.contains(handler_name)) {
            return error.UnknownHandler;
        }
        self.current_handler = handler_name;
    }

    /// 离开处理函数上下文
    pub fn exitHandler(self: *SaxRefereeRules) void {
        self.current_handler = null;
    }

    /// Rule 1: SaxStateLeak
    /// 检查组件销毁时所有状态变量是否已释放
    pub fn checkStateLeak(self: *SaxRefereeRules, released_vars: std.StringHashMap(void)) !void {
        var iter = self.state_vars.keyIterator();
        while (iter.next()) |var_name| {
            if (!released_vars.contains(var_name.*)) {
                std.debug.print(
                    "SaxStateLeak: state variable '{s}' not released at component end\n",
                    .{var_name.*},
                );
                return error.SaxStateLeak;
            }
        }
    }

    /// Rule 2: SaxEventEscape
    /// 检查事件处理函数是否在同一组件内定义
    pub fn checkEventBinding(self: *SaxRefereeRules, handler_name: []const u8) !void {
        if (!self.handler_names.contains(handler_name)) {
            std.debug.print(
                "SaxEventEscape: handler '{s}' is not defined in this <Component>\n",
                .{handler_name},
            );
            return error.SaxEventEscape;
        }
    }

    /// Rule 3: SaxRenderOutsideHandler
    /// 检查 call @render() 是否只在处理函数内调用
    pub fn checkRenderCall(self: *SaxRefereeRules) !void {
        if (self.current_handler == null) {
            std.debug.print(
                "SaxRenderOutsideHandler: call @render() is only legal inside @handler\n",
                .{},
            );
            return error.SaxRenderOutsideHandler;
        }
    }

    /// Rule 4: SaxInvalidInterpolation
    /// 检查插值表达式中是否包含 ^ 或 !
    pub fn checkInterpolation(self: *SaxRefereeRules, expr: []const u8) !void {
        _ = self;
        if (std.mem.containsAtLeast(u8, expr, 1, "^") or
            std.mem.containsAtLeast(u8, expr, 1, "!"))
        {
            std.debug.print(
                "SaxInvalidInterpolation: interpolation '{s}' must not contain ^ or !\n",
                .{expr},
            );
            return error.SaxInvalidInterpolation;
        }
    }

    /// Rule 5: SaxStateWriteFromOutside
    /// 检查状态内存是否被组件外部写入（简化版）
    pub fn checkStateWrite(
        self: *SaxRefereeRules,
        memory_offset: usize,
        is_from_outside: bool,
    ) !void {
        _ = memory_offset;
        if (is_from_outside) {
            std.debug.print(
                "SaxStateWriteFromOutside: state slot of '{s}' written from outside component\n",
                .{self.component_name},
            );
            return error.SaxStateWriteFromOutside;
        }
    }

    /// Rule 6: SaxUnknownTag
    /// 检查 DOM 标签是否属于 SAX 白名单
    pub fn checkTag(self: *SaxRefereeRules, tag_name: []const u8, is_known: bool) !void {
        _ = self;
        if (!is_known) {
            std.debug.print("SaxUnknownTag: tag '{s}' is not allowed in SAX\n", .{tag_name});
            return error.SaxUnknownTag;
        }
    }

    /// Rule 7: SaxUnknownEvent
    /// 检查事件是否属于 SAX 白名单
    pub fn checkEventName(self: *SaxRefereeRules, event_name: []const u8, is_known: bool) !void {
        _ = self;
        if (!is_known) {
            std.debug.print("SaxUnknownEvent: event '{s}' is not allowed in SAX\n", .{event_name});
            return error.SaxUnknownEvent;
        }
    }
};
