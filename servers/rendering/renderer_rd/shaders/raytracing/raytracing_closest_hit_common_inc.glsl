// Common closest_hit utilities shared by all hit groups.
//
// Required includes (before this file):
//   raytracing_inc.glsl, brdf_inc.glsl, raytracing_hit_inc.glsl, raytracing_lights_inc.glsl,
//   raytracing_material_eval_inc.glsl
//
// Required bindings (before this file):
//   tlas, payload, scene_data_block, geometries[], motion_indices[], materials[], motion_transforms[], bindless_textures[],
//   SAMPLER_* (12 material samplers), rt_params, rt_depth_image,
//   DLSS-RR images (ifdef DLSS_RR_ENABLED)

// ============================================================================
// HIT DATA
// ============================================================================

struct HitData {
	vec3 hit_pos;
	vec3 geometry_normal; // World space, flipped for back-face hits.
	vec3 tangent; // World space.
	vec3 bitangent; // World space.
	vec2 uv; // Raw UV (no material scale/offset applied).
	vec4 color; // Vertex color (white if not present).
	bool is_front_face;
	uint geometry_idx;
};

/// Fetch vertex attributes and transform to world space.
/// Requires hitAttributeEXT HitAttribs and GeometryBuffer/MaterialBuffer bindings.
HitData compute_hit_data() {
	HitData h;
	h.geometry_idx = gl_InstanceCustomIndexEXT;
	GeometryData geom = geometries[h.geometry_idx];

	// Custom hit groups may reference vertex color in their fragment code, so
	// pull all attributes; default HGs can skip color for perf.
#ifdef RT_CUSTOM_HIT_GROUP
	VertexAttributes attrs = fetch_vertex_attributes(geom, attribs, FETCH_ALL);
#else
	VertexAttributes attrs = fetch_vertex_attributes(geom, attribs, FETCH_UV | FETCH_TBN);
#endif
	h.uv = attrs.uv;
	h.color = attrs.color;

	mat3 model_rotation = mat3(gl_ObjectToWorldEXT);
	mat3 normal_matrix = mat3(
			normalize(model_rotation[0]),
			normalize(model_rotation[1]),
			normalize(model_rotation[2]));

#ifdef ENABLE_INTERSECTION_SHADERS
	if ((geom.flags & FLAG_PROCEDURAL) != 0u) {
		h.uv = hit_attribs.bary_or_uv;
		vec3 obj_normal = normalize(unpackSnorm4x8(hit_attribs.packed_normal).xyz);
		vec3 obj_tangent = normalize(unpackSnorm4x8(hit_attribs.packed_tangent).xyz);
		h.geometry_normal = normalize(normal_matrix * obj_normal);
		h.tangent = normalize(normal_matrix * obj_tangent);
		h.bitangent = cross(h.geometry_normal, h.tangent);

		h.is_front_face = (dot(h.geometry_normal, -gl_WorldRayDirectionEXT) > 0.0);
		if (!h.is_front_face) {
			h.geometry_normal = -h.geometry_normal;
		}
	} else
#endif
	{
		// Triangle hit: reuse `attrs` from the top-level fetch (already has
		// UV / TBN from FETCH_UV | FETCH_TBN or FETCH_ALL).
		h.geometry_normal = normalize(normal_matrix * attrs.normal);
		h.tangent = normalize(normal_matrix * attrs.tangent);
		h.bitangent = cross(h.geometry_normal, h.tangent) * attrs.bitangent_sign;

		h.is_front_face = (gl_HitKindEXT == gl_HitKindFrontFacingTriangleEXT);
		if (!h.is_front_face) {
			h.geometry_normal = -h.geometry_normal;
		}
	}

	h.hit_pos = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * gl_HitTEXT;

	return h;
}

// ============================================================================
// HELPERS
// ============================================================================

vec4 sample_bindless_texture(uint tex_idx, vec2 uv) {
	return texture(sampler2D(bindless_textures[nonuniformEXT(tex_idx)], SAMPLER_LINEAR_WITH_MIPMAPS_REPEAT), uv);
}

/// Sample with point/nearest filtering (for pixel art textures).
vec4 sample_bindless_texture_point(uint tex_idx, vec2 uv) {
	return texture(sampler2D(bindless_textures[nonuniformEXT(tex_idx)], SAMPLER_NEAREST_REPEAT), uv);
}

/// Sample with the appropriate filter based on material flags (bit 2 = point filtering).
vec4 sample_material_texture(uint tex_idx, vec2 uv, uint mat_flags) {
	if ((mat_flags & 4u) != 0u) {
		return sample_bindless_texture_point(tex_idx, uv);
	}
	return sample_bindless_texture(tex_idx, uv);
}

