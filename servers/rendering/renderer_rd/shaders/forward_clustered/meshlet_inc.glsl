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

struct DrawIndirectCommand {
	uint vertex_count;
	uint instance_count;
	uint first_vertex;
	uint first_instance;
};
