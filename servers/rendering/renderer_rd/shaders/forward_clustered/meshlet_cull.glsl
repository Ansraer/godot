#[compute]

#version 450

#VERSION_DEFINES

#extension GL_KHR_shader_subgroup_ballot : require
#extension GL_KHR_shader_subgroup_arithmetic : require

#include "meshlet_inc.glsl"

#define FLT_MAX 3.402823466e38

// Switch between outputting only count for prefix sum vs actual data
#define MODE_COUNT 0u
#define MODE_WRITE 1u
layout(constant_id = 0) const uint sc_cull_mode = MODE_COUNT;

// Must match RenderForwardClustered::MeshletCulling::CULL_FLAG_*
#define CULL_FLAG_MULTIMESH (1u << 0u)
#define CULL_FLAG_MULTIMESH_FORMAT_2D (1u << 1u)
#define CULL_FLAG_MULTIMESH_HAS_COLOR (1u << 2u)
#define CULL_FLAG_MULTIMESH_HAS_CUSTOM_DATA (1u << 3u)
#define CULL_FLAG_LOD_DISABLED (1u << 4u) // Only render leaf meshlets (highest detail).
#define CULL_FLAG_ORTHOGONAL (1u << 5u)

// Must match RenderForwardClustered::MeshletCulling::PushConstant
layout(push_constant, std430) uniform Params {
	mat3x4 camera_view_matrix;

	float lod_scale;
	float z_near;
	uint flags;
	uint multimesh_offset;

	uint draw_id;
	uint meshlet_count;
	uint instance_count;
	uint instance_base; // Index of the first InstanceData for this draw
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

// Set 1: per-draw instance data
// Must match scene_forward_clustered_inc.glsl InstanceData
struct InstanceData {
	mat3x4 transform;
	vec4 compressed_aabb_position_pad;
	vec4 compressed_aabb_size_pad;
	vec4 uv_scale;
	uint flags;
	uint instance_uniforms_ofs;
	uint gi_offset;
	uint layer_mask;
	mat3x4 prev_transform;
	vec4 lightmap_uv_scale;
#ifdef USE_DOUBLE_PRECISION
	vec4 model_precision;
	vec4 prev_model_precision;
#endif
};

layout(set = 1, binding = 0, std430) restrict readonly buffer InstanceDataBuffer {
	InstanceData data[];
}
instances;

// Multimesh transforms (only if CULL_FLAG_MULTIMESH is set)
layout(set = 1, binding = 1, std430) restrict readonly buffer Transforms {
	vec4 data[];
}
transforms;

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

#define INVALID_GROUP_ID 0xFFFFFFFFu

mat4 get_model_matrix_regular(uint instance_index) {
	mat3x4 t = instances.data[instance_index].transform;
	return transpose(mat4(t[0], t[1], t[2], vec4(0.0, 0.0, 0.0, 1.0)));
}

mat4 get_model_matrix_multimesh(uint instance_index, uint multimesh_instance) {
	// Same layout as in scene_forward_clustered.glsl
	uint stride = (params.flags & CULL_FLAG_MULTIMESH_FORMAT_2D) != 0u ? 2u : 3u;
	stride += (params.flags & CULL_FLAG_MULTIMESH_HAS_COLOR) != 0u ? 1u : 0u;
	stride += (params.flags & CULL_FLAG_MULTIMESH_HAS_CUSTOM_DATA) != 0u ? 1u : 0u;
	uint offset = stride * (multimesh_instance + params.multimesh_offset);

	mat4 matrix;
	if ((params.flags & CULL_FLAG_MULTIMESH_FORMAT_2D) != 0u) {
		matrix = mat4(transforms.data[offset + 0u], transforms.data[offset + 1u], vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	} else {
		matrix = mat4(transforms.data[offset + 0u], transforms.data[offset + 1u], transforms.data[offset + 2u], vec4(0.0, 0.0, 0.0, 1.0));
	}
	return get_model_matrix_regular(instance_index) * transpose(matrix);
}

mat4 get_model_matrix(uint instance_id) {
	if ((params.flags & CULL_FLAG_MULTIMESH) != 0u) {
		return get_model_matrix_multimesh(params.instance_base, instance_id);
	}
	return get_model_matrix_regular(params.instance_base + instance_id);
}

float lod_group_projected_error(uint group_id, mat4 model_view, float scale) {
	MeshletLodGroup g = lod_groups.data[group_id];
	if (g.error >= FLT_MAX / 2.0) {
		// Terminal group that can't be simplified further
		return FLT_MAX;
	}

	float error = g.error * scale;
	if ((params.flags & CULL_FLAG_ORTHOGONAL) != 0u) {
		return error * params.lod_scale;
	}

	vec3 center = (model_view * vec4(g.sphere.xyz, 1.0)).xyz;
	float radius = g.sphere.w * scale;

	// distance from the camera to the closest point of the error sphere
	float distance = max(length(center) - radius, params.z_near);
	return error / distance * params.lod_scale;
}

bool meshlet_cull(uint meshlet_id, uint instance_id) {
	Meshlet m = meshlets.data[meshlet_id];

	if ((params.flags & CULL_FLAG_LOD_DISABLED) != 0u) {
		// Only render leaf nodes
		return m.own_group_id != INVALID_GROUP_ID;
	}

	// NORMAL CULLING
	// TODO: implement me

	// LOD SELECTION

	mat4 camera_view_matrix = transpose(mat4(params.camera_view_matrix[0], params.camera_view_matrix[1], params.camera_view_matrix[2], vec4(0.0, 0.0, 0.0, 1.0)));
	mat4 model_view = camera_view_matrix * get_model_matrix(instance_id);

	// Errors and radii are stored in mesh space, scale them by the largest axis scale
	float scale = sqrt(max(dot(model_view[0].xyz, model_view[0].xyz), max(dot(model_view[1].xyz, model_view[1].xyz), dot(model_view[2].xyz, model_view[2].xyz))));

	float self_error = m.own_group_id == INVALID_GROUP_ID ? 0.0 : lod_group_projected_error(m.own_group_id, model_view, scale);
	float parent_error = m.parent_group_id == INVALID_GROUP_ID ? 3.4e38 : lod_group_projected_error(m.parent_group_id, model_view, scale);

	// render anything with an error <= 1.0, iff we can't instead use the cheaper parent
	bool render = self_error <= 1.0 && parent_error > 1.0;
	return !render;
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