/// Apply tangent-space normal map to geometry normal.
vec3 apply_normal_map(HitData h, vec3 tangent_space_normal, float normal_map_depth) {
	vec3 mapped = h.tangent * tangent_space_normal.x + h.bitangent * tangent_space_normal.y + h.geometry_normal * tangent_space_normal.z;
	return normalize(mix(h.geometry_normal, mapped, normal_map_depth));
}

// ============================================================================
// DEPTH WRITE (primary ray only)
// ============================================================================

/// Write NDC depth for primary ray hits (bounce 0, sample 0 only).
void write_primary_hit_depth(vec3 hit_pos) {
	if (get_total_bounces(payload.packed_bounces_flags) == 0u && is_sample_zero(payload.packed_bounces_flags)) {
		mat4 view_mat = transpose(mat4(scene_data_block.data.view_matrix[0],
				scene_data_block.data.view_matrix[1],
				scene_data_block.data.view_matrix[2],
				vec4(0.0, 0.0, 0.0, 1.0)));
		vec3 view_pos = (view_mat * vec4(hit_pos, 1.0)).xyz;
		vec4 clip_pos = scene_data_block.data.projection_matrix * vec4(view_pos, 1.0);
		float ndc_depth = clip_pos.z / clip_pos.w;
		imageStore(rt_depth_image, ivec2(gl_LaunchIDEXT.xy), vec4(ndc_depth));
	}
}

// ============================================================================
// VELOCITY WRITE (primary ray only, MV-gated)
// ============================================================================

#ifdef ENABLE_INTERSECTION_SHADERS
/// Decode the FP16-compressed PREV_POSITION delta from HitAttribs.
vec3 decode_prev_pos_delta() {
	uint dx_low = (hit_attribs.packed_normal >> 24u) & 0xFFu;
	uint dx_high = (hit_attribs.packed_tangent >> 24u) & 0xFFu;
	float delta_x = unpackHalf2x16(dx_low | (dx_high << 8u)).x;
	vec2 delta_yz = unpackHalf2x16(hit_attribs.prev_pos_delta_yz);
	return vec3(delta_x, delta_yz.x, delta_yz.y);
}
#endif

/// Reconstruct previous-frame mat4 from a compact motion transform entry.
mat4 decode_prev_object_to_world(int motion_idx) {
	InstanceMotionData m = motion_transforms[motion_idx];
	return transpose(mat4(
			vec4(m.prev_xform[0], m.prev_xform[1], m.prev_xform[2], m.prev_xform[3]),
			vec4(m.prev_xform[4], m.prev_xform[5], m.prev_xform[6], m.prev_xform[7]),
			vec4(m.prev_xform[8], m.prev_xform[9], m.prev_xform[10], m.prev_xform[11]),
			vec4(0.0, 0.0, 0.0, 1.0)));
}

/// Write motion vectors for primary ray hits (bounce 0, sample 0 only).
/// Uses unjittered VP matrices matching the raster motion_vectors_store convention.
void write_primary_hit_velocity(vec3 hit_pos) {
	if (get_total_bounces(payload.packed_bounces_flags) != 0u || !is_sample_zero(payload.packed_bounces_flags)) {
		return;
	}

	uint geom_idx = gl_InstanceCustomIndexEXT;
	int mi = motion_indices[geom_idx];

	// Resolve previous-frame model matrix: compact entry if moved, current transform otherwise.
	mat4 prev_model = (mi >= 0) ? decode_prev_object_to_world(mi) : mat4(gl_ObjectToWorldEXT);

	vec3 obj_pos = (mat4(gl_WorldToObjectEXT) * vec4(hit_pos, 1.0)).xyz;
	vec3 prev_obj_pos = obj_pos;

#ifdef ENABLE_INTERSECTION_SHADERS
	GeometryData geom = geometries[geom_idx];
	if ((geom.flags & FLAG_PROCEDURAL) != 0u) {
		prev_obj_pos += decode_prev_pos_delta();
	}
#endif

	vec3 prev_world_pos = (prev_model * vec4(prev_obj_pos, 1.0)).xyz;

	vec2 curr_uv = project_uv(hit_pos, curr_vp_unjittered);
	vec2 prev_uv = project_uv(prev_world_pos, prev_vp_unjittered);

	imageStore(rt_velocity_image, ivec2(gl_LaunchIDEXT.xy), vec4(prev_uv - curr_uv, 0.0, 0.0));
}

