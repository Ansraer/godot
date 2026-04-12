#[raygen]

#version 460

#extension GL_EXT_control_flow_attributes : enable

#VERSION_DEFINES

// clang-format off
#include "raytracing_inc.glsl"
#include "../scene_data_inc.glsl"
// clang-format on

#pragma shader_stage(raygen)
#extension GL_EXT_ray_tracing : enable
#extension GL_EXT_shader_invocation_reorder : enable

#include "raytracing_common_inc.glsl"

layout(set = 0, binding = 0, rgba32f) uniform image2D image;
layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;

layout(location = 0) rayPayloadEXT PathPayload payload;

void main() {
	uvec2 pixel = gl_LaunchIDEXT.xy;
	const vec2 pixel_center = vec2(pixel) + vec2(0.5);
	const vec2 in_uv = pixel_center / vec2(gl_LaunchSizeEXT.xy);
	vec2 d = in_uv * 2.0 - 1.0;

	mat4 inv_view = transpose(mat4(scene_data_block.data.inv_view_matrix[0],
			scene_data_block.data.inv_view_matrix[1],
			scene_data_block.data.inv_view_matrix[2],
			vec4(0.0, 0.0, 0.0, 1.0)));

	vec4 target = scene_data_block.data.inv_projection_matrix * vec4(d.x, d.y, 1.0, 1.0);
	vec4 origin = inv_view * vec4(0.0, 0.0, 0.0, 1.0);
	vec4 direction = inv_view * vec4(normalize(target.xyz), 0);

	// Sample count from specialization constant, frame index from uniform
	const uint samples_per_pixel = RT_GET_SAMPLE_COUNT();
	uint frame_index = uint(get_rt_param(RT_PARAM_FRAME_INDEX));

	// Accumulate multiple samples per pixel
	vec3 total_radiance = vec3(0.0);

	[[dont_unroll]] for (uint sample_idx = 0u; sample_idx < samples_per_pixel; sample_idx++) {
		// Initialize payload for this sample
		payload.radiance = vec3(0.0);
		payload.throughput = vec3(1.0);
		// Set sample 0 flag so closest_hit only writes DLSS RR outputs on first sample
		payload.packed_bounces_flags = (sample_idx == 0u) ? set_sample_zero(0u) : 0u;
		payload.rng_state = init_rng(pixel, frame_index, sample_idx);

		vec3 ray_origin = origin.xyz;
		vec3 ray_dir = direction.xyz;

		// Iterative bounce loop with Shader Execution Reordering
		[[dont_unroll]] for (uint bounce = 0u; bounce <= RT_GET_MAX_BOUNCES(); bounce++) {
			hitObjectEXT hit_object;
			hitObjectTraceRayEXT(hit_object, tlas, RT_RAY_FLAGS, 0xFF, 0, 0, 0, ray_origin, 0.001, ray_dir, 10000.0, 0);

			// Reorder with a coherence hint that has 8 bits
			// TODO: this hint is pretty redundant. Ideally we would have information about the control flow instead
			uint hint = 0;
			if (hitObjectIsHitEXT(hit_object)) {
				hint = hitObjectGetInstanceIdEXT(hit_object);
			}
			reorderThreadEXT(hit_object, hint, 8);

			hitObjectExecuteShaderEXT(hit_object, 0);

			if (!should_continue_ray(payload.packed_bounces_flags)) {
				break;
			}

			// Set up next iteration from bounce info written by closest_hit.
			ray_origin = payload.next_ray_origin;
			ray_dir = payload.next_ray_dir;
			payload.packed_bounces_flags = clear_continue_ray(payload.packed_bounces_flags);
		}

		total_radiance += payload.radiance;
	}

	// Average samples
	vec3 final_radiance = total_radiance / float(samples_per_pixel);
	imageStore(image, ivec2(pixel), vec4(final_radiance, 1.0));
}

#[miss]

#version 460

#VERSION_DEFINES

#pragma shader_stage(miss)
#extension GL_EXT_ray_tracing : enable

