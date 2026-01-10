#pragma once

#include "core/io/resource.h"
#include "scene/resources/material.h"

class MeshletMesh : public Resource {
	GDCLASS(MeshletMesh, Resource);

	Array _get_surfaces() const;
	void _set_surfaces(const Array &p_data);
	void _recompute_aabb();

private:
	struct Surface {
		int meshlet_count = 0;

		String name;
		AABB aabb;
		Ref<Material> material;
	};
	Vector<Surface> surfaces;
	RID mesh;
	AABB aabb;

protected:
	static void _bind_methods();
	virtual void reset_state() override;

public:
	void clear_cache() const;

	void surface_remove(int p_surface);
	void clear_surfaces();

	int get_surface_count() const;

	void surface_set_material(int p_idx, const Ref<Material> &p_material);
	Ref<Material> surface_get_material(int p_idx) const;

	int surface_find_by_name(const String &p_name) const;
	void surface_set_name(int p_idx, const String &p_name);
	String surface_get_name(int p_idx) const;

	AABB get_aabb() const;
};