/**************************************************************************/
/*  scene_shader_raytracing.cpp                                           */
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

#include "scene_shader_raytracing.h"

#include "core/config/project_settings.h"
#include "core/error/error_macros.h"
#include "core/io/dir_access.h"
#include "core/io/file_access.h"
#include "core/math/math_defs.h"
#include "core/os/os.h"
#include "servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h"
#include "servers/rendering/renderer_rd/renderer_compositor_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"

using namespace RendererSceneRenderImplementation;

static void _dump_failed_shader(const String &p_source, const String &p_label) {
	String tmp_dir = OS::get_singleton()->get_temp_path();
	String path = tmp_dir.path_join("rt_shader_" + p_label + ".glsl");
	Ref<FileAccess> f = FileAccess::open(path, FileAccess::WRITE);
	if (f.is_valid()) {
		f->store_string(p_source);
		WARN_PRINT("Dumped failed shader to: " + path);
	}
}

void SceneShaderRaytracing::ShaderData::set_code(const String &p_code) {
	code = p_code;

	if (raygen_version.is_null()) {
		MutexLock lock(SceneShaderRaytracing::singleton_mutex);
		raygen_version = SceneShaderRaytracing::singleton->raygen_shader.version_create();
	}

	blend_mode = BLEND_MODE_MIX;
	depth_draw = DEPTH_DRAW_OPAQUE;
	depth_test = DEPTH_TEST_ENABLED;
	cull_mode = CULL_BACK;
	alpha_antialiasing_mode = ALPHA_ANTIALIASING_OFF;

	uses_point_size = false;
	uses_alpha = false;
	uses_alpha_clip = false;
	uses_alpha_antialiasing = false;
	uses_blend_alpha = false;
	uses_depth_prepass_alpha = false;
	uses_discard = false;
	uses_roughness = false;
	uses_normal = false;
	uses_tangent = false;
	uses_normal_map = false;
	uses_vertex = false;
	uses_position = false;
	uses_sss = false;
	uses_transmittance = false;
	uses_time = false;
	uses_screen_texture = false;
	uses_screen_texture_mipmaps = false;
	uses_depth_texture = false;
	uses_normal_texture = false;
	uses_vertex_time = false;
	uses_fragment_time = false;
	writes_modelview_or_projection = false;
	uses_world_coordinates = false;
	uses_particle_trails = false;
	wireframe = false;
	unshaded = false;

	ubo_size = 0;
	uniforms.clear();
	ubo_offsets.clear();
	texture_uniforms.clear();
	_clear_vertex_input_mask_cache();
	pipeline_hash_map.clear_pipelines();
}

bool SceneShaderRaytracing::ShaderData::is_animated() const {
	return (uses_fragment_time && uses_discard) || (uses_vertex_time && uses_vertex);
}

bool SceneShaderRaytracing::ShaderData::casts_shadows() const {
	bool has_read_screen_alpha = uses_screen_texture || uses_depth_texture || uses_normal_texture;
	bool has_base_alpha = (uses_alpha && (!uses_alpha_clip || uses_alpha_antialiasing)) || has_read_screen_alpha;
	bool has_alpha = has_base_alpha || uses_blend_alpha;

	return !has_alpha || (uses_depth_prepass_alpha && !(depth_draw == DEPTH_DRAW_DISABLED || depth_test == DEPTH_TEST_DISABLED));
}

RenderingServerTypes::ShaderNativeSourceCode SceneShaderRaytracing::ShaderData::get_native_source_code() const {
	// For raytracing: return source code from raygen shader, not rasterization shader
	if (raygen_version.is_valid()) {
		MutexLock lock(SceneShaderRaytracing::singleton_mutex);
		return SceneShaderRaytracing::singleton->raygen_shader.version_get_native_source_code(raygen_version);
	} else {
		return RenderingServerTypes::ShaderNativeSourceCode();
	}
}

SceneShaderRaytracing::ShaderVersion SceneShaderRaytracing::ShaderData::_get_shader_version(PipelineVersion p_pipeline_version, uint32_t p_color_pass_flags, bool p_ubershader) const {
	// Simplified: we only have one shader version now (index 0)
	return ShaderVersion(0);
}

void SceneShaderRaytracing::ShaderData::_create_pipeline(PipelineKey p_pipeline_key) {
#if PRINT_PIPELINE_COMPILATION_KEYS
	print_line(
			"HASH:", p_pipeline_key.hash(),
			"VERSION:", version,
			"VERTEX:", p_pipeline_key.vertex_format_id,
			"FRAMEBUFFER:", p_pipeline_key.framebuffer_format_id,
			"CULL:", p_pipeline_key.cull_mode,
			"PRIMITIVE:", p_pipeline_key.primitive_type,
			"VERSION:", p_pipeline_key.version,
			"PASS FLAGS:", p_pipeline_key.color_pass_flags,
			"SPEC PACKED #0:", p_pipeline_key.shader_specialization.packed_0,
			"WIREFRAME:", p_pipeline_key.wireframe);
#endif

	// Simplified: just create a simple opaque color blend state
	RD::PipelineColorBlendState blend_state = RD::PipelineColorBlendState::create_disabled(1);

	RD::PipelineDepthStencilState depth_stencil_state;
	if (depth_test != DEPTH_TEST_DISABLED) {
		depth_stencil_state.enable_depth_test = true;
		depth_stencil_state.depth_compare_operator = RD::COMPARE_OP_GREATER_OR_EQUAL;
		depth_stencil_state.enable_depth_write = depth_draw != DEPTH_DRAW_DISABLED ? true : false;
	}

	RD::RenderPrimitive primitive_rd_table[RSE::PRIMITIVE_MAX] = {
		RD::RENDER_PRIMITIVE_POINTS,
		RD::RENDER_PRIMITIVE_LINES,
		RD::RENDER_PRIMITIVE_LINESTRIPS,
		RD::RENDER_PRIMITIVE_TRIANGLES,
		RD::RENDER_PRIMITIVE_TRIANGLE_STRIPS,
	};

	RD::RenderPrimitive primitive_rd = uses_point_size ? RD::RENDER_PRIMITIVE_POINTS : primitive_rd_table[p_pipeline_key.primitive_type];

	RD::PipelineRasterizationState raster_state;
	raster_state.cull_mode = p_pipeline_key.cull_mode;
	raster_state.wireframe = wireframe || p_pipeline_key.wireframe;

	RD::PipelineMultisampleState multisample_state;
	multisample_state.sample_count = RD::get_singleton()->framebuffer_format_get_texture_samples(p_pipeline_key.framebuffer_format_id, 0);

	// Simplified: no specialization constants
	Vector<RD::PipelineSpecializationConstant> specialization_constants;

	RID shader_rid = get_shader_variant(p_pipeline_key.version, p_pipeline_key.color_pass_flags, p_pipeline_key.ubershader);
	ERR_FAIL_COND(shader_rid.is_null());

	RID pipeline = RD::get_singleton()->render_pipeline_create(shader_rid, p_pipeline_key.framebuffer_format_id, p_pipeline_key.vertex_format_id, primitive_rd, raster_state, multisample_state, depth_stencil_state, blend_state, 0, 0, specialization_constants);
	ERR_FAIL_COND(pipeline.is_null());

	pipeline_hash_map.add_compiled_pipeline(p_pipeline_key.hash(), pipeline);
}

RD::PolygonCullMode SceneShaderRaytracing::ShaderData::get_cull_mode_from_cull_variant(CullVariant p_cull_variant) {
	const RD::PolygonCullMode cull_mode_rd_table[CULL_VARIANT_MAX][3] = {
		{ RD::POLYGON_CULL_DISABLED, RD::POLYGON_CULL_FRONT, RD::POLYGON_CULL_BACK },
		{ RD::POLYGON_CULL_DISABLED, RD::POLYGON_CULL_BACK, RD::POLYGON_CULL_FRONT },
		{ RD::POLYGON_CULL_DISABLED, RD::POLYGON_CULL_DISABLED, RD::POLYGON_CULL_DISABLED }
	};

	return cull_mode_rd_table[p_cull_variant][cull_mode];
}

