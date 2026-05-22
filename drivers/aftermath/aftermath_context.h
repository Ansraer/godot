/**************************************************************************/
/*  aftermath_context.h                                                   */
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

#pragma once

#include "core/typedefs.h"
#include "drivers/aftermath/aftermath_data.h"

#ifdef AFTERMATH_ENABLED
#include "core/os/mutex.h"
#include "core/templates/hash_map.h"
#include "core/templates/vector.h"
#endif

/**
 * AftermathContext - process-singleton owning all Aftermath state.
 * Always declared so call sites never need #ifdefs.
 * Method bodies compile to empty stubs when AFTERMATH_ENABLED is off.
 */
class AftermathContext {
public:
	static AftermathContext &get();

	bool load_functions();
	bool is_initialized() const { return _initialized; }

	void register_shader(AftermathShaderType p_type, const uint8_t *p_bytes, uint32_t p_size);
	// D3D12 requires an explicit init call after device creation.
	// Vulkan initializes implicitly via VkDeviceDiagnosticsConfigCreateInfoNV.
	void initialize_d3d12(void *p_d3d12_device);
	void wait_for_dump();

	const char *const *vk_required_extensions() const;
	void *vk_device_diagnostics_config();

	const char *dump_dir() const {
#ifdef AFTERMATH_ENABLED
		return _dump_dir;
#else
		return "";
#endif
	}

private:
	bool _initialized = false;

#ifdef AFTERMATH_ENABLED
	// Function pointers loaded from GFSDK_Aftermath_Lib.x64.dll.
	void *fn_EnableGpuCrashDumps = nullptr;
	void *fn_DisableGpuCrashDumps = nullptr;
	void *fn_GetCrashDumpStatus = nullptr;
	void *fn_GetShaderDebugInfoIdentifier = nullptr;
	void *fn_GpuCrashDump_CreateDecoder = nullptr;
	void *fn_GpuCrashDump_GenerateJSON = nullptr;
	void *fn_GpuCrashDump_GetJSON = nullptr;
	void *fn_GpuCrashDump_DestroyDecoder = nullptr;

#ifdef AFTERMATH_ENABLED_D3D12
	void *fn_DX12_Initialize = nullptr;
	void *fn_GetShaderHash = nullptr;
#endif

#ifdef AFTERMATH_ENABLED_VULKAN
	void *fn_GetShaderHashSpirv = nullptr;
#endif

	Mutex shader_map_mutex;
	HashMap<uint64_t, Vector<uint8_t>> shader_map;

	char _dump_dir[512] = {};
	// Raw storage for VkDeviceDiagnosticsConfigCreateInfoNV (avoids leaking SDK types).
	uint8_t vk_diag_config_storage[64] = {};

	static const char *vk_ext_names[3];

	void _create_dump_dirs();
	void _write_file(const char *p_path, const void *p_data, uint32_t p_size);

	// Static Aftermath C-callable callbacks (full signatures in aftermath_context.cpp).
	static void _cb_gpu_crash_dump(const void *p_data, uint32_t p_size, void *p_user);
	static void _cb_shader_debug_info(const void *p_data, uint32_t p_size, void *p_user);
	static void _cb_description(void *p_add_value_fn, void *p_user);
	static void _cb_resolve_marker(const void *p_marker, uint32_t p_size, void *p_user, void **pp_resolved, uint32_t *p_resolved_size);
	static void _cb_shader_lookup(const void *p_hash, void *p_set_shader_fn, void *p_user);
	static void _cb_shader_debug_info_lookup(const void *p_id, void *p_set_debug_info_fn, void *p_user);
#endif // AFTERMATH_ENABLED
};
