#[compute]

#version 450

#VERSION_DEFINES

#extension GL_KHR_shader_subgroup_ballot : require
#extension GL_KHR_shader_subgroup_arithmetic : require

#include "meshlet_inc.glsl"

// Switch between outputting only count for prefix sum vs actual data
#define MODE_COUNT 0u
#define MODE_WRITE 1u
layout(constant_id = 0) const uint sc_cull_mode = MODE_COUNT;

layout(push_constant, std430) uniform Params {
	uint draw_id;
	uint meshlet_count;
	uint instance_count;
}
params;

layout(set = 0, binding = 0, std430) restrict buffer DrawCounters {
	uint data[];
}
draw_counters;

// Bindings below are only needed in MODE_WRITE
// I kept them here so I can recycle the same uniform set for both
layout(set = 0, binding = 1, std430) restrict readonly buffer PrefixSum {
	uint data[];
}
prefix_sum;

layout(set = 0, binding = 2, std430) restrict buffer WriteCursors {
	uint data[];
}
write_cursors;

layout(set = 0, binding = 3, std430) restrict writeonly buffer MeshletInstances {
	MeshletInstance data[];
}
meshlet_instances;

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

bool meshlet_cull(uint meshlet_id, uint instance_id) {
	//TODO: implement me
	return true;
}

void main() {
	uint meshlet_id = gl_GlobalInvocationID.x;
	uint instance_id = gl_WorkGroupID.y + gl_WorkGroupID.z * 65535u;

	if (meshlet_id >= params.meshlet_count || instance_id >= params.instance_count) {
		return;
	}

	bool survives = in_range && meshlet_cull(meshlet_id, instance_id);

	uvec4 ballot = subgroupBallot(survives);
	uint subgroup_survivors = subgroupBallotBitCount(ballot);

	if (sc_cull_mode == MODE_COUNT) {
		if (subgroup_survivors > 0u && subgroupElect()) {
			atomicAdd(draw_counters.data[params.draw_id], subgroup_survivors);
		}
	} else {
		uint local_rank = subgroupBallotExclusiveBitCount(ballot);

		uint subgroup_base = 0u;
		if (subgroupElect()) {
			subgroup_base = atomicAdd(write_cursors.data[params.draw_id], subgroup_survivors);
		}
		subgroup_base = subgroupBroadcastFirst(subgroup_base);

		if (survives) {
			uint write_index = prefix_sum.data[params.draw_id] + subgroup_base + local_rank;
			MeshletInstance mi;
			mi.meshlet_id = meshlet_id;
			mi.instance_id = instance_id;
			meshlet_instances.data[write_index] = mi;
		}
	}
}