RID SceneShaderRaytracing::ShaderData::_get_shader_variant(ShaderVersion p_shader_version) const {
	// For raytracing, we don't use rasterization shaders - return invalid RID
	// The raygen shader is accessed via get_raygen_shader_variant() instead
	return RID();
}

void SceneShaderRaytracing::ShaderData::_clear_vertex_input_mask_cache() {
	for (uint32_t i = 0; i < VERTEX_INPUT_MASKS_SIZE; i++) {
		vertex_input_masks[i].store(0);
	}
}

RID SceneShaderRaytracing::ShaderData::get_shader_variant(PipelineVersion p_pipeline_version, uint32_t p_color_pass_flags, bool p_ubershader) const {
	return _get_shader_variant(_get_shader_version(p_pipeline_version, p_color_pass_flags, p_ubershader));
}

RID SceneShaderRaytracing::ShaderData::get_raygen_shader_variant() const {
	if (raygen_version.is_valid()) {
		MutexLock lock(SceneShaderRaytracing::singleton_mutex);
		ERR_FAIL_NULL_V(SceneShaderRaytracing::singleton, RID());
		return SceneShaderRaytracing::singleton->raygen_shader.version_get_shader(raygen_version, 0);
	} else {
		return RID();
	}
}

uint64_t SceneShaderRaytracing::ShaderData::get_vertex_input_mask(PipelineVersion p_pipeline_version, uint32_t p_color_pass_flags, bool p_ubershader) {
	// Vertex input masks require knowledge of the shader. Since querying the shader can be expensive due to high contention and the necessary mutex, we cache the result instead.
	ShaderVersion shader_version = _get_shader_version(p_pipeline_version, p_color_pass_flags, p_ubershader);
	uint64_t input_mask = vertex_input_masks[shader_version].load(std::memory_order_relaxed);
	if (input_mask == 0) {
		RID shader_rid = _get_shader_variant(shader_version);
		ERR_FAIL_COND_V(shader_rid.is_null(), 0);

		input_mask = RD::get_singleton()->shader_get_vertex_input_attribute_mask(shader_rid);
		vertex_input_masks[shader_version].store(input_mask, std::memory_order_relaxed);
	}

	return input_mask;
}

bool SceneShaderRaytracing::ShaderData::is_valid() const {
	// For raytracing: check raygen shader validity, not rasterization shader
	if (raygen_version.is_valid()) {
		MutexLock lock(SceneShaderRaytracing::singleton_mutex);
		ERR_FAIL_NULL_V(SceneShaderRaytracing::singleton, false);
		return SceneShaderRaytracing::singleton->raygen_shader.version_is_valid(raygen_version);
	} else {
		return false;
	}
}

SceneShaderRaytracing::ShaderData::ShaderData() :
		shader_list_element(this) {
	pipeline_hash_map.set_creation_object_and_function(this, &ShaderData::_create_pipeline);
	pipeline_hash_map.set_compilations(SceneShaderRaytracing::singleton->pipeline_compilations, &SceneShaderRaytracing::singleton_mutex);
}

SceneShaderRaytracing::ShaderData::~ShaderData() {
	pipeline_hash_map.clear_pipelines();

	// For raytracing: only free raygen_version, not the rasterization shader version
	if (raygen_version.is_valid()) {
		MutexLock lock(SceneShaderRaytracing::singleton_mutex);
		ERR_FAIL_NULL(SceneShaderRaytracing::singleton);
		SceneShaderRaytracing::singleton->raygen_shader.version_free(raygen_version);
	}
}

Pair<ShaderRD *, RID> SceneShaderRaytracing::ShaderData::get_native_shader_and_version() const {
	MutexLock lock(SceneShaderRaytracing::singleton_mutex);
	if (SceneShaderRaytracing::singleton == nullptr) {
		return Pair<ShaderRD *, RID>(nullptr, RID());
	}
	// For raytracing: return raygen shader instead of rasterization shader
	return Pair<ShaderRD *, RID>(&SceneShaderRaytracing::singleton->raygen_shader, raygen_version);
}

RendererRD::MaterialStorage::ShaderData *SceneShaderRaytracing::_create_shader_func() {
	MutexLock lock(SceneShaderRaytracing::singleton_mutex);
	ShaderData *shader_data = memnew(ShaderData);
	singleton->shader_list.add(&shader_data->shader_list_element);
	return shader_data;
}

void SceneShaderRaytracing::MaterialData::set_render_priority(int p_priority) {
	priority = p_priority - RSE::MATERIAL_RENDER_PRIORITY_MIN; //8 bits
}

void SceneShaderRaytracing::MaterialData::set_next_pass(RID p_pass) {
	next_pass = p_pass;
}

bool SceneShaderRaytracing::MaterialData::update_parameters(const HashMap<StringName, Variant> &p_parameters, bool p_uniform_dirty, bool p_textures_dirty) {
	// For raytracing: We don't use material uniform sets with the rasterization pipeline
	// Material parameters for RT would be handled differently (e.g., via shader binding table)
	// For now, just return true to indicate parameters were "processed"
	return true;
}

SceneShaderRaytracing::MaterialData::~MaterialData() {
	free_parameters_uniform_set(uniform_set);
}

RendererRD::MaterialStorage::MaterialData *SceneShaderRaytracing::_create_material_func(ShaderData *p_shader) {
	MaterialData *material_data = memnew(MaterialData);
	material_data->shader_data = p_shader;
	return material_data;
}

SceneShaderRaytracing *SceneShaderRaytracing::singleton = nullptr;
Mutex SceneShaderRaytracing::singleton_mutex;

SceneShaderRaytracing::SceneShaderRaytracing() {
	// There should be only one of these, contained within our RenderForwardClustered singleton.
	singleton = this;
}

SceneShaderRaytracing::~SceneShaderRaytracing() {
	invalidate_pipeline_bundles();

	if (raygen_shader_version.is_valid()) {
		raygen_shader.version_free(raygen_shader_version);
	}

	singleton = nullptr;
}

void SceneShaderRaytracing::invalidate_pipeline_bundles() {
	for (KeyValue<uint32_t, PipelineBundle> &kv : pipeline_bundles) {
		PipelineBundle &b = kv.value;
		if (b.hit_sbt.is_valid()) {
			RD::get_singleton()->free_rid(b.hit_sbt);
		}
		if (b.pipeline.is_valid()) {
			RD::get_singleton()->free_rid(b.pipeline);
		}
		for (const RID &rid : b.owned_shaders) {
			if (rid.is_valid()) {
				RD::get_singleton()->free_rid(rid);
			}
		}
	}
	pipeline_bundles.clear();
}

void SceneShaderRaytracing::begin_custom_shader_frame() {
	frame_custom_shaders.clear();
	frame_shader_id_to_hg.clear();
}

