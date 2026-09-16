#define MESHLET_SURFACE_SET 4
#define MAX_MESHLET_VERTICES 64
#define MAX_MESHLET_TRIANGLES 128
#define MAX_MESHLET_INDICES (MAX_MESHLET_TRIANGLES * 3)

// ArrayFormat bit flags — must match RenderingServerEnums::ArrayFormat
#define ARRAY_FORMAT_VERTEX (1u << 0)
#define ARRAY_FORMAT_NORMAL (1u << 1)
#define ARRAY_FORMAT_TANGENT (1u << 2)
#define ARRAY_FORMAT_COLOR (1u << 3)
#define ARRAY_FORMAT_TEX_UV (1u << 4)
#define ARRAY_FORMAT_TEX_UV2 (1u << 5)
#define ARRAY_FORMAT_CUSTOM0 (1u << 6)
#define ARRAY_FORMAT_CUSTOM1 (1u << 7)
#define ARRAY_FORMAT_CUSTOM2 (1u << 8)
#define ARRAY_FORMAT_CUSTOM3 (1u << 9)

#define ARRAY_FORMAT_CUSTOM_BASE 13u
#define ARRAY_FORMAT_CUSTOM_BITS 3u
#define ARRAY_FORMAT_CUSTOM_MASK 0x7u
#define ARRAY_FORMAT_CUSTOM0_SHIFT 13u
#define ARRAY_FORMAT_CUSTOM1_SHIFT 16u
#define ARRAY_FORMAT_CUSTOM2_SHIFT 19u
#define ARRAY_FORMAT_CUSTOM3_SHIFT 22u

#define ARRAY_COMPRESS_FLAGS_BASE 25u
#define ARRAY_FLAG_USE_2D_VERTICES (1u << 25)
#define ARRAY_FLAG_COMPRESS_ATTRIBUTES (1u << 29)

#define ARRAY_CUSTOM_RGBA8_UNORM 0u
#define ARRAY_CUSTOM_RGBA8_SNORM 1u
#define ARRAY_CUSTOM_RG_HALF 2u
#define ARRAY_CUSTOM_RGBA_HALF 3u
#define ARRAY_CUSTOM_R_FLOAT 4u
#define ARRAY_CUSTOM_RG_FLOAT 5u
#define ARRAY_CUSTOM_RGB_FLOAT 6u
#define ARRAY_CUSTOM_RGBA_FLOAT 7u

// Must match RenderingServerTypes::Meshlet.
struct Meshlet {
	uint vertex_offset;
	uint triangle_offset;
	uint vertex_count;
	uint triangle_count;
	uint own_group_id;
	uint parent_group_id;
};

// Must match RenderingServerTypes::MeshletLodGroup.
struct MeshletLodGroup {
	// sphere coords and error
	vec4 sphere;

	float error;
	float _pad0;
	float _pad1;
	float _pad2;
};

// post culling compact output
struct MeshletInstance {
	uint meshlet_id;
	uint instance_id;
};

struct DrawIndexedIndirectCommand {
	uint index_count;
	uint instance_count;
	uint first_index;
	int vertex_offset;
	uint first_instance;
};

layout(set = MESHLET_SURFACE_SET, binding = 0, std140) uniform MeshletSurfaceInfo {
	uint meshlet_count;
	uint lod_group_count;
	uint format_flags_lo;
	uint format_flags_hi;
	uint vertex_count;
}
meshlet_surface_info;

layout(set = MESHLET_SURFACE_SET, binding = 1, std430) restrict readonly buffer MeshletBuffer {
	Meshlet data[];
}
meshlets;

// This currently is a uint32 array, while on the cpu side we upload uint8. WHEN ACCESSING THIS WE NEED TO PROPERLY EXTRACT THE DATA WE NEED!!!!
// TODO: look into using GL_EXT_shader_explicit_arithmetic_types_int8 and VK_KHR_8bit_storage instead.
layout(set = MESHLET_SURFACE_SET, binding = 2, std430) restrict readonly buffer MeshletVerticesBuffer {
	uint data[];
}
meshlet_vertices;

layout(set = MESHLET_SURFACE_SET, binding = 3, std430) restrict readonly buffer MeshletTrianglesBuffer {
	uint data[];
}
meshlet_triangles;