#define GLSL 1

// clang-format off
#include "raytracing_inc.glsl"
#include "../oct_inc.glsl"
#include "../scene_data_inc.glsl"
#include "brdf_inc.glsl"
#include "raytracing_common_inc.glsl"
// clang-format on

layout(location = 0) rayPayloadInEXT PathPayload payload;

layout(set = 0, binding = 7) uniform texture2D radiance_octmap;
layout(set = 0, binding = 8) uniform sampler radiance_sampler;

void main() {
	// Debug visualization mode handling
	if ((RT_FLAGS & RT_FLAG_DEBUG_VIS_ENABLED) != 0u) {
		int VIS_MODE = int(get_rt_param(RT_PARAM_VIS_MODE));

		// Special handling for specular hit distance mode
		if (VIS_MODE == 13 && get_total_bounces(payload.packed_bounces_flags) > 0u) {
			// Sky hit - dark blue (no specular hit found)
			payload.radiance = vec3(0.1, 0.1, 0.4);
			return;
		}
	}

	// Primary ray miss: write depth and DLSS RR defaults (sample 0 only).
	{
		uint total_bounces = get_total_bounces(payload.packed_bounces_flags);
		if (total_bounces == 0u && is_sample_zero(payload.packed_bounces_flags)) {
			ivec2 pixel = ivec2(gl_LaunchIDEXT.xy);

			// Reverse-Z far plane = 0.0.
			imageStore(rt_depth_image, pixel, vec4(0.0));

#ifdef DLSS_RR_ENABLED
			// Sky has no surface - write zeros for albedo/normals.
			imageStore(dlss_rr_diffuse_albedo, pixel, vec4(0.0));
			imageStore(dlss_rr_specular_albedo, pixel, vec4(0.0));
			// Normal pointing towards camera, zero roughness (sky is infinitely far).
			imageStore(dlss_rr_normal_roughness, pixel, vec4(-gl_WorldRayDirectionEXT, 0.0));
			// Sky hit distance: -1 indicates infinite/sky.
			imageStore(dlss_rr_specular_hit_dist, pixel, vec4(-1.0));
#endif
		}
	}

	// Transform ray direction from world to sky space (user can rotate the skybox in world environment, this will make sure it is handled)
	mat3 camera_basis = mat3(scene_data_block.data.inv_view_matrix);
	mat3 world_to_sky = scene_data_block.data.radiance_inverse_xform * camera_basis;
	vec3 sky_dir = world_to_sky * gl_WorldRayDirectionEXT;

	// Convert to octahedral UV with border handling
	vec2 border = vec2(scene_data_block.data.radiance_border_size,
			1.0 - scene_data_block.data.radiance_border_size * 2.0);
	vec2 sky_uv = vec3_to_oct_with_border(sky_dir, border);

	// Sample sky radiance at LOD 0 (sharpest)
	vec3 sky_color = textureLod(sampler2D(radiance_octmap, radiance_sampler), sky_uv, 0.0).rgb;

	// Apply IBL exposure normalization
	sky_color *= scene_data_block.data.IBL_exposure_normalization;

	// Apply environment fog to sky.
	if ((RT_FLAGS & RT_FLAG_FOG_ENABLED) != 0u) {
		vec3 fog_color = scene_data_block.data.fog_light_color;

		if (scene_data_block.data.fog_aerial_perspective > 0.0) {
			vec3 sky_fog = textureLod(sampler2D(radiance_octmap, radiance_sampler), sky_uv, 1.0).rgb;
			sky_fog *= scene_data_block.data.IBL_exposure_normalization;
			fog_color = mix(fog_color, sky_fog, scene_data_block.data.fog_aerial_perspective);
		}

		sky_color = mix(sky_color, fog_color, scene_data_block.data.fog_sky_affect);
	}

	// For pathtracing mode, multiply by throughput; debug modes just use sky color directly
	if ((RT_FLAGS & RT_FLAG_DEBUG_VIS_ENABLED) != 0u) {
		int VIS_MODE = int(get_rt_param(RT_PARAM_VIS_MODE));
		if (VIS_MODE == 0) {
			payload.radiance += payload.throughput * sky_color;
		} else {
			payload.radiance = sky_color;
		}
	} else {
		// Production: always pathtracing
		payload.radiance += payload.throughput * sky_color;
	}
}

