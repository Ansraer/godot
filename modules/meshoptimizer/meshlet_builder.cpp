/**************************************************************************/
/*  meshlet_builder.cpp                                                   */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "meshlet_builder.h"

#include <thirdparty/meshoptimizer/clusterlod.h>

namespace MeshletDAGBuilder {

bool build_meshlet_lod_dag(const float *p_vertex_pos, size_t p_vertex_count, size_t p_vertex_pos_stride, const float *p_vertex_attr, size_t p_vertex_attr_stride, size_t p_attr_count, const float *p_attr_weights, const uint32_t *p_indices, size_t p_index_count, uint32_t p_max_vertices, uint32_t p_max_triangles, SurfaceTool::MeshletBuilderOutput *r_out) {
	ERR_FAIL_NULL_V(r_out, false);
	ERR_FAIL_COND_V(p_index_count == 0 || p_vertex_count == 0, false);

	clodConfig cfg = clodDefaultConfig(p_max_triangles);
	cfg.max_vertices = p_max_vertices;

	clodMesh mesh = {};
	mesh.index_count = p_index_count;
	mesh.indices = p_indices;
	mesh.vertex_count = p_vertex_count;
	mesh.vertex_positions = p_vertex_pos;
	mesh.vertex_positions_stride = p_vertex_pos_stride;
	mesh.attribute_count = p_attr_count;
	mesh.vertex_attributes = p_vertex_attr;
	mesh.vertex_attributes_stride = p_vertex_attr_stride;
	mesh.attribute_weights = p_attr_weights;

	mesh.vertex_lock = nullptr;
	mesh.attribute_protect_mask = 0;

	struct Ctx {
		SurfaceTool::MeshletBuilderOutput *out;
		uint32_t max_vertices;
		uint32_t max_triangles;
	};
	Ctx ctx = { r_out, p_max_vertices, p_max_triangles };

	// This is called once per group in sequence and used by us to store the data in a format we need.
	// The returned int will be stored in the clusters "refined" variable -> use it to store the own group_id for later callbacks.
	auto output_callback = [](void *p_ctx, clodGroup p_group, const clodCluster *p_clusters, size_t p_count) -> int {
		Ctx *c = static_cast<Ctx *>(p_ctx);
		SurfaceTool::MeshletBuilderOutput &out = *c->out;

		// Store group info
		uint32_t group_id = (uint32_t)out.groups.size();
		SurfaceTool::MeshletGroup g;
		g.sphere_center[0] = p_group.simplified.center[0];
		g.sphere_center[1] = p_group.simplified.center[1];
		g.sphere_center[2] = p_group.simplified.center[2];
		g.sphere_radius = p_group.simplified.radius;
		g.error = p_group.simplified.error; // may be FLT_MAX for terminal (root) groups.
		out.groups.push_back(g);

		LocalVector<unsigned int> local_vertices;
		LocalVector<unsigned char> local_triangles;

		// TODO: check if we can avoid the resize and directly init this with the proper size
		local_vertices.resize(c->max_vertices); // upper bound
		local_triangles.resize(c->max_triangles * 3); // we will pad with degenerate triangles tol make drawing easier

		// Store all meshlets in this group
		for (size_t i = 0; i < p_count; i++) {
			const clodCluster &cl = p_clusters[i];
			if (cl.index_count == 0) {
				continue;
			}

			// fill vertex and index data
			size_t vcount = clodLocalIndices(local_vertices.ptr(), local_triangles.ptr(), cl.indices, cl.index_count);

			SurfaceTool::Meshlet meshlet;
			meshlet.vertex_offset = (uint32_t)out.meshlet_vertices.size();
			meshlet.triangle_offset = (uint32_t)out.meshlet_triangles.size();
			meshlet.vertex_count = (uint32_t)vcount;
			meshlet.triangle_count = (uint32_t)(cl.index_count / 3);
			// refined is the returned group_id from a prior callback
			meshlet.own_group_id = (cl.refined < 0) ? 0xFFFFFFFFu : (uint32_t)cl.refined;
			meshlet.parent_group_id = group_id;

			out.meshlets.push_back(meshlet);
			for (size_t v = 0; v < vcount; v++) {
				out.meshlet_vertices.push_back(local_vertices[v]);
			}
			for (size_t t = 0; t < c->max_triangles * 3; t++) {
				if (t < cl.index_count) {
					out.meshlet_triangles.push_back(local_triangles[t]);
				} else {
					// fill with degenerate triangles to amek sure all meshlets can be drawn with a fixed triangle count
					out.meshlet_triangles.push_back(0);
				}
			}
			// TODO: in theory we could add meslet bounds data to out here
		}

		return (int)group_id;
	};

	size_t total = clodBuild(cfg, mesh, &ctx, output_callback);
	return total > 0 && !r_out->meshlets.is_empty();
}

} //namespace MeshletDAGBuilder
