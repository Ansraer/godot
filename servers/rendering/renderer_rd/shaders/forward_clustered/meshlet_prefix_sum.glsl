#[compute]

#version 450

#VERSION_DEFINES

#extension GL_KHR_shader_subgroup_basic : require
#extension GL_KHR_shader_subgroup_arithmetic : require

#include "meshlet_inc.glsl"

// Meshlet prefix sum over draw_counters[0 ... num_draws)
// Writes the per-draw start offset into prefix_sum[] and populates the indirect draw command buffer
//
// Smallish local size 128 -> only need a handful of subgroups
#define MAX_SUBGROUPS 64

layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;

// in
layout(push_constant, std430) uniform Params {
	uint num_draws;
}
params;

layout(set = 0, binding = 0, std430) restrict readonly buffer DrawCounters {
	uint data[];
}
draw_counters;

// output
layout(set = 0, binding = 1, std430) restrict writeonly buffer PrefixSum {
	uint data[];
}
prefix_sum;

layout(set = 0, binding = 2, std430) restrict writeonly buffer IndirectCmds {
	DrawIndexedIndirectCommand data[];
}
indirect_cmds;

shared uint sg_totals[MAX_SUBGROUPS];
shared uint sg_scanned[MAX_SUBGROUPS];
shared uint tile_carry;

void main() {
	uint lane = gl_LocalInvocationID.x;
	if (lane == 0u) {
		tile_carry = 0u;
	}
	barrier();

	uint num_subgroups = gl_NumSubgroups;
	uint sg_id = gl_SubgroupID;
	uint sg_lane = gl_SubgroupInvocationID;

	uint wg_size = gl_WorkGroupSize.x;
	uint tile_count = (params.num_draws + wg_size - 1u) / wg_size;

	for (uint tile = 0u; tile < tile_count; ++tile) {
		uint idx = tile * wg_size + lane;
		uint value = (idx < params.num_draws) ? draw_counters.data[idx] : 0u;

		uint sg_prefix = subgroupExclusiveAdd(value);
		uint sg_total = subgroupAdd(value);

		if (sg_lane == 0u) {
			sg_totals[sg_id] = sg_total;
		}
		barrier();

		// Scan the per-subgroup totals inside subgroup 0.
		if (sg_id == 0u) {
			uint t = (sg_lane < num_subgroups) ? sg_totals[sg_lane] : 0u;
			uint s = subgroupExclusiveAdd(t);
			if (sg_lane < num_subgroups) {
				sg_scanned[sg_lane] = s;
			}
		}
		barrier();

		uint offset = tile_carry + sg_scanned[sg_id] + sg_prefix;

		if (idx < params.num_draws) {
			prefix_sum.data[idx] = offset;

			DrawIndexedIndirectCommand cmd;
			cmd.index_count = uint(MAX_MESHLET_INDICES);
			cmd.instance_count = value;
			cmd.first_index = 0u;
			cmd.vertex_offset = 0;
			cmd.first_instance = 0u;
			indirect_cmds.data[idx] = cmd;
		}

		// Roll the running total forward by the sum of this tile so the next
		// iteration's offsets pick up where this one left off.
		if (lane == 0u) {
			uint tile_total = 0u;
			for (uint i = 0u; i < num_subgroups; ++i) {
				tile_total += sg_totals[i];
			}
			tile_carry += tile_total;
		}
		barrier();
	}
}
