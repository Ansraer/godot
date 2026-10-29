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

// Set 4: per-surface meshlet data
// layout must match scene_forward_clustered_inc.glsl (USE_MESHLETS)!
layout(set = 4, binding = 0, std140) uniform MeshletSurfaceInfo {
	uint meshlet_count;
	uint lod_group_count;
	uint format_flags_lo;
	uint format_flags_hi;
	uint vertex_count;
}
meshlet_surface_info;

layout(set = 4, binding = 1, std430) restrict readonly buffer MeshletBuffer {
	Meshlet data[];
}
meshlets;

layout(set = 4, binding = 2, std430) restrict readonly buffer MeshletVerticesBuffer {
	uint data[];
}
meshlet_vertices;

layout(set = 4, binding = 3, std430) restrict readonly buffer MeshletTrianglesBuffer {
	uint data[];
}
meshlet_triangles;

layout(set = 4, binding = 4, std430) restrict readonly buffer LodGroupBuffer {
	MeshletLodGroup data[];
}
lod_groups;

layout(set = 4, binding = 5, std430) restrict readonly buffer MeshletVertexBuffer {
	uint data[];
}
meshlet_vertex_buffer;

layout(set = 4, binding = 6, std430) restrict readonly buffer MeshletAttributeBuffer {
	uint data[];
}
meshlet_attribute_buffer;

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

bool meshlet_cull(uint meshlet_id, uint instance_id) {
	if (meshlet_id < meshlet_surface_info.meshlet_count) {
		Meshlet m = meshlets.data[meshlet_id];
		MeshletLodGroup g = lod_groups.data[0];

		// for now only render leaf nodes (highest quality LOD)
		if (m.own_group_id == 0xFFFFFFFFu) {
			return false;
		}
	}
	return true;
}

void main() {
	uint meshlet_id = gl_GlobalInvocationID.x;
	uint instance_id = gl_WorkGroupID.y + gl_WorkGroupID.z * 65535u;

	bool in_range = (meshlet_id < params.meshlet_count) && (instance_id < params.instance_count);
	bool survives = in_range && !meshlet_cull(meshlet_id, instance_id);

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