uint32_t SceneShaderRaytracing::register_custom_shader(uint32_t p_shader_id, RID p_material) {
	HashMap<uint32_t, uint32_t>::Iterator it = frame_shader_id_to_hg.find(p_shader_id);
	if (it != frame_shader_id_to_hg.end()) {
		return it->value;
	}

	RendererRD::MaterialStorage *material_storage = RendererRD::MaterialStorage::get_singleton();
	String code = material_storage->material_get_shader_code(p_material);
	if (code.is_empty()) {
		// ShaderMaterial without a Shader, silently fall back to default material
		frame_shader_id_to_hg[p_shader_id] = 0;
		return 0;
	}
	uint64_t code_hash = code.hash64();

	HashMap<uint32_t, CustomShaderEntry>::Iterator cache_it = compilation_cache.find(p_shader_id);
	if (cache_it == compilation_cache.end() || cache_it->value.source_hash != code_hash) {
		ShaderCompiler::IdentifierActions actions;
		actions.entry_point_stages["vertex"] = ShaderCompiler::STAGE_VERTEX;
		actions.entry_point_stages["fragment"] = ShaderCompiler::STAGE_FRAGMENT;

		bool detected_alpha_clip = false;
		actions.usage_flag_pointers["ALPHA_SCISSOR_THRESHOLD"] = &detected_alpha_clip;
		actions.usage_flag_pointers["ALPHA_HASH_SCALE"] = &detected_alpha_clip;

		HashMap<StringName, ShaderLanguage::ShaderNode::Uniform> uniform_sink;
		actions.uniforms = &uniform_sink;

		ShaderCompiler::GeneratedCode gen_code;
		Error err = compiler.compile(RSE::SHADER_SPATIAL, code, &actions, String(), gen_code);

		CustomShaderEntry entry;
		entry.source_hash = code_hash;
		entry.uses_alpha_clip = detected_alpha_clip;
		if (err == OK) {
			entry.vertex_code = gen_code.code.has("vertex") ? gen_code.code["vertex"] : String();
			entry.fragment_code = gen_code.code.has("fragment") ? gen_code.code["fragment"] : String();
			entry.fragment_globals = gen_code.stage_globals[ShaderCompiler::STAGE_FRAGMENT];
			entry.uniform_members = gen_code.uniforms;
			entry.uniform_total_size = gen_code.uniform_total_size;
			entry.uniform_offsets = gen_code.uniform_offsets;
			entry.uniforms = uniform_sink;

			// Compute raw (unrounded) end of the last uniform member.
			// ShaderCompiler rounds uniform_total_size to 16 bytes for UBO requirements,
			// but our buffer_reference struct uses std140 member layout without UBO-level padding.
			uint32_t raw_uniform_end = 0;
			for (const KeyValue<StringName, ShaderLanguage::ShaderNode::Uniform> &kv : uniform_sink) {
				const ShaderLanguage::ShaderNode::Uniform &uu = kv.value;
				if (ShaderLanguage::is_sampler_type(uu.type) || uu.order < 0 || uu.order >= (int)gen_code.uniform_offsets.size()) {
					continue;
				}
				uint32_t end = gen_code.uniform_offsets[uu.order] + ShaderLanguage::get_datatype_size(uu.type);
				if (end > raw_uniform_end) {
					raw_uniform_end = end;
				}
			}

			for (int ti = 0; ti < gen_code.texture_uniforms.size(); ti++) {
				const ShaderCompiler::GeneratedCode::Texture &tex = gen_code.texture_uniforms[ti];
				if (tex.name.is_empty()) {
					continue;
				}

				// Strip the texture2D declaration from fragment_globals.
				String decl_marker = " m_" + tex.name + ";";
				int pos = entry.fragment_globals.find(decl_marker);
				if (pos >= 0) {
					int line_start = entry.fragment_globals.rfind("\n", pos);
					line_start = (line_start < 0) ? 0 : line_start + 1;
					int line_end = entry.fragment_globals.find("\n", pos);
					if (line_end < 0) {
						line_end = entry.fragment_globals.length();
					} else {
						line_end += 1;
					}
					entry.fragment_globals = entry.fragment_globals.substr(0, line_start) + entry.fragment_globals.substr(line_end);
				}

				// Append uint member to the uniform buffer struct (stores bindless index).
				uint32_t offset = raw_uniform_end;
				if (offset % 4 != 0) {
					offset += 4 - (offset % 4);
				}

				TextureUniformInfo tui;
				tui.name = tex.name;
				tui.hint = tex.hint;
				tui.use_color = tex.use_color;
				tui.is_global = tex.global;
				tui.buffer_offset = offset;
				entry.texture_uniforms.push_back(tui);

				entry.uniform_members += "uint m_" + tex.name + ";\n";
				raw_uniform_end = offset + 4;
			}

			entry.uniform_total_size = raw_uniform_end;
			if (entry.uniform_total_size % 16 != 0) {
				entry.uniform_total_size += 16 - (entry.uniform_total_size % 16);
			}

		} else {
			WARN_PRINT("RT: Failed to compile custom shader (shader_id=" + itos(p_shader_id) + "). Falling back to standard material.");
			if (cache_it != compilation_cache.end()) {
				cache_it->value.source_hash = 0;
			}
			frame_shader_id_to_hg[p_shader_id] = 0;
			return 0;
		}

		if (cache_it != compilation_cache.end()) {
			cache_it->value = entry;
		} else {
			cache_it = compilation_cache.insert(p_shader_id, entry);
		}
	}

	if (cache_it->value.fragment_code.is_empty() && cache_it->value.vertex_code.is_empty()) {
		frame_shader_id_to_hg[p_shader_id] = 0;
		return 0;
	}

	uint32_t hg_index = frame_custom_shaders.size() + 1;
	frame_custom_shaders.push_back(cache_it->value);
	frame_shader_id_to_hg[p_shader_id] = hg_index;
	return hg_index;
}

uint32_t SceneShaderRaytracing::register_procedural_shader(uint32_t p_shader_id, RID p_material) {
	HashMap<uint32_t, uint32_t>::Iterator it = frame_shader_id_to_hg.find(p_shader_id);
	if (it != frame_shader_id_to_hg.end()) {
		return it->value;
	}

	RendererRD::MaterialStorage *material_storage = RendererRD::MaterialStorage::get_singleton();
	String code = material_storage->material_get_shader_code(p_material);
	uint64_t code_hash = code.hash64();

	HashMap<uint32_t, CustomShaderEntry>::Iterator cache_it = compilation_cache.find(p_shader_id);
	if (cache_it == compilation_cache.end() || cache_it->value.source_hash != code_hash) {
		ShaderCompiler::IdentifierActions actions;
		actions.entry_point_stages["vertex"] = ShaderCompiler::STAGE_VERTEX;
		actions.entry_point_stages["fragment"] = ShaderCompiler::STAGE_FRAGMENT;
		actions.entry_point_stages["light"] = ShaderCompiler::STAGE_FRAGMENT;
		actions.entry_point_stages["intersection"] = ShaderCompiler::STAGE_INTERSECTION;

		bool detected_alpha_clip = false;
		actions.usage_flag_pointers["ALPHA_SCISSOR_THRESHOLD"] = &detected_alpha_clip;
		actions.usage_flag_pointers["ALPHA_HASH_SCALE"] = &detected_alpha_clip;

		HashMap<StringName, ShaderLanguage::ShaderNode::Uniform> uniform_sink;
		actions.uniforms = &uniform_sink;

		ShaderCompiler::GeneratedCode gen_code;
		Error err = compiler.compile(RSE::SHADER_SPATIAL, code, &actions, String(), gen_code);

		CustomShaderEntry entry;
		entry.source_hash = code_hash;
		entry.is_procedural = true;
		entry.uses_alpha_clip = detected_alpha_clip;
		if (err == OK) {
			entry.intersection_code = gen_code.code.has("intersection") ? gen_code.code["intersection"] : String();
			entry.intersection_globals = gen_code.stage_globals[ShaderCompiler::STAGE_INTERSECTION];
			entry.fragment_code = gen_code.code.has("fragment") ? gen_code.code["fragment"] : String();
			entry.fragment_globals = gen_code.stage_globals[ShaderCompiler::STAGE_FRAGMENT];
			entry.uniform_members = gen_code.uniforms;
			entry.uniform_total_size = gen_code.uniform_total_size;
			entry.uniform_offsets = gen_code.uniform_offsets;
			entry.uniforms = uniform_sink;

			// Compute raw (unrounded) end of the last uniform member.
			uint32_t raw_uniform_end = 0;
			for (const KeyValue<StringName, ShaderLanguage::ShaderNode::Uniform> &kv : uniform_sink) {
				const ShaderLanguage::ShaderNode::Uniform &uu = kv.value;
				if (ShaderLanguage::is_sampler_type(uu.type) || uu.order < 0 || uu.order >= (int)gen_code.uniform_offsets.size()) {
					continue;
				}
				uint32_t end = gen_code.uniform_offsets[uu.order] + ShaderLanguage::get_datatype_size(uu.type);
				if (end > raw_uniform_end) {
					raw_uniform_end = end;
				}
			}

			for (int ti = 0; ti < gen_code.texture_uniforms.size(); ti++) {
				const ShaderCompiler::GeneratedCode::Texture &tex = gen_code.texture_uniforms[ti];
				if (tex.name.is_empty()) {
					continue;
				}

				// Strip texture declarations from both globals.
				String decl_marker = " m_" + tex.name + ";";
				for (String *globals : { &entry.intersection_globals, &entry.fragment_globals }) {
					int pos = globals->find(decl_marker);
					if (pos >= 0) {
						int line_start = globals->rfind("\n", pos);
						line_start = (line_start < 0) ? 0 : line_start + 1;
						int line_end = globals->find("\n", pos);
						if (line_end < 0) {
							line_end = globals->length();
						} else {
							line_end += 1;
						}
						*globals = globals->substr(0, line_start) + globals->substr(line_end);
					}
				}

				uint32_t offset = raw_uniform_end;
				if (offset % 4 != 0) {
					offset += 4 - (offset % 4);
				}

				TextureUniformInfo tui;
				tui.name = tex.name;
				tui.hint = tex.hint;
				tui.use_color = tex.use_color;
				tui.buffer_offset = offset;
				entry.texture_uniforms.push_back(tui);

				entry.uniform_members += "uint m_" + tex.name + ";\n";
				raw_uniform_end = offset + 4;
			}

			entry.uniform_total_size = raw_uniform_end;
			if (entry.uniform_total_size % 16 != 0) {
				entry.uniform_total_size += 16 - (entry.uniform_total_size % 16);
			}
		} else {
			WARN_PRINT_ONCE("RT: Failed to compile procedural shader (shader_id=" + itos(p_shader_id) + "). Skipping.");
			// Cache the failure with the real hash so we don't retry every frame.
			entry.intersection_code = String();
			if (cache_it != compilation_cache.end()) {
				cache_it->value = entry;
			} else {
				compilation_cache.insert(p_shader_id, entry);
			}
			frame_shader_id_to_hg[p_shader_id] = 0;
			return 0;
		}

		if (cache_it != compilation_cache.end()) {
			cache_it->value = entry;
		} else {
			cache_it = compilation_cache.insert(p_shader_id, entry);
		}
	}

	if (cache_it->value.intersection_code.is_empty()) {
		frame_shader_id_to_hg[p_shader_id] = 0;
		return 0;
	}

	uint32_t hg_index = frame_custom_shaders.size() + 1;
	frame_custom_shaders.push_back(cache_it->value);
	frame_shader_id_to_hg[p_shader_id] = hg_index;
	return hg_index;
}