#[closest_hit]

#version 460

#VERSION_DEFINES

#pragma shader_stage(closest_hit)
#extension GL_EXT_ray_tracing : enable
#extension GL_EXT_ray_query : enable
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_ARB_gpu_shader_int64 : require
#extension GL_EXT_nonuniform_qualifier : require

#define GLSL 1

// clang-format off
#include "raytracing_inc.glsl"
#include "../oct_inc.glsl"
#include "../scene_data_inc.glsl"
#include "brdf_inc.glsl"
#include "raytracing_common_inc.glsl"
// clang-format on

hitAttributeEXT vec2 attribs;
#define RT_HIT_ATTRIBS_DECLARED

#include "raytracing_hit_inc.glsl"

layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;
layout(location = 0) rayPayloadInEXT PathPayload payload;

layout(set = 1, binding = 0) uniform texture2D bindless_textures[];

#include "raytracing_samplers_inc.glsl"

layout(set = 0, binding = 3, std430) readonly buffer GeometryBuffer {
	GeometryData geometries[];
};

layout(set = 0, binding = 5, std430) readonly buffer MaterialBuffer {
	MaterialData materials[];
};

#include "raytracing_lights_inc.glsl"

layout(set = 0, binding = 7) uniform texture2D radiance_octmap;
layout(set = 0, binding = 8) uniform sampler radiance_sampler;

// clang-format off
#include "raytracing_material_eval_inc.glsl"
#include "raytracing_closest_hit_common_inc.glsl"
// clang-format on