// ============================================================================
// ENVIRONMENT FOG (per ray segment)
// ============================================================================

vec3 fog_get_directional_color(uint index) {
	return rt_lights[index].emission;
}

vec3 fog_get_directional_direction(uint index) {
	vec3 world_dir = -normalize(rt_lights[index].position);
	mat3 view_rot = transpose(mat3(
			scene_data_block.data.view_matrix[0].xyz,
			scene_data_block.data.view_matrix[1].xyz,
			scene_data_block.data.view_matrix[2].xyz));
	return view_rot * world_dir;
}

#define FOG_HAS_RADIANCE

vec3 fog_sample_radiance(vec3 vertex, float mip_level) {
	vec3 cube_view = scene_data_block.data.radiance_inverse_xform * vertex;
	float roughness_lod = mip_level * MAX_ROUGHNESS_LOD;
	vec2 border = vec2(scene_data_block.data.radiance_border_size,
			1.0 - scene_data_block.data.radiance_border_size * 2.0);
	vec2 cube_uv = vec3_to_oct_with_border(cube_view, border);
	return textureLod(sampler2D(radiance_octmap, radiance_sampler), cube_uv, roughness_lod).rgb;
}

#include "../fog_inc.glsl"

/// Apply environment fog for the ray segment that was just traversed.
/// Attenuates throughput and adds in-scattered fog color.
void apply_segment_fog(float segment_dist, inout vec3 radiance, inout vec3 throughput) {
	if ((RT_FLAGS & RT_FLAG_FOG_ENABLED) == 0u) {
		return;
	}

	// Build a view-space vertex along the ray direction at the hit distance.
	// fog_process needs view-space position for distance and height calculations.
	mat4 view_mat = transpose(mat4(
			scene_data_block.data.view_matrix[0],
			scene_data_block.data.view_matrix[1],
			scene_data_block.data.view_matrix[2],
			vec4(0.0, 0.0, 0.0, 1.0)));
	vec3 world_hit = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * segment_dist;
	vec3 vertex = (view_mat * vec4(world_hit, 1.0)).xyz;

	vec4 fog = fog_process(scene_data_block.data, vertex);
	radiance += throughput * fog.rgb * fog.a;
	throughput *= (1.0 - fog.a);
}

// ============================================================================
// SHADE AND BOUNCE
// ============================================================================