void SceneShaderRaytracing::finalize_custom_shaders() {
	bool any_procedural = false;
	uint64_t new_hash = 0;
	for (uint32_t i = 0; i < frame_custom_shaders.size(); i++) {
		new_hash = hash_djb2_one_64(frame_custom_shaders[i].vertex_code.hash64(), new_hash);
		new_hash = hash_djb2_one_64(frame_custom_shaders[i].fragment_code.hash64(), new_hash);
		new_hash = hash_djb2_one_64(frame_custom_shaders[i].fragment_globals.hash64(), new_hash);
		new_hash = hash_djb2_one_64(frame_custom_shaders[i].uniform_members.hash64(), new_hash);
		new_hash = hash_djb2_one_64(frame_custom_shaders[i].uses_alpha_clip ? 1 : 0, new_hash);
		new_hash = hash_djb2_one_64(frame_custom_shaders[i].intersection_code.hash64(), new_hash);
		new_hash = hash_djb2_one_64(frame_custom_shaders[i].intersection_globals.hash64(), new_hash);
		new_hash = hash_djb2_one_64(frame_custom_shaders[i].is_procedural ? 1 : 0, new_hash);
		any_procedural = any_procedural || frame_custom_shaders[i].is_procedural;
	}

	if (any_procedural != has_intersection_shaders) {
		has_intersection_shaders = any_procedural;
	}

	if (new_hash != active_custom_shaders_hash || frame_custom_shaders.size() != active_custom_shaders.size()) {
		active_custom_shaders = frame_custom_shaders;
		active_custom_shaders_hash = new_hash;
		invalidate_pipeline_bundles();
	}
}

const SceneShaderRaytracing::CustomShaderEntry *SceneShaderRaytracing::get_custom_shader_entry(uint32_t p_hg_index) const {
	if (p_hg_index == 0 || p_hg_index > frame_custom_shaders.size()) {
		return nullptr;
	}
	return &frame_custom_shaders[p_hg_index - 1];
}

uint32_t SceneShaderRaytracing::compute_rt_flags(const float *p_env_params, bool p_fog_enabled) {
	uint32_t flags = RT_FLAG_NONE;
	uint32_t sample_count = 1;
	uint32_t max_bounces = 3;

	if (p_env_params) {
		if (p_env_params[RT_PARAM_VIS_MODE] != 0.0f) {
			flags |= RT_FLAG_DEBUG_VIS_ENABLED;
		}
		sample_count = MAX(1u, (uint32_t)p_env_params[RT_PARAM_SAMPLE_COUNT]);
		max_bounces = MAX(1u, MIN(8u, (uint32_t)p_env_params[RT_PARAM_MAX_BOUNCES]));
		if ((uint32_t)p_env_params[RT_PARAM_DENOISER] == RSE::PT_DENOISER_DLSS_RAY_RECONSTRUCTION) {
			flags |= RT_FLAG_DLSS_RR_ENABLED;
		}
	}

	if (p_fog_enabled) {
		flags |= RT_FLAG_FOG_ENABLED;
	}

	if (GLOBAL_GET("rendering/pathtracer/use_shader_execution_reordering")) {
		flags |= RT_FLAG_SER_ENABLED;
	}

	return rt_flags_pack(flags, sample_count, max_bounces);
}

SceneShaderRaytracing *SceneShaderRaytracing::get_singleton() {
	if (singleton == nullptr) {
		MutexLock lock(SceneShaderRaytracing::singleton_mutex);
		if (singleton == nullptr) {
			memnew(SceneShaderRaytracing);
		}
	}
	return singleton;
}

