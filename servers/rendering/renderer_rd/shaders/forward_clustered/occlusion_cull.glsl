#[compute]

#version 450

#VERSION_DEFINES

// Two pass occlusion culling of the opaque render list, compiled once for each pass.
//
// The early pass tests every element against last frame's depth pyramid, using last frame's
// camera, and fills the visible commands for the first depth pass. Once that has been rendered
// and turned into a new depth pyramid, the visible commands are cleared and the late pass tests
// every element against the new pyramid. It refills the visible commands for the color pass,
// and fills the late commands with what the first depth pass missed.
//
// Batches keep their position in the render list. Each one owns a single draw command, and its
// instances are packed at the start of its range of the matching instance index indirection
// buffer, which the scene shaders use to find the instance data of the visible elements.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct CullElement {
	vec3 aabb_center; // Relative to the camera.
	uint element_index;
	vec3 aabb_extent;
	uint batch_first;
	uint index_count_depth;
	uint index_count_color;
	uint pad[2];
};

struct DrawIndexedIndirectCommand {
	uint index_count;
	uint instance_count;
	uint first_index;
	int vertex_offset;
	uint first_instance;
};

layout(set = 0, binding = 0, std430) restrict readonly buffer Elements {
	CullElement data[];
}
elements;

layout(set = 0, binding = 1, std430) restrict buffer VisibleCommands {
	DrawIndexedIndirectCommand data[];
}
visible_commands;

layout(set = 0, binding = 2, std430) restrict writeonly buffer VisibleInstanceIndexIndirection {
	uint data[];
}
visible_instance_index_indirection;

// One bit per element, so that the late pass knows what the early pass already drew.
layout(set = 0, binding = 3, std430) restrict buffer DrawnInFirstPass {
	uint data[];
}
drawn_in_first_pass;

layout(set = 0, binding = 4) uniform sampler2D hzb;

#ifdef LATE_PASS

layout(set = 0, binding = 5, std430) restrict buffer LateCommands {
	DrawIndexedIndirectCommand data[];
}
late_commands;

layout(set = 0, binding = 6, std430) restrict writeonly buffer LateInstanceIndexIndirection {
	uint data[];
}
late_instance_index_indirection;

#endif

layout(push_constant, std430) uniform Params {
	mat4 view_projection;
	uint element_count;
	uint hzb_mip_count;
	vec2 hzb_size;
}
params;

void emit_visible(CullElement p_element, uint p_index_count) {
	uint command = p_element.batch_first;
	visible_commands.data[command].index_count = p_index_count;
	uint batch_slot = atomicAdd(visible_commands.data[command].instance_count, 1u);
	visible_instance_index_indirection.data[command + batch_slot] = p_element.element_index;
}

#ifdef LATE_PASS
void emit_late(CullElement p_element, uint p_index_count) {
	uint command = p_element.batch_first;
	late_commands.data[command].index_count = p_index_count;
	uint batch_slot = atomicAdd(late_commands.data[command].instance_count, 1u);
	late_instance_index_indirection.data[command + batch_slot] = p_element.element_index;
}
#endif

bool is_occluded(vec3 p_center, vec3 p_extent) {
	float nearest_depth = 0.0;
	vec2 uv_min = vec2(1e20);
	vec2 uv_max = vec2(-1e20);

	for (uint i = 0; i < 8; i++) {
		vec3 corner_sign = vec3((i & 1) != 0 ? 1.0 : -1.0, (i & 2) != 0 ? 1.0 : -1.0, (i & 4) != 0 ? 1.0 : -1.0);
		vec4 clip = params.view_projection * vec4(p_center + p_extent * corner_sign, 1.0);
		if (clip.w <= 0.0) {
			return false; // Crosses the camera plane, so screen bounds are meaningless.
		}
		vec3 ndc = clip.xyz / clip.w;
		vec2 uv = ndc.xy * 0.5 + 0.5;
		uv_min = min(uv_min, uv);
		uv_max = max(uv_max, uv);
		nearest_depth = max(nearest_depth, ndc.z);
	}

	if (any(greaterThan(uv_min, vec2(1.0))) || any(lessThan(uv_max, vec2(0.0)))) {
		return false; // Outside of the view the pyramid was built from, so nothing is known about it.
	}

	uv_min = clamp(uv_min, vec2(0.0), vec2(1.0));
	uv_max = clamp(uv_max, vec2(0.0), vec2(1.0));

	// Pick the mip where the bounds cover at most two texels per axis.
	vec2 footprint = (uv_max - uv_min) * params.hzb_size;
	int mip = clamp(int(ceil(log2(max(max(footprint.x, footprint.y), 1.0)))), 0, int(params.hzb_mip_count) - 1);

	ivec2 mip_size = textureSize(hzb, mip);
	ivec2 from = clamp(ivec2(floor(uv_min * vec2(mip_size))), ivec2(0), mip_size - ivec2(1));
	ivec2 to = clamp(ivec2(ceil(uv_max * vec2(mip_size))) - ivec2(1), from, mip_size - ivec2(1));

	float farthest = 1.0;
	for (int y = from.y; y <= to.y; y++) {
		for (int x = from.x; x <= to.x; x++) {
			farthest = min(farthest, texelFetch(hzb, ivec2(x, y), mip).r);
		}
	}

	// Depth is reversed: occluded when even the nearest point is behind everything rendered there.
	return nearest_depth < farthest;
}

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= params.element_count) {
		return;
	}

	CullElement element = elements.data[index];
	uint word = index >> 5;
	uint bit = 1u << (index & 31u);

	if (is_occluded(element.aabb_center, element.aabb_extent)) {
		return;
	}

#ifndef LATE_PASS
	atomicOr(drawn_in_first_pass.data[word], bit);
	emit_visible(element, element.index_count_depth);
#else
	emit_visible(element, element.index_count_color);
	if ((drawn_in_first_pass.data[word] & bit) == 0) {
		emit_late(element, element.index_count_depth);
	}
#endif
}
