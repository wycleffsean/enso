const std = @import("std");
const ssa = @import("../ssa.zig");

pub const Graph = struct {
    graph: *const ssa.SsaGraph,

    pub fn format(self: *const Graph, writer: *std.Io.Writer) !void {
        for (0..self.graph.cfg.blocks.len) |block_usize| {
            const block: ssa.BlockId = @intCast(block_usize);
            try writer.print("bb{d}:\n", .{block});

            const value_tags = self.graph.builder.values.items(.tag);
            const value_blocks = self.graph.builder.values.items(.block);
            const replacements = self.graph.builder.values.items(.replacement);
            for (value_tags, value_blocks, replacements, 0..) |tag, value_block, replacement, value_usize| {
                if (tag != .phi or value_block != block or replacement != std.math.maxInt(ssa.ValueId)) continue;
                const value: ssa.ValueId = @intCast(value_usize);
                const operands = self.graph.builder.phiOperands(value);
                try writer.print("    %{d} = phi", .{value});
                for (operands.preds, operands.values) |pred, operand| {
                    try writer.print(" [bb{d}: %{d}]", .{ pred, self.graph.builder.valueReplacement(operand) });
                }
                try writer.print("\n", .{});
            }

            const blocks = self.graph.insts.items(.block);
            const results = self.graph.insts.items(.result);
            const ops = self.graph.insts.items(.op);
            for (blocks, results, ops) |inst_block, result, op| {
                if (inst_block != block) continue;
                try writer.print("    ", .{});
                if (result) |value| try writer.print("%{d} = ", .{self.graph.builder.valueReplacement(value)});
                try formatOp(self.graph, writer, op);
                try writer.print("\n", .{});
            }
        }
    }
};

pub fn graph(value: *const ssa.SsaGraph) Graph {
    return .{ .graph = value };
}

fn formatOp(graph_value: *const ssa.SsaGraph, writer: *std.Io.Writer, op: ssa.Op) !void {
    switch (op) {
        .load_const => |value| try writer.print("load_const {f}", .{value}),
        .load_name => |name| try writer.print("load_name {f}", .{name}),
        .store_name => |store| try writer.print("store_name {f}, %{d}", .{ store.name, graph_value.builder.valueReplacement(store.value) }),
        .binary_op => |binary| try writer.print("binary_op {s}, %{d}, %{d}", .{
            @tagName(binary.op),
            graph_value.builder.valueReplacement(binary.lhs),
            graph_value.builder.valueReplacement(binary.rhs),
        }),
        .call => |call| {
            try writer.print("call %{d}, %{d}", .{
                graph_value.builder.valueReplacement(call.receiver),
                graph_value.builder.valueReplacement(call.name),
            });
            for (graph_value.call_args.items[call.args_start..][0..call.args_len]) |arg| {
                try writer.print(", %{d}", .{graph_value.builder.valueReplacement(arg)});
            }
        },
        .pop_top => |value| try writer.print("pop_top %{d}", .{graph_value.builder.valueReplacement(value)}),
        .branch_if_false => |branch| try writer.print("br_if_false %{d}, bb{d}, bb{d}", .{
            graph_value.builder.valueReplacement(branch.condition),
            branch.false_block,
            branch.true_block,
        }),
        .branch_if_true => |branch| try writer.print("br_if_true %{d}, bb{d}, bb{d}", .{
            graph_value.builder.valueReplacement(branch.condition),
            branch.true_block,
            branch.false_block,
        }),
        .jump => |target| try writer.print("jump bb{d}", .{target}),
        .return_value => |ret| try writer.print("return %{d}", .{graph_value.builder.valueReplacement(ret.value)}),
        .return_const => |value| try writer.print("return_const {f}", .{value}),
        .nop => try writer.print("nop", .{}),
    }
}