const SceneShaderRaytracing::PipelineBundle &SceneShaderRaytracing::ensure_pipeline_bundle(uint32_t p_rt_flags) {
	static const PipelineBundle EMPTY_BUNDLE;

	HashMap<uint32_t, PipelineBundle>::Iterator it = pipeline_bundles.find(p_rt_flags);
	if (it != pipeline_bundles.end()) {
		return it->value;
	}

	ERR_FAIL_COND_V(!raygen_shader_version.is_valid(), EMPTY_BUNDLE);

	int dlss_bit = (p_rt_flags & RT_FLAG_DLSS_RR_ENABLED) ? 1 : 0;
	int ser_bit = (p_rt_flags & RT_FLAG_SER_ENABLED) ? 1 : 0;
	int variant = ser_bit * 2 + dlss_bit;

	Vector<String> sources = raygen_shader.version_build_variant_stage_sources(raygen_shader_version, variant);
	ERR_FAIL_COND_V(sources.is_empty(), EMPTY_BUNDLE);

	// Procedural instances need full HitAttribs (normal/tangent).
	if (has_intersection_shaders) {
		static const String is_define = "#define ENABLE_INTERSECTION_SHADERS\n";
		for (int i = 0; i < sources.size(); i++) {
			if (sources[i].is_empty()) {
				continue;
			}
			int ver_pos = sources[i].find("#version");
			if (ver_pos >= 0) {
				int nl = sources[i].find("\n", ver_pos);
				if (nl >= 0) {
					sources.write[i] = sources[i].insert(nl + 1, is_define);
				}
			}
		}
	}

	// Save intersection source as template for procedural HGs; clear it from
	// the base so HG0 stays a triangle hit group.
	String intersection_source_template;
	if (sources.size() > RD::SHADER_STAGE_INTERSECTION) {
		intersection_source_template = sources[RD::SHADER_STAGE_INTERSECTION];
		sources.write[RD::SHADER_STAGE_INTERSECTION] = String();
	}

	Vector<RD::ShaderStageSPIRVData> base_stages = ShaderRD::compile_stages(sources, {});
	ERR_FAIL_COND_V(base_stages.is_empty(), EMPTY_BUNDLE);

	Vector<RD::PipelineSpecializationConstant> spec_constants;
	{
		RD::PipelineSpecializationConstant sc;
		sc.constant_id = 0;
		sc.type = RD::PIPELINE_SPECIALIZATION_CONSTANT_TYPE_INT;
		sc.int_value = p_rt_flags;
		spec_constants.push_back(sc);
	}

	// Build a single combined shader from all base RT stages so they share one descriptor layout.
	Vector<uint8_t> base_binary = RD::get_singleton()->shader_compile_binary_from_spirv(base_stages, "RT_base");
	ERR_FAIL_COND_V(base_binary.is_empty(), EMPTY_BUNDLE);

	RID base_shader_rd = RD::get_singleton()->shader_create_from_bytecode(base_binary);
	ERR_FAIL_COND_V(!base_shader_rd.is_valid(), EMPTY_BUNDLE);

	PipelineBundle bundle;
	bundle.base_shader = base_shader_rd;
	bundle.owned_shaders.push_back(base_shader_rd);

	RD::PipelineShader base_ps = { base_shader_rd, spec_constants };

	// HG0 = default material hit group.
	LocalVector<RD::HitGroup> hit_groups;
	{
		RD::HitGroup hg0;
		hg0.closest_hit_shader = base_ps;
		hg0.any_hit_shader = base_ps;
		hit_groups.push_back(hg0);
	}

	// Custom shader hit groups (HG1..HGN).
	if (!active_custom_shaders.is_empty()) {
		String base_ch_src = sources[RD::SHADER_STAGE_CLOSEST_HIT];
		String base_ah_src = sources[RD::SHADER_STAGE_ANY_HIT];
		ERR_FAIL_COND_V(base_ch_src.is_empty(), EMPTY_BUNDLE);
		ERR_FAIL_COND_V(base_ah_src.is_empty(), EMPTY_BUNDLE);

		// Collect base raygen + miss SPIRV so custom HG binaries include all stages.
		// Without this, the custom shader's set_formats won't match (different stages bits).
		Vector<RD::ShaderStageSPIRVData> base_non_hit_stages;
		for (const RD::ShaderStageSPIRVData &sd : base_stages) {
			if (sd.shader_stage == RD::SHADER_STAGE_RAYGEN || sd.shader_stage == RD::SHADER_STAGE_MISS) {
				base_non_hit_stages.push_back(sd);
			}
		}

		static const String custom_hg_define = "#define RT_CUSTOM_HIT_GROUP\n";
		int base_ch_ver = base_ch_src.find("#version");
		int base_ah_ver = base_ah_src.find("#version");
		ERR_FAIL_COND_V(base_ch_ver < 0 || base_ah_ver < 0, EMPTY_BUNDLE);

		String ch_template = base_ch_src.insert(base_ch_src.find("\n", base_ch_ver) + 1, custom_hg_define);
		String ah_template = base_ah_src.insert(base_ah_src.find("\n", base_ah_ver) + 1, custom_hg_define);

		RD::HitGroup hg0_fallback;
		hg0_fallback.closest_hit_shader = base_ps;
		hg0_fallback.any_hit_shader = base_ps;

		// Prepare intersection source template for procedural HGs.
		String is_template;
		if (!intersection_source_template.is_empty()) {
			int base_is_ver = intersection_source_template.find("#version");
			if (base_is_ver >= 0) {
				is_template = intersection_source_template.insert(intersection_source_template.find("\n", base_is_ver) + 1, custom_hg_define);
			}
		}

		String error;
		for (uint32_t hg_i = 0; hg_i < active_custom_shaders.size(); hg_i++) {
			const CustomShaderEntry &entry = active_custom_shaders[hg_i];

			String tex_defines;
			for (int ti = 0; ti < entry.texture_uniforms.size(); ti++) {
				const TextureUniformInfo &tui = entry.texture_uniforms[ti];
				tex_defines += "#define m_" + tui.name + " bindless_textures[nonuniformEXT(material.m_" + tui.name + ")]\n";
			}
			String uniform_members = entry.uniform_members.is_empty() ? "float _rt_pad;" : entry.uniform_members;

			String vertex_function;
			String vertex_call;
			if (!entry.vertex_code.is_empty()) {
				vertex_function = "void rt_run_vertex_shader() {\n" + entry.vertex_code + "\n}\n";
				vertex_call = "rt_run_vertex_shader();";
			}

			// Procedural without custom fragment: fall back to standard material eval.
			String fragment_code = entry.fragment_code;
			if (fragment_code.is_empty() && entry.is_procedural) {
				fragment_code =
						"vec2 mat_uv = uv_interp * rt_mat.uv1_scale + rt_mat.uv1_offset;\n"
						"vec4 albedo_tex = sample_material_texture(rt_mat.albedo_texture_idx, mat_uv, rt_mat.flags);\n"
						"albedo = albedo_tex.rgb * rt_mat.albedo_color.rgb;\n"
						"alpha = albedo_tex.a * rt_mat.albedo_color.a;\n"
						"vec3 orm = sample_material_texture(rt_mat.orm_texture_idx, mat_uv, rt_mat.flags).rgb;\n"
						"roughness = orm.g * rt_mat.roughness;\n"
						"metallic = orm.b * rt_mat.metallic;\n"
						"if ((rt_mat.flags & 1u) != 0u) {\n"
						"    normal_map = sample_material_texture(rt_mat.normal_texture_idx, mat_uv, rt_mat.flags).rgb;\n"
						"    normal_map_depth = rt_mat.normal_map_depth;\n"
						"}\n"
						"if ((rt_mat.flags & 2u) != 0u) {\n"
						"    emission = sample_material_texture(rt_mat.emission_texture_idx, mat_uv, rt_mat.flags).rgb\n"
						"             * rt_mat.emission_color * rt_mat.emission_strength;\n"
						"}\n";
			}

			String ch_src = ch_template;
			ch_src = ch_src.replace("/* RT_CUSTOM_FRAGMENT_GLOBALS */", entry.fragment_globals);
			ch_src = ch_src.replace("/* RT_CUSTOM_FRAGMENT_CODE */", fragment_code);
			ch_src = ch_src.replace("/* RT_CUSTOM_UNIFORM_MEMBERS */", uniform_members);
			ch_src = ch_src.replace("/* RT_CUSTOM_TEXTURE_DEFINES */", tex_defines);
			ch_src = ch_src.replace("/* RT_CUSTOM_VERTEX_FUNCTION */", vertex_function);
			ch_src = ch_src.replace("/* RT_CUSTOM_VERTEX_CALL */", vertex_call);

			Vector<uint8_t> ch_spirv = RD::get_singleton()->shader_compile_spirv_from_source(
					RD::SHADER_STAGE_CLOSEST_HIT, ch_src, RD::SHADER_LANGUAGE_GLSL, &error);
			if (ch_spirv.is_empty()) {
				WARN_PRINT("Failed to compile HG" + itos(hg_i + 1) + " closest_hit, falling back to default material: " + error);
				_dump_failed_shader(ch_src, "hg" + itos(hg_i + 1) + "_closest_hit");
				hit_groups.push_back(hg0_fallback);
				continue;
			}

			// Include base raygen + miss so per-HG shader matches base `stages` bits.
			Vector<RD::ShaderStageSPIRVData> custom_stages = base_non_hit_stages;
			{
				RD::ShaderStageSPIRVData sd;
				sd.shader_stage = RD::SHADER_STAGE_CLOSEST_HIT;
				sd.spirv = ch_spirv;
				custom_stages.push_back(sd);
			}

			if (entry.uses_alpha_clip) {
				String ah_src = ah_template;
				ah_src = ah_src.replace("/* RT_CUSTOM_FRAGMENT_GLOBALS */", entry.fragment_globals);
				ah_src = ah_src.replace("/* RT_CUSTOM_FRAGMENT_CODE */", fragment_code);
				ah_src = ah_src.replace("/* RT_CUSTOM_UNIFORM_MEMBERS */", uniform_members);
				ah_src = ah_src.replace("/* RT_CUSTOM_TEXTURE_DEFINES */", tex_defines);
				ah_src = ah_src.replace("/* RT_CUSTOM_VERTEX_FUNCTION */", vertex_function);
				ah_src = ah_src.replace("/* RT_CUSTOM_VERTEX_CALL */", vertex_call);

				Vector<uint8_t> ah_spirv = RD::get_singleton()->shader_compile_spirv_from_source(
						RD::SHADER_STAGE_ANY_HIT, ah_src, RD::SHADER_LANGUAGE_GLSL, &error);
				if (ah_spirv.is_empty()) {
					WARN_PRINT("Failed to compile HG" + itos(hg_i + 1) + " any_hit, falling back to default material: " + error);
					_dump_failed_shader(ah_src, "hg" + itos(hg_i + 1) + "_any_hit");
					hit_groups.push_back(hg0_fallback);
					continue;
				}

				RD::ShaderStageSPIRVData sd;
				sd.shader_stage = RD::SHADER_STAGE_ANY_HIT;
				sd.spirv = ah_spirv;
				custom_stages.push_back(sd);
			} else {
				// Include base any_hit SPIRV for consistent stage reflection.
				for (const RD::ShaderStageSPIRVData &sd : base_stages) {
					if (sd.shader_stage == RD::SHADER_STAGE_ANY_HIT) {
						custom_stages.push_back(sd);
						break;
					}
				}
			}

			// Procedural HG: add intersection stage. Driver auto-promotes to PROCEDURAL_HIT_GROUP.
			if (entry.is_procedural && !is_template.is_empty()) {
				String is_src = is_template;
				is_src = is_src.replace("/* RT_CUSTOM_INTERSECTION_GLOBALS */", entry.intersection_globals);
				is_src = is_src.replace("/* RT_CUSTOM_INTERSECTION_CODE */", entry.intersection_code);
				is_src = is_src.replace("/* RT_CUSTOM_UNIFORM_MEMBERS */", uniform_members);
				is_src = is_src.replace("/* RT_CUSTOM_TEXTURE_DEFINES */", tex_defines);

				Vector<uint8_t> is_spirv = RD::get_singleton()->shader_compile_spirv_from_source(
						RD::SHADER_STAGE_INTERSECTION, is_src, RD::SHADER_LANGUAGE_GLSL, &error);
				if (is_spirv.is_empty()) {
					WARN_PRINT("Failed to compile HG" + itos(hg_i + 1) + " intersection, falling back to default material: " + error);
					_dump_failed_shader(is_src, "hg" + itos(hg_i + 1) + "_intersection");
					hit_groups.push_back(hg0_fallback);
					continue;
				}

				RD::ShaderStageSPIRVData sd;
				sd.shader_stage = RD::SHADER_STAGE_INTERSECTION;
				sd.spirv = is_spirv;
				custom_stages.push_back(sd);
			}

			Vector<uint8_t> custom_binary = RD::get_singleton()->shader_compile_binary_from_spirv(
					custom_stages, "RT_hg" + itos(hg_i + 1));
			if (custom_binary.is_empty()) {
				WARN_PRINT("Failed to compile HG" + itos(hg_i + 1) + " binary, falling back to default material.");
				hit_groups.push_back(hg0_fallback);
				continue;
			}

			RID custom_shader_rd = RD::get_singleton()->shader_create_from_bytecode(custom_binary);
			if (!custom_shader_rd.is_valid()) {
				WARN_PRINT("Failed to create HG" + itos(hg_i + 1) + " shader, falling back to default material.");
				hit_groups.push_back(hg0_fallback);
				continue;
			}
			bundle.owned_shaders.push_back(custom_shader_rd);

			RD::PipelineShader custom_ps = { custom_shader_rd, spec_constants };

			RD::HitGroup hg;
			hg.closest_hit_shader = custom_ps;
			if (entry.uses_alpha_clip) {
				hg.any_hit_shader = custom_ps;
			}
			if (entry.is_procedural && !is_template.is_empty()) {
				hg.intersection_shader = custom_ps;
			}

			hit_groups.push_back(hg);
		}
	}

	bundle.pipeline = RD::get_singleton()->raytracing_pipeline_create(
			{ &base_ps, 1 },
			{ &base_ps, 1 },
			{ hit_groups.ptr(), (uint64_t)hit_groups.size() },
			RT_MAX_RECURSION_DEPTH);
	ERR_FAIL_COND_V(bundle.pipeline.is_null(), EMPTY_BUNDLE);
	RD::get_singleton()->set_resource_name(bundle.pipeline, String("RT Pipeline [flags=") + itos(p_rt_flags) + "]");

	// Pre-allocate a large identity-mapped hit SBT.
	static constexpr uint32_t HIT_SBT_CAPACITY = 4096;
	uint32_t hg_count = hit_groups.size();
	uint32_t sbt_size = MAX(hg_count, HIT_SBT_CAPACITY);

	bundle.hit_sbt = RD::get_singleton()->hit_sbt_create(bundle.pipeline, sbt_size);
	ERR_FAIL_COND_V(bundle.hit_sbt.is_null(), EMPTY_BUNDLE);
	RD::get_singleton()->set_resource_name(bundle.hit_sbt, String("RT Hit SBT [flags=") + itos(p_rt_flags) + "]");

	RD::HitShaderBindingTableRange sbt_range = RD::get_singleton()->hit_sbt_range_alloc(bundle.hit_sbt, sbt_size);
	ERR_FAIL_COND_V(!sbt_range, EMPTY_BUNDLE);

	// Identity SBT: slot i -> HG i, past-end -> HG 0.
	LocalVector<uint32_t> indices;
	indices.resize(sbt_size);
	for (uint32_t i = 0; i < sbt_size; i++) {
		indices[i] = (i < hg_count) ? i : 0;
	}
	RD::get_singleton()->hit_sbt_range_update(bundle.hit_sbt, sbt_range, 0, indices);

	return pipeline_bundles.insert(p_rt_flags, bundle)->value;
}

