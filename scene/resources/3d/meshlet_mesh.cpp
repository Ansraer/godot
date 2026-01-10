#include "meshlet_mesh.h";

void MeshletMesh::clear_cache() const {
	triangle_mesh.unref();
	debug_lines.clear();
}

void MeshletMesh::_bind_methods() {
	// FIXME: add add surface function?
	ClassDB::bind_method(D_METHOD("surface_remove", "surf_idx"), &MeshletMesh::surface_remove);
	ClassDB::bind_method(D_METHOD("clear_surfaces"), &MeshletMesh::clear_surfaces);

	ClassDB::bind_method(D_METHOD("surface_set_material", "surf_idx", "material"), &MeshletMesh::surface_set_material);
	ClassDB::bind_method(D_METHOD("surface_get_material", "surf_idx"), &MeshletMesh::surface_get_material);
	ClassDB::bind_method(D_METHOD("surface_find_by_name", "name"), &MeshletMesh::surface_find_by_name);
	ClassDB::bind_method(D_METHOD("surface_set_name", "surf_idx", "name"), &MeshletMesh::surface_set_name);
	ClassDB::bind_method(D_METHOD("surface_get_name", "surf_idx"), &MeshletMesh::surface_get_name);

	ClassDB::bind_method(D_METHOD("_set_surfaces", "surfaces"), &MeshletMesh::_set_surfaces);
	ClassDB::bind_method(D_METHOD("_get_surfaces"), &MeshletMesh::_get_surfaces);

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "_surfaces", PROPERTY_HINT_NO_NODEPATH, "", PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_INTERNAL), "_set_surfaces", "_get_surfaces");
}

void MeshletMesh::reset_state() {
	clear_surfaces();

	aabb = AABB();
}

Array MeshletMesh::_get_surfaces() const {
	if (mesh.is_null()) {
		return Array();
	}

	// TODO: create an array of dicts containing all the remote information from the RenderingServer
}

void MeshletMesh::_set_surfaces(const Array &p_surfaces) {
	//TODO: load surface data from array of dictionary, update both the local information, the material and also the info in the rendering server
}

void MeshletMesh::_recompute_aabb() {
	// regenerate AABB
	aabb = AABB();

	for (int i = 0; i < surfaces.size(); i++) {
		if (i == 0) {
			aabb = surfaces[i].aabb;
		} else {
			aabb.merge_with(surfaces[i].aabb);
		}
	}
}

AABB MeshletMesh::get_aabb() const {
	return aabb;
}

void MeshletMesh::surface_remove(int p_surface) {
	ERR_FAIL_INDEX(p_surface, surfaces.size());
	// TODO: implement me
	RS::get_singleton()->meshlet_mesh_surface_remove(mesh, p_surface);
	surfaces.remove_at(p_surface);

	clear_cache();
	_recompute_aabb();
	notify_property_list_changed();
	emit_changed();
}

void MeshletMesh::clear_surfaces() {
	if (!mesh.is_valid()) {
		return;
	}

	// TODO: implement me
	RS::get_singleton()->meshlet_mesh_clear(mesh);
	surfaces.clear();
	aabb = AABB();
}

void MeshletMesh::surface_set_material(int p_idx, const Ref<Material> &p_material) {
	ERR_FAIL_INDEX(p_idx, surfaces.size());
	if (surfaces[p_idx].material == p_material) {
		return;
	}
	surfaces.write[p_idx].material = p_material;
	//TODO: implement me
	RenderingServer::get_singleton()->meshlet_mesh_surface_set_material(mesh, p_idx, p_material.is_null() ? RID() : p_material->get_rid());

	emit_changed();
}

Ref<Material> MeshletMesh::surface_get_material(int p_idx) const {
	Ref<Material> ret;
	GDVIRTUAL_CALL(_surface_get_material, p_idx, ret);
	return ret;
}

int MeshletMesh::surface_find_by_name(const String &p_name) const {
	for (int i = 0; i < surfaces.size(); i++) {
		if (surfaces[i].name == p_name) {
			return i;
		}
	}
	return -1;
}

void MeshletMesh::surface_set_name(int p_idx, const String &p_name) {
	ERR_FAIL_INDEX(p_idx, surfaces.size());

	surfaces.write[p_idx].name = p_name;
	emit_changed();
}

String MeshletMesh::surface_get_name(int p_idx) const {
	ERR_FAIL_INDEX_V(p_idx, surfaces.size(), String());
	return surfaces[p_idx].name;
}