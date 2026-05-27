const std = @import("std");

pub const table = @import("referee/table.zig");
pub const call = @import("referee/call.zig");
pub const verifier = @import("referee/verifier.zig");

pub const CapabilityTable = table.CapabilityTable;
pub const TableError = table.TableError;
pub const AnnotatedInstruction = verifier.AnnotatedInstruction;
pub const VerifyOk = verifier.VerifyOk;
pub const VerifyResult = verifier.VerifyResult;
pub const VerifyOptions = verifier.VerifyOptions;
pub const SaxValidationContext = verifier.SaxValidationContext;
pub const verify = verifier.verify;
pub const verifyWithOptions = verifier.verifyWithOptions;

test "referee exports real modules" {
    _ = CapabilityTable;
    _ = verify;
    try std.testing.expect(true);
}
