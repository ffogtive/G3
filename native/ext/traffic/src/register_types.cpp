// GDExtension entry point for libtraffic (entry_symbol in native/ext/traffic.gdextension).
#include "traffic.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

namespace {

void initialize_traffic_module(godot::ModuleInitializationLevel p_level) {
	if (p_level != godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(lane1::Traffic);
}

void uninitialize_traffic_module(godot::ModuleInitializationLevel /*p_level*/) {}

} // namespace

extern "C" {

GDExtensionBool GDE_EXPORT traffic_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_traffic_module);
	init_obj.register_terminator(uninitialize_traffic_module);
	init_obj.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}

} // extern "C"