// ============================================================================
// DEBUG VISUALIZATION (only compiled when RT_FLAG_DEBUG_VIS_ENABLED is set)
// ============================================================================
void debug_visualize(
		int vis_mode,
		vec3 geometry_normal,
		vec3 final_normal,
		vec3 tangent_space_normal,
		vec3 world_tangent,
		vec3 world_bitangent,
		vec2 uv,
		vec3 albedo,
		vec3 orm,
		float metalness,
		float roughness,
		vec3 V,
		float NdotV) {
	if (vis_mode == 1) {
		// Mirror reflection using geometry normal
		if (get_total_bounces(payload.packed_bounces_flags) == 0u) {
			payload.packed_bounces_flags = inc_total_bounce(payload.packed_bounces_flags);
			vec3 hit_pos = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * gl_HitTEXT;
			vec3 reflect_dir = reflect(gl_WorldRayDirectionEXT, geometry_normal);
			payload.next_ray_origin = hit_pos + geometry_normal * 0.01;
			payload.next_ray_dir = reflect_dir;
			payload.packed_bounces_flags = set_continue_ray(payload.packed_bounces_flags);
		} else {
			payload.radiance = geometry_normal * 0.5 + 0.5;
		}
	} else if (vis_mode == 2) {
		// Geometry normals (world space, no normal map)
		payload.radiance = geometry_normal * 0.5 + 0.5;
	} else if (vis_mode == 3) {
		// Final normals (with normal map applied)
		payload.radiance = final_normal * 0.5 + 0.5;
	} else if (vis_mode == 4) {
		// Normal map raw (tangent space)
		payload.radiance = tangent_space_normal * 0.5 + 0.5;
	} else if (vis_mode == 5) {
		// Tangent visualization
		payload.radiance = world_tangent * 0.5 + 0.5;
	} else if (vis_mode == 6) {
		// Bitangent visualization
		payload.radiance = world_bitangent * 0.5 + 0.5;
	} else if (vis_mode == 7) {
		// UV visualization
		payload.radiance = vec3(fract(uv), 0.0);
	} else if (vis_mode == 8) {
		// Albedo only (unlit)
		payload.radiance = albedo;
	} else if (vis_mode == 9) {
		// ORM texture (Occlusion=R, Roughness=G, Metallic=B)
		payload.radiance = orm;
	}
	// =========================================================================
	// DLSS-RR STYLE VISUALIZATION MODES
	// =========================================================================
	else if (vis_mode == 10) {
		// Diffuse Albedo
		payload.radiance = DLSSRR_computeDiffuseAlbedo(albedo, metalness);
	} else if (vis_mode == 11) {
		// Specular Albedo
		payload.radiance = DLSSRR_computeSpecularAlbedo(albedo, metalness, roughness, NdotV);
	} else if (vis_mode == 12) {
		// Normal + Roughness visualization
		payload.radiance = (final_normal * 0.5 + 0.5) * (1.0 - roughness * 0.5);
	} else if (vis_mode == 13) {
		// DLSS RR Specular Hit Distance (with log-scale heat map)
		if (get_total_bounces(payload.packed_bounces_flags) == 0u) {
			// Primary ray - trace specular ray if smooth enough
			if (roughness < MAX_DENOISER_SPECULAR_HIT_THRESHOLD) {
				payload.packed_bounces_flags = inc_total_bounce(payload.packed_bounces_flags);
				payload.radiance = vec3(-1.0, 0.0, 0.0); // Initialize to sky value before trace
				vec3 hit_pos = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * gl_HitTEXT;
				vec3 reflect_dir = reflect(gl_WorldRayDirectionEXT, final_normal);
				payload.next_ray_origin = hit_pos + final_normal * 0.01;
				payload.next_ray_dir = reflect_dir;
				payload.packed_bounces_flags = set_continue_ray(payload.packed_bounces_flags);
			} else {
				// Too rough for meaningful specular reflection - use same color as sky/miss
				payload.radiance = vec3(0.1, 0.1, 0.4);
			}
		} else {
			// Secondary ray hit - convert hit distance to heat map visualization.
			float spec_hit_t = gl_HitTEXT;
			float v = clamp(log(spec_hit_t + 1.0) / log(1000.0), 0.0, 1.0);
			vec3 color;
			if (v < 0.33) {
				color = mix(vec3(0.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), v * 3.0);
			} else if (v < 0.66) {
				color = mix(vec3(1.0, 0.0, 0.0), vec3(1.0, 1.0, 0.0), (v - 0.33) * 3.0);
			} else {
				color = mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 1.0, 1.0), (v - 0.66) * 3.0);
			}
			payload.radiance = color;
		}
	} else if (vis_mode == 14) {
		// Metalness
		payload.radiance = vec3(metalness);
	} else if (vis_mode == 15) {
		// Roughness
		payload.radiance = vec3(roughness);
	} else if (vis_mode == 16) {
		// View-space normals
		mat3 world_to_view = mat3(scene_data_block.data.inv_view_matrix);
		payload.radiance = normalize(world_to_view * final_normal) * 0.5 + 0.5;
	} else if (vis_mode == 17) {
		// Diffuse + Specular split
		vec3 diffuse_albedo = DLSSRR_computeDiffuseAlbedo(albedo, metalness);
		vec3 specular_albedo = DLSSRR_computeSpecularAlbedo(albedo, metalness, roughness, NdotV);
		payload.radiance = mix(diffuse_albedo, specular_albedo, metalness);
	} else if (vis_mode == 18) {
		// Fresnel F0
		payload.radiance = baseColorToSpecularF0(albedo, metalness);
	} else if (vis_mode == 19) {
		// Front/Back face hit
		bool is_front_face = (gl_HitKindEXT == gl_HitKindFrontFacingTriangleEXT);
		payload.radiance = is_front_face ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	}
}

// ============================================================================
// CUSTOM SHADER GLOBALS (injected by ShaderCompiler for HG1+)
// ============================================================================
#ifdef RT_CUSTOM_HIT_GROUP
#include "raytracing_custom_globals_inc.glsl"
#endif