layout(set = MESHLET_SURFACE_SET, binding = 4, std430) restrict readonly buffer LodGroupBuffer {
	MeshletLodGroup data[];
}
lod_groups;

layout(set = MESHLET_SURFACE_SET, binding = 5, std430) restrict readonly buffer MeshletVertexBuffer {
	uint data[];
}
meshlet_vertex_buffer;

layout(set = MESHLET_SURFACE_SET, binding = 6, std430) restrict readonly buffer MeshletAttributeBuffer {
	uint data[];
}
meshlet_attribute_buffer;

// Vertex Pulling Helpers

uint meshlet_custom_size(uint fmt) {
	// Matches ArrayCustomFormat size table.
	if (fmt == ARRAY_CUSTOM_RGBA8_UNORM) {
		return 4u;
	}
	if (fmt == ARRAY_CUSTOM_RGBA8_SNORM) {
		return 4u;
	}
	if (fmt == ARRAY_CUSTOM_RG_HALF) {
		return 4u;
	}
	if (fmt == ARRAY_CUSTOM_RGBA_HALF) {
		return 8u;
	}
	if (fmt == ARRAY_CUSTOM_R_FLOAT) {
		return 4u;
	}
	if (fmt == ARRAY_CUSTOM_RG_FLOAT) {
		return 8u;
	}
	if (fmt == ARRAY_CUSTOM_RGB_FLOAT) {
		return 12u;
	}
	if (fmt == ARRAY_CUSTOM_RGBA_FLOAT) {
		return 16u;
	}
	return 0u;
}

uint meshlet_custom_format(uint slot) {
	uint fmt_lo = meshlet_surface_info.format_flags_lo;
	uint shift = ARRAY_FORMAT_CUSTOM_BASE + ARRAY_FORMAT_CUSTOM_BITS * slot;
	return (fmt_lo >> shift) & ARRAY_FORMAT_CUSTOM_MASK;
}