void SceneShaderRaytracing::init(const String p_defines) {
	// For raytracing: The raygen shader has embedded code via setup_raytracing() in its constructor
	// setup_raytracing() set pipeline_type = RAYTRACING, so initialize() will use raytracing stages
	// Shader variants (compiled on-demand):
	// Variant 0: Base
	// Variant 1: DLSS RR
	// Variant 2: SER
	// Variant 3: SER + DLSS RR
	// TODO: Remove SER variants once SER benchmarking is complete, keep them always enabled.
	Vector<String> modes;
	modes.push_back("\n");
	modes.push_back("\n#define DLSS_RR_ENABLED\n");
	modes.push_back("\n#define USE_SER\n");
	modes.push_back("\n#define DLSS_RR_ENABLED\n#define USE_SER\n");
	raygen_shader.initialize(modes, p_defines);

	// Now create a version to access the embedded raytracing shader
	raygen_shader_version = raygen_shader.version_create();
	if (raygen_shader_version.is_valid()) {
		// Eagerly build the default pipeline bundle so first-frame doesn't stall.
		const PipelineBundle &b = ensure_pipeline_bundle(RT_FLAG_NONE);
		if (!b.pipeline.is_valid()) {
			WARN_PRINT("Failed to create default raytracing pipeline bundle");
		}
	} else {
		WARN_PRINT("Failed to create raytracing shader version");
	}

	{
		// Shader compiler (not used for RT, but needed for compatibility).
		ShaderCompiler::DefaultIdentifierActions actions;

		actions.renames["MODEL_MATRIX"] = "read_model_matrix";
		actions.renames["MODEL_NORMAL_MATRIX"] = "model_normal_matrix";
		actions.renames["VIEW_MATRIX"] = "read_view_matrix";
		actions.renames["INV_VIEW_MATRIX"] = "inv_view_matrix";
		actions.renames["PROJECTION_MATRIX"] = "projection_matrix";
		actions.renames["INV_PROJECTION_MATRIX"] = "inv_projection_matrix";
		actions.renames["MODELVIEW_MATRIX"] = "(read_view_matrix * read_model_matrix)";
		actions.renames["MODELVIEW_NORMAL_MATRIX"] = "mat3(read_view_matrix * read_model_matrix)";
		actions.renames["MAIN_CAM_INV_VIEW_MATRIX"] = "inv_view_matrix";

		actions.renames["VERTEX"] = "vertex";
		actions.renames["NORMAL"] = "normal";
		actions.renames["TANGENT"] = "tangent";
		actions.renames["BINORMAL"] = "binormal";
		actions.renames["POSITION"] = "position";
		actions.renames["UV"] = "uv_interp";
		actions.renames["UV2"] = "uv2_interp";
		actions.renames["COLOR"] = "color_interp";
		actions.renames["POINT_SIZE"] = "rt_point_size";
		actions.renames["INSTANCE_ID"] = "rt_instance_id";
		actions.renames["VERTEX_ID"] = "rt_vertex_id";

		actions.renames["ALPHA_SCISSOR_THRESHOLD"] = "alpha_scissor_threshold";
		actions.renames["ALPHA_HASH_SCALE"] = "alpha_hash_scale";
		actions.renames["ALPHA_ANTIALIASING_EDGE"] = "alpha_antialiasing_edge";
		actions.renames["ALPHA_TEXTURE_COORDINATE"] = "alpha_texture_coordinate";

		// Builtins.

		actions.renames["TIME"] = "global_time";
		actions.renames["PREV_TIME"] = "global_prev_time";
		actions.renames["EXPOSURE"] = "(1.0 / scene_data_block.data.emissive_exposure_normalization)";
		actions.renames["PI"] = String::num(Math::PI);
		actions.renames["TAU"] = String::num(Math::TAU);
		actions.renames["E"] = String::num(Math::E);
		actions.renames["OUTPUT_IS_SRGB"] = "SHADER_IS_SRGB";
		actions.renames["CLIP_SPACE_FAR"] = "SHADER_SPACE_FAR";
		actions.renames["VIEWPORT_SIZE"] = "read_viewport_size";

		actions.renames["FRAGCOORD"] = "rt_frag_coord";
		actions.renames["FRONT_FACING"] = "rt_front_facing";
		actions.renames["NORMAL_MAP"] = "normal_map";
		actions.renames["NORMAL_MAP_DEPTH"] = "normal_map_depth";
		actions.renames["ALBEDO"] = "albedo";
		actions.renames["ALPHA"] = "alpha";
		actions.renames["PREMUL_ALPHA_FACTOR"] = "premul_alpha";
		actions.renames["METALLIC"] = "metallic";
		actions.renames["SPECULAR"] = "specular";
		actions.renames["ROUGHNESS"] = "roughness";
		actions.renames["RIM"] = "rim";
		actions.renames["RIM_TINT"] = "rim_tint";
		actions.renames["CLEARCOAT"] = "clearcoat";
		actions.renames["CLEARCOAT_ROUGHNESS"] = "clearcoat_roughness";
		actions.renames["ANISOTROPY"] = "anisotropy";
		actions.renames["ANISOTROPY_FLOW"] = "anisotropy_flow";
		actions.renames["SSS_STRENGTH"] = "sss_strength";
		actions.renames["SSS_TRANSMITTANCE_COLOR"] = "transmittance_color";
		actions.renames["SSS_TRANSMITTANCE_DEPTH"] = "transmittance_depth";
		actions.renames["SSS_TRANSMITTANCE_BOOST"] = "transmittance_boost";
		actions.renames["BACKLIGHT"] = "backlight";
		actions.renames["AO"] = "ao";
		actions.renames["AO_LIGHT_AFFECT"] = "ao_light_affect";
		actions.renames["EMISSION"] = "emission";
		actions.renames["POINT_COORD"] = "rt_point_coord";
		actions.renames["INSTANCE_CUSTOM"] = "instance_custom";
		actions.renames["SCREEN_UV"] = "rt_screen_uv";
		actions.renames["DEPTH"] = "rt_depth";
		actions.renames["FOG"] = "fog";
		actions.renames["RADIANCE"] = "custom_radiance";
		actions.renames["IRRADIANCE"] = "custom_irradiance";
		actions.renames["BONE_INDICES"] = "bone_attrib";
		actions.renames["BONE_WEIGHTS"] = "weight_attrib";
		actions.renames["CUSTOM0"] = "custom0_attrib";
		actions.renames["CUSTOM1"] = "custom1_attrib";
		actions.renames["CUSTOM2"] = "custom2_attrib";
		actions.renames["CUSTOM3"] = "custom3_attrib";
		actions.renames["LIGHT_VERTEX"] = "light_vertex";

		actions.renames["NODE_POSITION_WORLD"] = "read_model_matrix[3].xyz";
		actions.renames["CAMERA_POSITION_WORLD"] = "inv_view_matrix[3].xyz";
		actions.renames["CAMERA_DIRECTION_WORLD"] = "inv_view_matrix[2].xyz";
		actions.renames["CAMERA_VISIBLE_LAYERS"] = "scene_data_block.data.camera_visible_layers";
		actions.renames["NODE_POSITION_VIEW"] = "(read_view_matrix * read_model_matrix)[3].xyz";

		actions.renames["VIEW_INDEX"] = "ViewIndex";
		actions.renames["VIEW_MONO_LEFT"] = "0";
		actions.renames["VIEW_RIGHT"] = "1";
		actions.renames["EYE_OFFSET"] = "eye_offset";

		// For light.
		actions.renames["VIEW"] = "view";
		actions.renames["SPECULAR_AMOUNT"] = "specular_amount";
		actions.renames["LIGHT_COLOR"] = "light_color";
		actions.renames["LIGHT_IS_DIRECTIONAL"] = "is_directional";
		actions.renames["LIGHT"] = "light";
		actions.renames["ATTENUATION"] = "attenuation";
		actions.renames["DIFFUSE_LIGHT"] = "diffuse_light";
		actions.renames["SPECULAR_LIGHT"] = "specular_light";

		actions.usage_defines["NORMAL"] = "#define NORMAL_USED\n";
		actions.usage_defines["TANGENT"] = "#define TANGENT_USED\n";
		actions.usage_defines["BINORMAL"] = "@TANGENT";
		actions.usage_defines["RIM"] = "#define LIGHT_RIM_USED\n";
		actions.usage_defines["RIM_TINT"] = "@RIM";
		actions.usage_defines["CLEARCOAT"] = "#define LIGHT_CLEARCOAT_USED\n";
		actions.usage_defines["CLEARCOAT_ROUGHNESS"] = "@CLEARCOAT";
		actions.usage_defines["ANISOTROPY"] = "#define LIGHT_ANISOTROPY_USED\n";
		actions.usage_defines["ANISOTROPY_FLOW"] = "@ANISOTROPY";
		actions.usage_defines["AO"] = "#define AO_USED\n";
		actions.usage_defines["AO_LIGHT_AFFECT"] = "#define AO_USED\n";
		actions.usage_defines["UV"] = "#define UV_USED\n";
		actions.usage_defines["UV2"] = "#define UV2_USED\n";
		actions.usage_defines["BONE_INDICES"] = "#define BONES_USED\n";
		actions.usage_defines["BONE_WEIGHTS"] = "#define WEIGHTS_USED\n";
		actions.usage_defines["CUSTOM0"] = "#define CUSTOM0_USED\n";
		actions.usage_defines["CUSTOM1"] = "#define CUSTOM1_USED\n";
		actions.usage_defines["CUSTOM2"] = "#define CUSTOM2_USED\n";
		actions.usage_defines["CUSTOM3"] = "#define CUSTOM3_USED\n";
		actions.usage_defines["NORMAL_MAP"] = "#define NORMAL_MAP_USED\n";
		actions.usage_defines["NORMAL_MAP_DEPTH"] = "@NORMAL_MAP";
		actions.usage_defines["COLOR"] = "#define COLOR_USED\n";
		actions.usage_defines["INSTANCE_CUSTOM"] = "#define ENABLE_INSTANCE_CUSTOM\n";
		actions.usage_defines["POSITION"] = "#define OVERRIDE_POSITION\n";
		actions.usage_defines["LIGHT_VERTEX"] = "#define LIGHT_VERTEX_USED\n";
		actions.usage_defines["PREMUL_ALPHA_FACTOR"] = "#define PREMUL_ALPHA_USED\n";

		actions.usage_defines["ALPHA_SCISSOR_THRESHOLD"] = "#define ALPHA_SCISSOR_USED\n";
		actions.usage_defines["ALPHA_HASH_SCALE"] = "#define ALPHA_HASH_USED\n";
		actions.usage_defines["ALPHA_ANTIALIASING_EDGE"] = "#define ALPHA_ANTIALIASING_EDGE_USED\n";
		actions.usage_defines["ALPHA_TEXTURE_COORDINATE"] = "@ALPHA_ANTIALIASING_EDGE";

		actions.usage_defines["SSS_STRENGTH"] = "#define ENABLE_SSS\n";
		actions.usage_defines["SSS_TRANSMITTANCE_DEPTH"] = "#define ENABLE_TRANSMITTANCE\n";
		actions.usage_defines["BACKLIGHT"] = "#define LIGHT_BACKLIGHT_USED\n";
		actions.usage_defines["SCREEN_UV"] = "#define SCREEN_UV_USED\n";

		actions.usage_defines["FOG"] = "#define CUSTOM_FOG_USED\n";
		actions.usage_defines["RADIANCE"] = "#define CUSTOM_RADIANCE_USED\n";
		actions.usage_defines["IRRADIANCE"] = "#define CUSTOM_IRRADIANCE_USED\n";

		actions.usage_defines["MODEL_MATRIX"] = "#define MODEL_MATRIX_USED\n";

		actions.render_mode_defines["skip_vertex_transform"] = "#define SKIP_TRANSFORM_USED\n";
		actions.render_mode_defines["world_vertex_coords"] = "#define VERTEX_WORLD_COORDS_USED\n";
		actions.render_mode_defines["ensure_correct_normals"] = "#define ENSURE_CORRECT_NORMALS\n";
		actions.render_mode_defines["cull_front"] = "#define DO_SIDE_CHECK\n";
		actions.render_mode_defines["cull_disabled"] = "#define DO_SIDE_CHECK\n";
		actions.render_mode_defines["particle_trails"] = "#define USE_PARTICLE_TRAILS\n";
		actions.render_mode_defines["depth_prepass_alpha"] = "#define USE_OPAQUE_PREPASS\n";

		bool force_lambert = GLOBAL_GET("rendering/shading/overrides/force_lambert_over_burley");

		if (!force_lambert) {
			actions.render_mode_defines["diffuse_burley"] = "#define DIFFUSE_BURLEY\n";
		}

		actions.render_mode_defines["diffuse_lambert_wrap"] = "#define DIFFUSE_LAMBERT_WRAP\n";
		actions.render_mode_defines["diffuse_toon"] = "#define DIFFUSE_TOON\n";

		actions.render_mode_defines["sss_mode_skin"] = "#define SSS_MODE_SKIN\n";

		actions.render_mode_defines["specular_schlick_ggx"] = "#define SPECULAR_SCHLICK_GGX\n";

		actions.render_mode_defines["specular_toon"] = "#define SPECULAR_TOON\n";
		actions.render_mode_defines["specular_disabled"] = "#define SPECULAR_DISABLED\n";
		actions.render_mode_defines["shadows_disabled"] = "#define SHADOWS_DISABLED\n";
		actions.render_mode_defines["ambient_light_disabled"] = "#define AMBIENT_LIGHT_DISABLED\n";
		actions.render_mode_defines["shadow_to_opacity"] = "#define USE_SHADOW_TO_OPACITY\n";
		actions.render_mode_defines["unshaded"] = "#define MODE_UNSHADED\n";

		bool force_vertex_shading = GLOBAL_GET("rendering/shading/overrides/force_vertex_shading");
		if (!force_vertex_shading) {
			// If forcing vertex shading, this will be defined already.
			actions.render_mode_defines["vertex_lighting"] = "#define USE_VERTEX_LIGHTING\n";
		}

		actions.render_mode_defines["debug_shadow_splits"] = "#define DEBUG_DRAW_PSSM_SPLITS\n";
		actions.render_mode_defines["fog_disabled"] = "#define FOG_DISABLED\n";

		actions.base_texture_binding_index = 1;
		actions.texture_layout_set = RenderForwardClustered::MATERIAL_UNIFORM_SET;
		actions.base_uniform_string = "material.";
		actions.base_varying_index = 14;
		actions.suppress_varying_io = true;

		actions.default_filter = ShaderLanguage::FILTER_LINEAR_MIPMAP;
		actions.default_repeat = ShaderLanguage::REPEAT_ENABLE;
		actions.global_buffer_array_variable = "global_shader_uniforms.data";
		actions.instance_uniform_index_variable = "instances.data[instance_index_interp].instance_uniforms_ofs";

		actions.check_multiview_samplers = RendererCompositorRD::get_singleton()->is_xr_enabled(); // Make sure we check sampling multiview textures.

		// Intersection stage built-in renames (must match locals in the GLSL template).
		actions.renames["ORIGIN"] = "m_ORIGIN";
		actions.renames["DIRECTION"] = "m_DIRECTION";
		actions.renames["WORLD_ORIGIN"] = "m_WORLD_ORIGIN";
		actions.renames["WORLD_DIRECTION"] = "m_WORLD_DIRECTION";
		actions.renames["T_MIN"] = "m_T_MIN";
		actions.renames["T_MAX"] = "m_T_MAX";
		actions.renames["HIT_UV"] = "m_HIT_UV";
		actions.renames["HIT_NORMAL"] = "m_HIT_NORMAL";
		actions.renames["HIT_TANGENT"] = "m_HIT_TANGENT";
		actions.renames["PREV_POSITION"] = "m_PREV_POSITION";
		actions.renames["AABB_MIN"] = "m_AABB_MIN";
		actions.renames["AABB_MAX"] = "m_AABB_MAX";

		// Stage function rename: bypass _mkid prefix to match the GLSL macro.
		actions.renames["report_intersection"] = "report_intersection";

		compiler.initialize(actions);
	}

	// For raytracing: we don't use the material system at all
	// Materials, shaders, and variants are all skipped - we use the fixed raygen shader created above
	// Set these to invalid/null for safety
	default_shader = RID();
	default_material = RID();
	default_shader_rd = RID();
	default_shader_sdfgi_rd = RID();
	default_material_shader_ptr = nullptr;
	default_material_uniform_set = RID();

	// Overdraw and debug materials are not used in raytracing mode
	overdraw_material_shader = RID();
	overdraw_material = RID();
	overdraw_material_shader_ptr = nullptr;
	overdraw_material_uniform_set = RID();

	debug_shadow_splits_material_shader = RID();
	debug_shadow_splits_material = RID();
	debug_shadow_splits_material_shader_ptr = nullptr;
	debug_shadow_splits_material_uniform_set = RID();

	// Default vec4 xform buffer and shadow sampler are not used in raytracing mode
	default_vec4_xform_buffer = RID();
	default_vec4_xform_uniform_set = RID();
	shadow_sampler = RID();
}

void SceneShaderRaytracing::set_default_specialization(const ShaderSpecialization &p_specialization) {
	default_specialization = p_specialization;

	for (SelfList<ShaderData> *E = shader_list.first(); E; E = E->next()) {
		E->self()->pipeline_hash_map.clear_pipelines();
	}
}

void SceneShaderRaytracing::enable_advanced_shader_group(bool p_needs_multiview) {
	// For raytracing: we don't use shader groups, no-op
}

bool SceneShaderRaytracing::is_multiview_shader_group_enabled() const {
	// For raytracing: we don't use shader groups
	return false;
}

bool SceneShaderRaytracing::is_advanced_shader_group_enabled(bool p_multiview) const {
	// For raytracing: we don't use shader groups
	return false;
}

uint32_t SceneShaderRaytracing::get_pipeline_compilations(RSE::PipelineSource p_source) {
	MutexLock lock(SceneShaderRaytracing::singleton_mutex);
	return pipeline_compilations[p_source];
}