// ============================================================================
// MAIN
// ============================================================================
void main() {
	HitData h = compute_hit_data();
	write_primary_hit_depth(h.hit_pos);

#ifdef RT_CUSTOM_HIT_GROUP
	uint rt_geometry_idx = h.geometry_idx;
	vec3 rt_hit_pos = h.hit_pos;
	vec2 rt_uv = h.uv;
	vec3 rt_normal = h.geometry_normal;
	vec3 rt_tangent = h.tangent;
	vec3 rt_bitangent = h.bitangent;
	bool rt_front_face = h.is_front_face;

#include "raytracing_custom_fragment_inc.glsl"

	// Alpha scissor: treat pixel as fully transparent if below threshold.
	// The any_hit shader handles this via ignoreIntersectionEXT, so this
	// should not normally be reached.
	if (alpha_scissor_threshold > 0.0 && alpha < alpha_scissor_threshold) {
		return;
	}

	// Build MaterialResult from fragment outputs.
	MaterialResult m;
	m.albedo = albedo;
	m.alpha = alpha;
	m.roughness = roughness;
	m.metalness = metallic;
	m.emissive = emission * scene_data_block.data.emissive_exposure_normalization;
	m.normal = normal;

	// Apply normal map if it was written.
	if (normal_map != vec3(0.5, 0.5, 1.0)) {
		vec3 ts_normal;
		ts_normal.xy = normal_map.xy * 2.0 - 1.0;
		ts_normal.z = sqrt(max(0.0, 1.0 - dot(ts_normal.xy, ts_normal.xy)));
		m.normal = apply_normal_map(h, ts_normal, normal_map_depth);
	}

	shade_and_bounce(h, m);
#else
	// HG0: StandardMaterial3D evaluation.
	MaterialData mat = materials[h.geometry_idx];
	vec2 uv = h.uv * mat.uv1_scale + mat.uv1_offset;

	// Normal mapping.
	vec3 tangent_space_normal = vec3(0.0, 0.0, 1.0);
	vec3 final_normal = h.geometry_normal;
	if ((mat.flags & 1u) != 0u) {
		vec3 normal_sample = sample_bindless_texture(mat.normal_texture_idx, uv).rgb;
		tangent_space_normal.xy = normal_sample.xy * 2.0 - 1.0;
		tangent_space_normal.z = sqrt(max(0.0, 1.0 - dot(tangent_space_normal.xy, tangent_space_normal.xy)));
		final_normal = apply_normal_map(h, tangent_space_normal, mat.normal_map_depth);
	}

	// Texture sampling.
	vec4 albedo_tex = sample_material_texture(mat.albedo_texture_idx, uv, mat.flags);
	vec3 albedo = albedo_tex.rgb * mat.albedo_color.rgb;
	vec3 orm = sample_material_texture(mat.orm_texture_idx, uv, mat.flags).rgb;
	float roughness = saturate(orm.g * mat.roughness);
	float metalness = saturate(orm.b * mat.metallic);

	vec3 emissive = vec3(0.0);
	if ((mat.flags & 2u) != 0u) {
		emissive = sample_material_texture(mat.emission_texture_idx, uv, mat.flags).rgb * mat.emission_color * mat.emission_strength;
		emissive *= scene_data_block.data.emissive_exposure_normalization;
	}

	// Build MaterialResult.
	MaterialResult m;
	m.albedo = albedo;
	m.alpha = albedo_tex.a * mat.albedo_color.a;
	m.roughness = roughness;
	m.metalness = metalness;
	m.emissive = emissive;
	m.normal = final_normal;

	// Debug or production path.
	int VIS_MODE = 0;
	if ((RT_FLAGS & RT_FLAG_DEBUG_VIS_ENABLED) != 0u) {
		VIS_MODE = int(get_rt_param(RT_PARAM_VIS_MODE));
	}

	if ((RT_FLAGS & RT_FLAG_DEBUG_VIS_ENABLED) != 0u && VIS_MODE != 0) {
		vec3 V = -gl_WorldRayDirectionEXT;
		float NdotV = max(dot(m.normal, V), 0.0001);
		debug_visualize(VIS_MODE, h.geometry_normal, final_normal, tangent_space_normal,
				h.tangent, h.bitangent, uv, albedo, orm, metalness, roughness, V, NdotV);
	} else {
		shade_and_bounce(h, m);
	}
#endif
}