/// Production shading: emissive + NEE direct lighting + BRDF importance sampling + next bounce.
/// Also handles DLSS-RR G-buffer output on primary ray.
void shade_and_bounce(HitData h, MaterialResult m) {
	PathState ps = path_unpack(payload);

	vec3 V = -gl_WorldRayDirectionEXT;
	float NdotV = max(dot(m.normal, V), 0.0001);

	uint total_bounces = get_total_bounces(ps.packed_bounces_flags);
	uint diffuse_bounces = get_diffuse_bounces(ps.packed_bounces_flags);

	// Environment fog for this ray segment (before surface contribution).
	apply_segment_fog(gl_HitTEXT, ps.radiance, ps.throughput);

	// Emissive contribution.
	ps.radiance += ps.throughput * m.emissive;

	// Bounce limit check.
	if (total_bounces >= RT_GET_MAX_BOUNCES() || diffuse_bounces >= MAX_DIFFUSE_BOUNCES) {
		ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
		path_pack(payload, ps);
		return;
	}

	// BRDF material setup.
	MaterialProperties brdf_mat;
	brdf_mat.baseColor = m.albedo;
	brdf_mat.metalness = m.metalness;
	brdf_mat.roughness = m.roughness;
	brdf_mat.emissive = m.emissive;
	brdf_mat.transmissivness = 0.0;
	brdf_mat.opacity = 1.0;

	vec3 specularF0 = baseColorToSpecularF0(brdf_mat.baseColor, brdf_mat.metalness);
	vec3 diffuseReflectance = baseColorToDiffuseReflectance(brdf_mat.baseColor, brdf_mat.metalness);

	// =================================================================
	// DLSS Ray Reconstruction output (primary ray, sample 0 only)
	// =================================================================
#ifdef DLSS_RR_ENABLED
	if (total_bounces == 0u && is_sample_zero(ps.packed_bounces_flags)) {
		ivec2 pixel = ivec2(gl_LaunchIDEXT.xy);

		vec3 diffuse_albedo = DLSSRR_computeDiffuseAlbedo(m.albedo, m.metalness);
		imageStore(dlss_rr_diffuse_albedo, pixel, vec4(diffuse_albedo, 1.0));

		vec3 specular_albedo = DLSSRR_computeSpecularAlbedo(m.albedo, m.metalness, m.roughness, NdotV);
		imageStore(dlss_rr_specular_albedo, pixel, vec4(specular_albedo, 1.0));

		imageStore(dlss_rr_normal_roughness, pixel, vec4(m.normal, m.roughness));

		// Specular hit distance via inline ray query (only for smooth surfaces).
		float spec_hit_dist = -1.0;
		if (m.roughness < MAX_DENOISER_SPECULAR_HIT_THRESHOLD) {
			vec3 spec_dir = reflect(-V, m.normal);
			vec3 spec_origin = offset_ray_origin(h.hit_pos, spec_dir);

			rayQueryEXT spec_rq;
			rayQueryInitializeEXT(spec_rq, tlas, RT_RAY_FLAGS | gl_RayFlagsTerminateOnFirstHitEXT,
					0xFF, spec_origin, 0.001, spec_dir, 10000.0);
			while (rayQueryProceedEXT(spec_rq)) {
				if (rayQueryGetIntersectionTypeEXT(spec_rq, false) == gl_RayQueryCandidateIntersectionTriangleEXT) {
					if (ray_query_alpha_test(
								rayQueryGetIntersectionInstanceCustomIndexEXT(spec_rq, false),
								rayQueryGetIntersectionPrimitiveIndexEXT(spec_rq, false),
								rayQueryGetIntersectionBarycentricsEXT(spec_rq, false))) {
						rayQueryConfirmIntersectionEXT(spec_rq);
					}
				}
			}
			if (rayQueryGetIntersectionTypeEXT(spec_rq, true) != gl_RayQueryCommittedIntersectionNoneEXT) {
				spec_hit_dist = rayQueryGetIntersectionTEXT(spec_rq, true);
			}
		}
		imageStore(dlss_rr_specular_hit_dist, pixel, vec4(spec_hit_dist));
	}
#endif

	// =================================================================
	// NEE: Next Event Estimation (direct light sampling)
	// =================================================================
	path_pack(payload, ps);

	uint rt_light_count = uint(get_rt_param(RT_PARAM_LIGHT_COUNT));
	if (rt_light_count > 0u) {
		vec3 hit_pos_offset = offset_ray_origin(h.hit_pos, h.geometry_normal);
		bool is_indirect = (diffuse_bounces > 0u);
		vec3 direct_light = lights_evaluate_direct_lighting(
				hit_pos_offset, m.normal, V, brdf_mat, ps.rng_state, is_indirect, rt_light_count);
		ps.radiance += ps.throughput * direct_light;
	}

	// =================================================================
	// BRDF importance sampling for next bounce
	// =================================================================
	float specularLum = luminance(specularF0);
	float diffuseLum = luminance(diffuseReflectance);

	int brdfType;
	if (diffuseLum < 0.0001) {
		brdfType = SPECULAR_TYPE;
	} else if (specularLum < 0.0001) {
		brdfType = DIFFUSE_TYPE;
	} else {
		float brdfProbability = clamp(specularLum / (specularLum + diffuseLum), 0.01, 0.99);
		if (rand(ps.rng_state) < brdfProbability) {
			brdfType = SPECULAR_TYPE;
			ps.throughput /= brdfProbability;
		} else {
			brdfType = DIFFUSE_TYPE;
			ps.throughput /= (1.0 - brdfProbability);
		}
	}

	vec2 u = rand2(ps.rng_state);
	vec3 next_dir;
	vec3 brdf_weight;
	if (!evalIndirectCombinedBRDF(u, m.normal, h.geometry_normal, V, brdf_mat, brdfType, next_dir, brdf_weight, vec4(0.0))) {
		// No valid next-bounce direction -- terminate here.
		ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
		path_pack(payload, ps);
		return;
	}

	ps.throughput *= brdf_weight;

	if (brdfType == DIFFUSE_TYPE) {
		ps.packed_bounces_flags = inc_diffuse_bounce(ps.packed_bounces_flags);
	} else {
		ps.packed_bounces_flags = inc_total_bounce(ps.packed_bounces_flags);
	}

	// Hand the next ray back to raygen. PATH_TERMINATED_FLAG stays clear so
	// the raygen loop continues with (next_ray_origin, next_ray_dir).
	ps.next_ray_origin = offset_ray_origin(h.hit_pos, h.geometry_normal);
	ps.next_ray_dir = next_dir;
	path_pack(payload, ps);
}