uint meshlet_position_stride() {
	uint fmt = meshlet_surface_info.format_flags_lo;
	if ((fmt & ARRAY_FLAG_USE_2D_VERTICES) != 0u) {
		return 8u; // 2 floats
	}
	if ((fmt & ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0u) {
		return 8u; // 4 uint16 (xyz + angle)
	}
	return 12u; // 3 floats
}

uint meshlet_normal_tangent_stride() {
	uint fmt = meshlet_surface_info.format_flags_lo;
	uint s = 0u;
	if ((fmt & ARRAY_FORMAT_NORMAL) != 0u) {
		s += 4u; // 2 uint16
	}
	if ((fmt & ARRAY_FORMAT_TANGENT) != 0u) {
		s += ((fmt & ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0u) ? 0u : 4u;
	}
	return s;
}

uint meshlet_attribute_stride() {
	uint fmt = meshlet_surface_info.format_flags_lo;
	uint s = 0u;
	if ((fmt & ARRAY_FORMAT_COLOR) != 0u) {
		s += 4u;
	}
	uint uv_size = ((fmt & ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0u) ? 4u : 8u;
	if ((fmt & ARRAY_FORMAT_TEX_UV) != 0u) {
		s += uv_size;
	}
	if ((fmt & ARRAY_FORMAT_TEX_UV2) != 0u) {
		s += uv_size;
	}
	for (uint i = 0u; i < 4u; i++) {
		if ((fmt & (ARRAY_FORMAT_CUSTOM0 << i)) != 0u) {
			s += meshlet_custom_size(meshlet_custom_format(i));
		}
	}
	return s;
}

// Per-vertex byte offsets inside the packed vertex_buffer / attribute_buffer

uint meshlet_position_offset(uint global_vidx) {
	return global_vidx * meshlet_position_stride();
}

uint meshlet_normal_tangent_offset(uint global_vidx) {
	uint segment_start = meshlet_position_stride() * meshlet_surface_info.vertex_count;
	return segment_start + global_vidx * meshlet_normal_tangent_stride();
}

uint meshlet_attribute_record_offset(uint global_vidx) {
	return global_vidx * meshlet_attribute_stride();
}

uint meshlet_color_offset_in_record() {
	return 0u; // Color always first (if present).
}

uint meshlet_uv_offset_in_record() {
	uint fmt = meshlet_surface_info.format_flags_lo;
	return ((fmt & ARRAY_FORMAT_COLOR) != 0u) ? 4u : 0u;
}

uint meshlet_uv2_offset_in_record() {
	uint fmt = meshlet_surface_info.format_flags_lo;
	uint o = meshlet_uv_offset_in_record();
	if ((fmt & ARRAY_FORMAT_TEX_UV) != 0u) {
		o += ((fmt & ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0u) ? 4u : 8u;
	}
	return o;
}

uint meshlet_custom_offset_in_record(uint slot) {
	uint fmt = meshlet_surface_info.format_flags_lo;
	uint o = meshlet_uv2_offset_in_record();
	if ((fmt & ARRAY_FORMAT_TEX_UV2) != 0u) {
		o += ((fmt & ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0u) ? 4u : 8u;
	}
	for (uint i = 0u; i < slot; i++) {
		if ((fmt & (ARRAY_FORMAT_CUSTOM0 << i)) != 0u) {
			o += meshlet_custom_size(meshlet_custom_format(i));
		}
	}
	return o;
}

// Raw uint fetch helpers (all offsets in bytes; must be 4-aligned)

uint meshlet_vb_load_u32(uint byte_off) {
	return meshlet_vertex_buffer.data[byte_off >> 2];
}

uint meshlet_ab_load_u32(uint byte_off) {
	return meshlet_attribute_buffer.data[byte_off >> 2];
}

// Local-index (0-255) extraction from the uint32-packed uint8 triangle buffer

uint meshlet_triangle_local_index(uint global_byte_index) {
	uint word = meshlet_triangles.data[global_byte_index >> 2];
	return (word >> ((global_byte_index & 3u) * 8u)) & 0xFFu;
}

// Pull functions producing the same vec4/vec2 values the vertex_input attributes would deliver for the current format.

vec4 meshlet_pull_position(uint global_vidx) {
	uint fmt = meshlet_surface_info.format_flags_lo;
	uint off = meshlet_position_offset(global_vidx);
	if ((fmt & ARRAY_FLAG_USE_2D_VERTICES) != 0u) {
		float x = uintBitsToFloat(meshlet_vb_load_u32(off));
		float y = uintBitsToFloat(meshlet_vb_load_u32(off + 4u));
		return vec4(x, y, 0.0, 0.0);
	}
	if ((fmt & ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0u) {
		vec2 xy = unpackUnorm2x16(meshlet_vb_load_u32(off));
		vec2 zw = unpackUnorm2x16(meshlet_vb_load_u32(off + 4u));
		return vec4(xy, zw);
	}
	float x = uintBitsToFloat(meshlet_vb_load_u32(off));
	float y = uintBitsToFloat(meshlet_vb_load_u32(off + 4u));
	float z = uintBitsToFloat(meshlet_vb_load_u32(off + 8u));
	return vec4(x, y, z, 0.0);
}

vec4 meshlet_pull_normal_tangent(uint global_vidx) {
	uint fmt = meshlet_surface_info.format_flags_lo;
	if ((fmt & ARRAY_FORMAT_NORMAL) == 0u) {
		// Matches the Vulkan default for missing attribute components (0, 0, 0, 1).
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	uint off = meshlet_normal_tangent_offset(global_vidx);
	vec2 nxy = unpackUnorm2x16(meshlet_vb_load_u32(off));
	bool has_uncompressed_tangent = ((fmt & ARRAY_FORMAT_TANGENT) != 0u) && ((fmt & ARRAY_FLAG_COMPRESS_ATTRIBUTES) == 0u);
	if (has_uncompressed_tangent) {
		vec2 tzw = unpackUnorm2x16(meshlet_vb_load_u32(off + 4u));
		return vec4(nxy, tzw);
	}
	// Compressed or normal-only: leave zw as the driver default (0, 1) so
	// _unpack_vertex_attributes takes the compressed branch.
	return vec4(nxy, 0.0, 1.0);
}

vec4 meshlet_pull_color(uint global_vidx) {
	uint fmt = meshlet_surface_info.format_flags_lo;
	if ((fmt & ARRAY_FORMAT_COLOR) == 0u) {
		return vec4(1.0);
	}
	uint off = meshlet_attribute_record_offset(global_vidx) + meshlet_color_offset_in_record();
	return unpackUnorm4x8(meshlet_ab_load_u32(off));
}

vec2 meshlet_pull_uv(uint global_vidx) {
	uint fmt = meshlet_surface_info.format_flags_lo;
	if ((fmt & ARRAY_FORMAT_TEX_UV) == 0u) {
		return vec2(0.0);
	}
	uint off = meshlet_attribute_record_offset(global_vidx) + meshlet_uv_offset_in_record();
	if ((fmt & ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0u) {
		return unpackUnorm2x16(meshlet_ab_load_u32(off));
	}
	float u = uintBitsToFloat(meshlet_ab_load_u32(off));
	float v = uintBitsToFloat(meshlet_ab_load_u32(off + 4u));
	return vec2(u, v);
}

vec2 meshlet_pull_uv2(uint global_vidx) {
	uint fmt = meshlet_surface_info.format_flags_lo;
	if ((fmt & ARRAY_FORMAT_TEX_UV2) == 0u) {
		return vec2(0.0);
	}
	uint off = meshlet_attribute_record_offset(global_vidx) + meshlet_uv2_offset_in_record();
	if ((fmt & ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0u) {
		return unpackUnorm2x16(meshlet_ab_load_u32(off));
	}
	float u = uintBitsToFloat(meshlet_ab_load_u32(off));
	float v = uintBitsToFloat(meshlet_ab_load_u32(off + 4u));
	return vec2(u, v);
}

vec4 meshlet_pull_custom(uint slot, uint global_vidx) {
	uint fmt = meshlet_surface_info.format_flags_lo;
	if ((fmt & (ARRAY_FORMAT_CUSTOM0 << slot)) == 0u) {
		return vec4(0.0);
	}
	uint off = meshlet_attribute_record_offset(global_vidx) + meshlet_custom_offset_in_record(slot);
	uint cf = meshlet_custom_format(slot);
	if (cf == ARRAY_CUSTOM_RGBA8_UNORM) {
		return unpackUnorm4x8(meshlet_ab_load_u32(off));
	}
	if (cf == ARRAY_CUSTOM_RGBA8_SNORM) {
		return unpackSnorm4x8(meshlet_ab_load_u32(off));
	}
	if (cf == ARRAY_CUSTOM_RG_HALF) {
		vec2 v = unpackHalf2x16(meshlet_ab_load_u32(off));
		return vec4(v, 0.0, 0.0);
	}
	if (cf == ARRAY_CUSTOM_RGBA_HALF) {
		vec2 rg = unpackHalf2x16(meshlet_ab_load_u32(off));
		vec2 ba = unpackHalf2x16(meshlet_ab_load_u32(off + 4u));
		return vec4(rg, ba);
	}
	if (cf == ARRAY_CUSTOM_R_FLOAT) {
		return vec4(uintBitsToFloat(meshlet_ab_load_u32(off)), 0.0, 0.0, 0.0);
	}
	if (cf == ARRAY_CUSTOM_RG_FLOAT) {
		float x = uintBitsToFloat(meshlet_ab_load_u32(off));
		float y = uintBitsToFloat(meshlet_ab_load_u32(off + 4u));
		return vec4(x, y, 0.0, 0.0);
	}
	if (cf == ARRAY_CUSTOM_RGB_FLOAT) {
		float x = uintBitsToFloat(meshlet_ab_load_u32(off));
		float y = uintBitsToFloat(meshlet_ab_load_u32(off + 4u));
		float z = uintBitsToFloat(meshlet_ab_load_u32(off + 8u));
		return vec4(x, y, z, 0.0);
	}
	// ARRAY_CUSTOM_RGBA_FLOAT
	float x = uintBitsToFloat(meshlet_ab_load_u32(off));
	float y = uintBitsToFloat(meshlet_ab_load_u32(off + 4u));
	float z = uintBitsToFloat(meshlet_ab_load_u32(off + 8u));
	float w = uintBitsToFloat(meshlet_ab_load_u32(off + 12u));
	return vec4(x, y, z, w);
}
