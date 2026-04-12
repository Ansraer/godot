// Shared definitions for raytracing shaders (raygen, miss, closest_hit, any_hit).
// Must be included before scene_data_inc.glsl since it defines MAX_VIEWS.

#define MAX_VIEWS 2

#ifndef PI
#define PI 3.141592653589f
#endif

// ============================================================================
// RT_PARAMS INDICES - Must match RT_PARAM_* in scene_shader_raytracing.h
// ============================================================================
// rt_params is a vec4[4] uniform buffer (16 floats total)
// Access: rt_params[idx >> 2][idx & 3] or get_rt_param(idx)
#define RT_PARAM_VIS_MODE 0 // rt_params[0].x - Debug visualization mode (0 = disabled)
#define RT_PARAM_SAMPLE_COUNT 1 // rt_params[0].y - Samples per pixel
#define RT_PARAM_MAX_BOUNCES 2 // rt_params[0].z - Maximum ray bounces
#define RT_PARAM_DENOISER 3 // rt_params[0].w - Denoiser selection (0=none, 1=DLSS RR)
// Indices 4-13 reserved for future use
#define RT_PARAM_LIGHT_COUNT 14 // rt_params[3].z - Number of active lights in light buffer
#define RT_PARAM_FRAME_INDEX 15 // rt_params[3].w - Frame counter for temporal variation

// ============================================================================
// PATHTRACING PAYLOAD (56 bytes)
// ============================================================================
// All shader stages must use identical struct layout for payload communication.
struct PathPayload {
	vec3 radiance; // 12 bytes - Output color / accumulated radiance
	uint packed_bounces_flags; // 4 bytes  - Packed: [flags:8][unused:8][diffuse_bounces:8][total_bounces:8]
	vec3 throughput; // 12 bytes - Path throughput
	uint rng_state; // 4 bytes  - RNG state for PCG
	// TODO: we could compress the next_ray data
	vec3 next_ray_origin; // 12 bytes - Origin for next bounce (set by closest_hit)
	vec3 next_ray_dir; // 12 bytes - Direction for next bounce (set by closest_hit)
};

// Bounce count helpers (bits 0-7: total, bits 8-15: diffuse)
uint get_total_bounces(uint packed) {
	return packed & 0xFFu;
}
uint get_diffuse_bounces(uint packed) {
	return (packed >> 8u) & 0xFFu;
}
uint pack_bounces(uint total, uint diffuse) {
	return total | (diffuse << 8u);
}
uint inc_total_bounce(uint packed) {
	return packed + 1u;
}
uint inc_diffuse_bounce(uint packed) {
	return packed + 0x101u;
} // +1 to both total and diffuse

// Sample 0 flag (bit 24) - only write DLSS RR outputs on first sample
const uint SAMPLE_ZERO_FLAG = (1u << 24);
uint set_sample_zero(uint packed) {
	return packed | SAMPLE_ZERO_FLAG;
}
bool is_sample_zero(uint packed) {
	return (packed & SAMPLE_ZERO_FLAG) != 0u;
}

// Continue bouncing flag (bit 25) - set by closest_hit when a next bounce is needed
const uint CONTINUE_RAY_FLAG = (1u << 25);
uint set_continue_ray(uint packed) {
	return packed | CONTINUE_RAY_FLAG;
}
bool should_continue_ray(uint packed) {
	return (packed & CONTINUE_RAY_FLAG) != 0u;
}
uint clear_continue_ray(uint packed) {
	return packed & ~CONTINUE_RAY_FLAG;
}

// Bounce limits
#define MAX_DIFFUSE_BOUNCES 2u
#define MAX_DENOISER_SPECULAR_HIT_THRESHOLD 0.25

// ============================================================================
// CONSTANTS
// ============================================================================
const uint OFFSET_NONE = 0xFFFFFFFFu;
const uint FLAG_COMPRESSED = 1u;

// ============================================================================
// RANDOM NUMBER GENERATION - PCG (Permuted Congruential Generator)
// ============================================================================

/// PCG random number generator - improved XSH-RR variant with better avalanche
uint pcg_hash(uint seed) {
	uint state = seed * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

/// Initialize RNG state with improved mixing to eliminate patterns
uint init_rng(uvec2 pixel, uint frame, uint sample_idx) {
	// Use Wang hash for better mixing - eliminates linear patterns
	uint seed = pixel.x + pixel.y * 65536u + frame * 1000000u + sample_idx * 100000000u;
	return pcg_hash(seed);
}

/// Random float in [0, 1)
float rand(inout uint state) {
	state = pcg_hash(state);
	return float(state) / 4294967296.0;
}

/// Random vec2 in [0, 1)
vec2 rand2(inout uint state) {
	return vec2(rand(state), rand(state));
}

// ============================================================================
// RAY ORIGIN OFFSET (prevents self-intersection)
// Simple geometry normal offset - works better than complex integer math
// ============================================================================
vec3 offset_ray_origin(vec3 p, vec3 n) {
	return p + n * 0.001;
}