#[any_hit]

#version 460

#VERSION_DEFINES

#pragma shader_stage(any_hit)
#extension GL_EXT_ray_tracing : enable
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_ARB_gpu_shader_int64 : require
#extension GL_EXT_nonuniform_qualifier : require

#define GLSL 1
#define RT_STAGE_ANY_HIT

// clang-format off
#include "raytracing_inc.glsl"
#include "../oct_inc.glsl"
#include "../scene_data_inc.glsl"
#include "raytracing_common_inc.glsl"
// clang-format on

hitAttributeEXT vec2 attribs;
#define RT_HIT_ATTRIBS_DECLARED

#include "raytracing_hit_inc.glsl"

layout(location = 0) rayPayloadInEXT PathPayload payload;

layout(set = 0, binding = 3, std430) readonly buffer GeometryBuffer {
	GeometryData geometries[];
};

layout(set = 0, binding = 5, std430) readonly buffer MaterialBuffer {
	MaterialData materials[];
};

layout(set = 1, binding = 0) uniform texture2D bindless_textures[];

#include "raytracing_samplers_inc.glsl"

// ============================================================================
// CUSTOM SHADER GLOBALS (injected for per-HG any-hit)
// ============================================================================
#ifdef RT_CUSTOM_HIT_GROUP
#include "raytracing_custom_globals_inc.glsl"
#endif

void main() {
	uint geometry_idx = gl_InstanceCustomIndexEXT;
	GeometryData geom = geometries[geometry_idx];

	uint i0, i1, i2;
	get_triangle_indices(geom, i0, i1, i2);
	vec3 bary = vec3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);

#ifdef RT_CUSTOM_HIT_GROUP
	// Compute hit data inline (cannot include closest_hit_common_inc here).
	uint rt_geometry_idx = geometry_idx;
	vec2 rt_uv = fetch_uv(geom, i0, i1, i2, bary);
	TBNResult ah_tbn = fetch_tbn(geom, i0, i1, i2, bary);

	mat3 model_rotation = mat3(gl_ObjectToWorldEXT);
	mat3 normal_matrix = mat3(
			normalize(model_rotation[0]),
			normalize(model_rotation[1]),
			normalize(model_rotation[2]));

	vec3 rt_normal = normalize(normal_matrix * ah_tbn.normal);
	bool rt_front_face = (gl_HitKindEXT == gl_HitKindFrontFacingTriangleEXT);
	if (!rt_front_face) {
		rt_normal = -rt_normal;
	}

	vec3 rt_hit_pos = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * gl_HitTEXT;
	vec3 rt_tangent = normalize(normal_matrix * ah_tbn.tangent);
	vec3 rt_bitangent = cross(rt_normal, rt_tangent) * ah_tbn.bitangent_sign;

#include "raytracing_custom_fragment_inc.glsl"

	if (alpha_scissor_threshold > 0.0 && alpha < alpha_scissor_threshold) {
		ignoreIntersectionEXT;
	}
#else
	// HG0: Standard material alpha test.
	vec2 uv = fetch_uv(geom, i0, i1, i2, bary);
	MaterialData mat = materials[geometry_idx];
	uv = uv * mat.uv1_scale + mat.uv1_offset;
	float alpha = texture(sampler2D(bindless_textures[nonuniformEXT(mat.albedo_texture_idx)], SAMPLER_LINEAR_WITH_MIPMAPS_REPEAT), uv).a;
	alpha *= mat.albedo_color.a;

	if (alpha < 0.5) {
		ignoreIntersectionEXT;
	}
#endif
}
