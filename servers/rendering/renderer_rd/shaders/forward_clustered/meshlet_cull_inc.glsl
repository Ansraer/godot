#define MESHLET_SURFACE_SET 4
#define MAX_MESHLET_VERTICES 64
#define MAX_MESHLET_TRIANGLES 128
#define MAX_MESHLET_INDICES (MAX_MESHLET_TRIANGLES * 3)

// Must match RenderingServerTypes::Meshlet!
struct Meshlet {
	uint vertex_offset;
	uint triangle_offset;
	uint vertex_count;
	uint triangle_count;
	uint own_group_id;
	uint parent_group_id;
};

// Must match RenderingServerTypes::MeshletLodGroup!!
struct MeshletLodGroup {
	// sphere coords and error
	vec4 sphere;

	float error;
	float _pad0;
	float _pad1;
	float _pad2;
};

// Compact post culling output
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
}
meshlet_surface_info;

layout(set = MESHLET_SURFACE_SET, binding = 1, std430) restrict readonly buffer MeshletBuffer {
	Meshlet data[];
}
meshlets;

layout(set = MESHLET_SURFACE_SET, binding = 2, std430) restrict readonly buffer MeshletVerticesBuffer {
	uint data[];
}
meshlet_vertices;

// This currently is a uint32 array, while on the cpu side we upload uin8. WHEN ACCESSING THIS WE NEED TO PROBABLY EXTRACT THE DATA WE NEED!!!!
// TODO: look into using GL_EXT_shader_explicit_arithmetic_types_int8  and VK_KHR_8bit_storage instead
layout(set = MESHLET_SURFACE_SET, binding = 3, std430) restrict readonly buffer MeshletTrianglesBuffer {
	uint data[];
}
meshlet_triangles;

layout(set = MESHLET_SURFACE_SET, binding = 4, std430) restrict readonly buffer LodGroupBuffer {
	MeshletLodGroup data[];
}
lod_groups;
