#[compute]

#version 450

#VERSION_DEFINES

// TODO: replace this with AMD's SPD? Probably best to profile first. Why aren't me using SPD for mipmap generation anyways?
// Builds one mip of the occlusion culling depth pyramid. Depth is reversed, so we store the smallest depth

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_depth;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D dest_depth;

layout(push_constant, std430) uniform Params {
	ivec2 dest_size;
	vec2 source_scale;
}
params;

void main() {
	ivec2 dest_pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(dest_pos, params.dest_size))) {
		return;
	}

	// The first mip is rounded down to a power of two, so one texel can cover up to
	// three source texels per axis. Fetch all of them to stay conservative.
	ivec2 source_max = textureSize(source_depth, 0) - ivec2(1);
	ivec2 from = clamp(ivec2(floor(vec2(dest_pos) * params.source_scale)), ivec2(0), source_max);
	ivec2 to = clamp(ivec2(ceil(vec2(dest_pos + ivec2(1)) * params.source_scale)) - ivec2(1), from, source_max);

	float farthest = 1.0;
	for (int y = from.y; y <= to.y; y++) {
		for (int x = from.x; x <= to.x; x++) {
			farthest = min(farthest, texelFetch(source_depth, ivec2(x, y), 0).r);
		}
	}

	imageStore(dest_depth, dest_pos, vec4(farthest));
}
