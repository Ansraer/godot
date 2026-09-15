#define MESHLET_SURFACE_SET 4
#define MAX_MESHLET_VERTICES 64
#define MAX_MESHLET_TRIANGLES 128
#define MAX_MESHLET_INDICES (MAX_MESHLET_TRIANGLES * 3)

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
