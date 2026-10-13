// haptics_gdextension.cpp — IOSHaptics (RefCounted) on the raw GDExtension C interface, Godot 4.7+.
//
// 가설: ✅ godot-cpp 없이 C 인터페이스만 쓰면 iOS 정적 링크에서 traffic(godot-cpp)과 독립된다. Godot 4.7.2 iOS
//       export는 manifest마다 [dependencies]를 중복 제거 없이 추가하므로(컨테이너 재현), 공용 godot-cpp
//       xcframework를 두 manifest에 적으면 PBX 참조가 2개 생기고, 안 적으면 haptics가 traffic manifest에 기댄다.
//       또 ext(traffic) 빌드가 실패해도 이 모듈은 단독으로 링크된다(ios_run.sh 요구: ext 실패해도 게임은 뜬다).
//
// Methods (all instance methods; GDScript: `var h: Object = ClassDB.instantiate(&"IOSHaptics")`):
//   backend_name() -> String ("corehaptics" | "null")      is_supported() -> bool
//   start() -> bool   stop()                                 prepare()
//   transient(intensity: float, sharpness: float) -> bool
//   continuous(intensity: float, sharpness: float, duration: float) -> bool
//   register_pattern(name: String, ahap_json: String) -> bool   play_registered(name: String) -> bool
//   play_pattern(ahap_json: String) -> bool
//   selection()   impact(style: int, intensity: float)    (style: 0 light 1 medium 2 heavy 3 soft 4 rigid)
//   thermal_state() -> String   is_low_power_mode() -> bool   thermal_change_count() -> int
//   debug_state() -> String (JSON)   build_info() -> String
//
// The interface header is generated from the pinned engine (`godot --headless --dump-gdextension-interface`) by
// tools/mac/build_ios_ext.sh; this file only uses functions marked @since <= 4.7.
#include <gdextension_interface.h>

#include "haptics_core.h"

#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <tuple>
#include <type_traits>
#include <utility>
#include <vector>

#if defined(_WIN32)
#define LANE1_HAPTICS_EXPORT __declspec(dllexport)
#else
#define LANE1_HAPTICS_EXPORT __attribute__((visibility("default")))
#endif

#ifndef LANE1_HAPTICS_VERSION
#define LANE1_HAPTICS_VERSION "0.1.0"
#endif

namespace {

using lane1::haptics::Core;

constexpr const char *kClassName = "IOSHaptics";
constexpr const char *kParentClass = "RefCounted";
// Object.notification(what: int, reversed: bool = false); method hash from extension_api.json (4.7).
constexpr GDExtensionInt kObjectNotificationHash = 4023243586;
constexpr int64_t kNotificationPostinitialize = 0;
constexpr uint32_t kPropertyUsageDefault = 6; // PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR

static_assert(sizeof(void *) == 8, "64-bit targets only (iOS arm64, Linux x86_64, macOS arm64/x86_64)");
constexpr size_t kStringSize = 8; // String / StringName: one pointer (extension_api builtin_class_sizes float_64)

// ---------------------------------------------------------------------------------------------------------------
// Interface function table.
struct Api {
	GDExtensionInterfaceGetProcAddress get_proc_address = nullptr;
	GDExtensionClassLibraryPtr library = nullptr;

	GDExtensionInterfacePrintWarning print_warning = nullptr;
	GDExtensionInterfaceStringNameNewWithLatin1Chars string_name_new_with_latin1_chars = nullptr;
	GDExtensionInterfaceStringNewWithUtf8CharsAndLen2 string_new_with_utf8_chars_and_len2 = nullptr;
	GDExtensionInterfaceStringToUtf8Chars string_to_utf8_chars = nullptr;
	GDExtensionInterfaceVariantGetPtrDestructor variant_get_ptr_destructor = nullptr;
	GDExtensionInterfaceGetVariantFromTypeConstructor get_variant_from_type_constructor = nullptr;
	GDExtensionInterfaceGetVariantToTypeConstructor get_variant_to_type_constructor = nullptr;
	GDExtensionInterfaceVariantGetType variant_get_type = nullptr;
	GDExtensionInterfaceVariantDestroy variant_destroy = nullptr;
	GDExtensionInterfaceClassdbConstructObject3 classdb_construct_object3 = nullptr;
	GDExtensionInterfaceObjectSetInstance object_set_instance = nullptr;
	GDExtensionInterfaceClassdbRegisterExtensionClass6 classdb_register_extension_class6 = nullptr;
	GDExtensionInterfaceClassdbRegisterExtensionClassMethod classdb_register_extension_class_method = nullptr;
	GDExtensionInterfaceClassdbUnregisterExtensionClass classdb_unregister_extension_class = nullptr;
	GDExtensionInterfaceClassdbGetMethodBind classdb_get_method_bind = nullptr;
	GDExtensionInterfaceObjectMethodBindPtrcall object_method_bind_ptrcall = nullptr;

	// Resolved once the core functions above are loaded.
	GDExtensionPtrDestructor string_destructor = nullptr;
	GDExtensionPtrDestructor string_name_destructor = nullptr;
	GDExtensionVariantFromTypeConstructorFunc variant_from_bool = nullptr;
	GDExtensionVariantFromTypeConstructorFunc variant_from_int = nullptr;
	GDExtensionVariantFromTypeConstructorFunc variant_from_float = nullptr;
	GDExtensionVariantFromTypeConstructorFunc variant_from_string = nullptr;
	GDExtensionTypeFromVariantConstructorFunc bool_from_variant = nullptr;
	GDExtensionTypeFromVariantConstructorFunc int_from_variant = nullptr;
	GDExtensionTypeFromVariantConstructorFunc float_from_variant = nullptr;
	GDExtensionTypeFromVariantConstructorFunc string_from_variant = nullptr;
	GDExtensionMethodBindPtr object_notification = nullptr;
};

Api api;

template <typename F>
bool load_proc(F &r_fn, const char *p_name) {
	r_fn = reinterpret_cast<F>(api.get_proc_address(p_name));
	return r_fn != nullptr;
}

void warn(const char *p_message) {
	if (api.print_warning != nullptr) {
		api.print_warning(p_message, "lane1_haptics", __FILE__, __LINE__, false);
	}
}

// ---------------------------------------------------------------------------------------------------------------
// Owned opaque builtins.
class GDStringName {
public:
	explicit GDStringName(const char *p_text) { api.string_name_new_with_latin1_chars(opaque_, p_text, false); }
	~GDStringName() { api.string_name_destructor(opaque_); }
	GDStringName(const GDStringName &) = delete;
	GDStringName &operator=(const GDStringName &) = delete;
	GDExtensionStringNamePtr ptr() { return opaque_; }

private:
	alignas(void *) uint8_t opaque_[kStringSize] = {};
};

class GDString {
public:
	explicit GDString(const std::string &p_text = std::string()) {
		api.string_new_with_utf8_chars_and_len2(opaque_, p_text.data(), static_cast<GDExtensionInt>(p_text.size()));
	}
	~GDString() { api.string_destructor(opaque_); }
	GDString(const GDString &) = delete;
	GDString &operator=(const GDString &) = delete;
	GDExtensionStringPtr ptr() { return opaque_; }

private:
	alignas(void *) uint8_t opaque_[kStringSize] = {};
};

std::string to_std_string(GDExtensionConstStringPtr p_string) {
	const GDExtensionInt length = api.string_to_utf8_chars(p_string, nullptr, 0);
	std::string out(static_cast<size_t>(length > 0 ? length : 0), '\0');
	if (length > 0) {
		api.string_to_utf8_chars(p_string, out.data(), length);
	}
	return out;
}

GDExtensionVariantPtr mutable_variant(GDExtensionConstVariantPtr p_variant) {
	// The to-type constructors take a non-const pointer but only read from it.
	return const_cast<GDExtensionVariantPtr>(p_variant);
}

// ---------------------------------------------------------------------------------------------------------------
// Type traits: Variant <-> C++ and ptrcall encoding (Godot PtrToArg: bool=1 byte, int=int64, float=double).
template <typename T>
struct Type;

template <>
struct Type<bool> {
	static constexpr GDExtensionVariantType kType = GDEXTENSION_VARIANT_TYPE_BOOL;
	static constexpr GDExtensionClassMethodArgumentMetadata kMeta = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	static bool from_variant(GDExtensionConstVariantPtr p_v, bool &r_out) {
		switch (api.variant_get_type(p_v)) {
			case GDEXTENSION_VARIANT_TYPE_BOOL: {
				GDExtensionBool b = 0;
				api.bool_from_variant(&b, mutable_variant(p_v));
				r_out = b != 0;
				return true;
			}
			case GDEXTENSION_VARIANT_TYPE_INT: {
				int64_t i = 0;
				api.int_from_variant(&i, mutable_variant(p_v));
				r_out = i != 0;
				return true;
			}
			default:
				return false;
		}
	}
	static bool from_ptr(GDExtensionConstTypePtr p_ptr) { return *static_cast<const GDExtensionBool *>(p_ptr) != 0; }
	static void to_variant(GDExtensionUninitializedVariantPtr r_v, bool p_value) {
		GDExtensionBool b = p_value ? 1 : 0;
		api.variant_from_bool(r_v, &b);
	}
	static void to_ptr(GDExtensionTypePtr r_ptr, bool p_value) { *static_cast<GDExtensionBool *>(r_ptr) = p_value ? 1 : 0; }
};

template <>
struct Type<int64_t> {
	static constexpr GDExtensionVariantType kType = GDEXTENSION_VARIANT_TYPE_INT;
	static constexpr GDExtensionClassMethodArgumentMetadata kMeta = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT64;
	static bool from_variant(GDExtensionConstVariantPtr p_v, int64_t &r_out) {
		switch (api.variant_get_type(p_v)) {
			case GDEXTENSION_VARIANT_TYPE_INT:
				api.int_from_variant(&r_out, mutable_variant(p_v));
				return true;
			case GDEXTENSION_VARIANT_TYPE_FLOAT: {
				double d = 0.0;
				api.float_from_variant(&d, mutable_variant(p_v));
				r_out = static_cast<int64_t>(d);
				return true;
			}
			case GDEXTENSION_VARIANT_TYPE_BOOL: {
				GDExtensionBool b = 0;
				api.bool_from_variant(&b, mutable_variant(p_v));
				r_out = b != 0 ? 1 : 0;
				return true;
			}
			default:
				return false;
		}
	}
	static int64_t from_ptr(GDExtensionConstTypePtr p_ptr) { return *static_cast<const int64_t *>(p_ptr); }
	static void to_variant(GDExtensionUninitializedVariantPtr r_v, int64_t p_value) { api.variant_from_int(r_v, &p_value); }
	static void to_ptr(GDExtensionTypePtr r_ptr, int64_t p_value) { *static_cast<int64_t *>(r_ptr) = p_value; }
};

template <>
struct Type<double> {
	static constexpr GDExtensionVariantType kType = GDEXTENSION_VARIANT_TYPE_FLOAT;
	static constexpr GDExtensionClassMethodArgumentMetadata kMeta = GDEXTENSION_METHOD_ARGUMENT_METADATA_REAL_IS_DOUBLE;
	static bool from_variant(GDExtensionConstVariantPtr p_v, double &r_out) {
		switch (api.variant_get_type(p_v)) {
			case GDEXTENSION_VARIANT_TYPE_FLOAT:
				api.float_from_variant(&r_out, mutable_variant(p_v));
				return true;
			case GDEXTENSION_VARIANT_TYPE_INT: {
				int64_t i = 0;
				api.int_from_variant(&i, mutable_variant(p_v));
				r_out = static_cast<double>(i);
				return true;
			}
			default:
				return false;
		}
	}
	static double from_ptr(GDExtensionConstTypePtr p_ptr) { return *static_cast<const double *>(p_ptr); }
	static void to_variant(GDExtensionUninitializedVariantPtr r_v, double p_value) { api.variant_from_float(r_v, &p_value); }
	static void to_ptr(GDExtensionTypePtr r_ptr, double p_value) { *static_cast<double *>(r_ptr) = p_value; }
};

template <>
struct Type<std::string> {
	static constexpr GDExtensionVariantType kType = GDEXTENSION_VARIANT_TYPE_STRING;
	static constexpr GDExtensionClassMethodArgumentMetadata kMeta = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	static bool from_variant(GDExtensionConstVariantPtr p_v, std::string &r_out) {
		// The to-type constructors are unchecked casts: only a STRING variant may be read as a String.
		if (api.variant_get_type(p_v) != GDEXTENSION_VARIANT_TYPE_STRING) {
			return false;
		}
		alignas(void *) uint8_t tmp[kStringSize] = {};
		api.string_from_variant(tmp, mutable_variant(p_v));
		r_out = to_std_string(tmp);
		api.string_destructor(tmp);
		return true;
	}
	static std::string from_ptr(GDExtensionConstTypePtr p_ptr) { return to_std_string(p_ptr); }
	static void to_variant(GDExtensionUninitializedVariantPtr r_v, const std::string &p_value) {
		GDString s(p_value);
		api.variant_from_string(r_v, s.ptr());
	}
	static void to_ptr(GDExtensionTypePtr r_ptr, const std::string &p_value) {
		// r_ptr points to a constructed String (Godot's ptrcall convention): replace it.
		api.string_destructor(r_ptr);
		api.string_new_with_utf8_chars_and_len2(r_ptr, p_value.data(), static_cast<GDExtensionInt>(p_value.size()));
	}
};

// ---------------------------------------------------------------------------------------------------------------
// Method binder: wraps a free function `R fn(A...)` as call + ptrcall entry points.
template <auto Fn>
struct Method;

template <typename R, typename... A, R (*Fn)(A...)>
struct Method<Fn> {
	using Args = std::tuple<std::decay_t<A>...>;
	using Return = R;
	static constexpr size_t kArgc = sizeof...(A);
	static constexpr bool kHasReturn = !std::is_void_v<R>;

	static std::array<GDExtensionVariantType, kArgc> arg_types() { return { Type<std::decay_t<A>>::kType... }; }
	static std::array<GDExtensionClassMethodArgumentMetadata, kArgc> arg_meta() { return { Type<std::decay_t<A>>::kMeta... }; }

	static void call(void * /*userdata*/, GDExtensionClassInstancePtr /*instance*/, const GDExtensionConstVariantPtr *p_args,
			GDExtensionInt p_argc, GDExtensionVariantPtr r_return, GDExtensionCallError *r_error) {
		if (p_argc < static_cast<GDExtensionInt>(kArgc)) {
			r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
			r_error->expected = static_cast<int32_t>(kArgc);
			return;
		}
		if (p_argc > static_cast<GDExtensionInt>(kArgc)) {
			r_error->error = GDEXTENSION_CALL_ERROR_TOO_MANY_ARGUMENTS;
			r_error->expected = static_cast<int32_t>(kArgc);
			return;
		}
		Args values;
		if (!convert_all(p_args, values, r_error, std::index_sequence_for<A...>{})) {
			return;
		}
		r_error->error = GDEXTENSION_CALL_OK;
		if constexpr (kHasReturn) {
			R result = std::apply(Fn, values);
			api.variant_destroy(r_return); // r_return is a constructed (Nil) Variant
			Type<R>::to_variant(r_return, result);
		} else {
			std::apply(Fn, values);
		}
	}

	static void ptrcall(void * /*userdata*/, GDExtensionClassInstancePtr /*instance*/, const GDExtensionConstTypePtr *p_args,
			GDExtensionTypePtr r_ret) {
		ptrcall_impl(p_args, r_ret, std::index_sequence_for<A...>{});
	}

private:
	template <size_t... I>
	static bool convert_all([[maybe_unused]] const GDExtensionConstVariantPtr *p_args, [[maybe_unused]] Args &r_values,
			[[maybe_unused]] GDExtensionCallError *r_error, std::index_sequence<I...>) {
		return (convert_one<I>(p_args, r_values, r_error) && ...);
	}

	template <size_t I>
	static bool convert_one(const GDExtensionConstVariantPtr *p_args, Args &r_values, GDExtensionCallError *r_error) {
		using T = std::tuple_element_t<I, Args>;
		if (Type<T>::from_variant(p_args[I], std::get<I>(r_values))) {
			return true;
		}
		r_error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
		r_error->argument = static_cast<int32_t>(I);
		r_error->expected = static_cast<int32_t>(Type<T>::kType);
		return false;
	}

	template <size_t... I>
	static void ptrcall_impl([[maybe_unused]] const GDExtensionConstTypePtr *p_args, [[maybe_unused]] GDExtensionTypePtr r_ret,
			std::index_sequence<I...>) {
		if constexpr (kHasReturn) {
			Type<R>::to_ptr(r_ret, Fn(Type<std::decay_t<A>>::from_ptr(p_args[I])...));
		} else {
			Fn(Type<std::decay_t<A>>::from_ptr(p_args[I])...);
		}
	}
};

template <auto Fn>
void bind_method(const char *p_name, std::initializer_list<const char *> p_arg_names) {
	using M = Method<Fn>;
	if (p_arg_names.size() != M::kArgc) {
		warn("lane1_haptics: argument name count mismatch (method not bound)");
		return;
	}
	GDStringName class_name(kClassName);
	GDStringName method_name(p_name);
	GDStringName empty_name("");
	GDString empty_hint;

	std::vector<std::unique_ptr<GDStringName>> arg_names;
	std::vector<GDExtensionPropertyInfo> arg_info;
	const auto types = M::arg_types();
	auto meta = M::arg_meta();
	size_t i = 0;
	for (const char *arg_name : p_arg_names) {
		arg_names.push_back(std::make_unique<GDStringName>(arg_name));
		arg_info.push_back({ types[i], arg_names.back()->ptr(), empty_name.ptr(), 0, empty_hint.ptr(), kPropertyUsageDefault });
		++i;
	}

	GDExtensionPropertyInfo return_info = {};
	GDExtensionClassMethodArgumentMetadata return_meta = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	if constexpr (M::kHasReturn) {
		using R = typename M::Return;
		return_info = { Type<R>::kType, empty_name.ptr(), empty_name.ptr(), 0, empty_hint.ptr(), kPropertyUsageDefault };
		return_meta = Type<R>::kMeta;
	}

	GDExtensionClassMethodInfo info = {};
	info.name = method_name.ptr();
	info.method_userdata = nullptr;
	info.call_func = &M::call;
	info.ptrcall_func = &M::ptrcall;
	info.method_flags = GDEXTENSION_METHOD_FLAGS_DEFAULT;
	info.has_return_value = M::kHasReturn ? 1 : 0;
	info.return_value_info = M::kHasReturn ? &return_info : nullptr;
	info.return_value_metadata = return_meta;
	info.argument_count = static_cast<uint32_t>(M::kArgc);
	info.arguments_info = arg_info.empty() ? nullptr : arg_info.data();
	info.arguments_metadata = M::kArgc == 0 ? nullptr : meta.data();
	info.default_argument_count = 0;
	info.default_arguments = nullptr;
	api.classdb_register_extension_class_method(api.library, class_name.ptr(), &info);
}

// ---------------------------------------------------------------------------------------------------------------
// Bound functions (the backend is process-wide, so the instance pointer is unused).
std::string m_backend_name() { return Core::get().backend_name(); }
bool m_is_supported() { return Core::get().is_supported(); }
bool m_start() { return Core::get().start(); }
void m_stop() { Core::get().stop(); }
bool m_transient(double p_intensity, double p_sharpness) { return Core::get().transient(p_intensity, p_sharpness); }
bool m_continuous(double p_intensity, double p_sharpness, double p_duration) {
	return Core::get().continuous(p_intensity, p_sharpness, p_duration);
}
bool m_register_pattern(const std::string &p_name, const std::string &p_ahap_json) {
	return Core::get().register_pattern(p_name, p_ahap_json);
}
bool m_play_registered(const std::string &p_name) { return Core::get().play_registered(p_name); }
bool m_play_pattern(const std::string &p_ahap_json) { return Core::get().play_pattern(p_ahap_json); }
void m_selection() { Core::get().selection(); }
void m_impact(int64_t p_style, double p_intensity) { Core::get().impact(p_style, p_intensity); }
void m_prepare() { Core::get().prepare(); }
std::string m_thermal_state() { return Core::get().thermal_state(); }
bool m_is_low_power_mode() { return Core::get().is_low_power_mode(); }
int64_t m_thermal_change_count() { return Core::get().thermal_change_count(); }
std::string m_debug_state() { return Core::get().debug_state(); }
std::string m_build_info() {
	return std::string("lane1_haptics ") + LANE1_HAPTICS_VERSION + " backend=" + Core::get().backend_name() + " api=4.7 (C interface)";
}

// ---------------------------------------------------------------------------------------------------------------
// Class lifecycle.
struct Instance {
	GDExtensionObjectPtr owner = nullptr;
};

GDExtensionObjectPtr create_instance(void * /*class_userdata*/, GDExtensionBool p_notify_postinitialize) {
	GDStringName parent(kParentClass);
	GDStringName class_name(kClassName);
	// 4.7 contract (classdb_construct_object3 / GDExtensionClassCreateInstance3): a RefCounted comes back with a
	// refcount of 1 and that reference is handed to the engine unchanged — the same sequence godot-cpp 10 uses.
	GDExtensionObjectPtr object = api.classdb_construct_object3(parent.ptr());
	if (object == nullptr) {
		return nullptr;
	}
	auto *instance = new Instance{ object };
	api.object_set_instance(object, class_name.ptr(), instance);
	Core::get().on_instance_created();
	if (p_notify_postinitialize && api.object_notification != nullptr) {
		int64_t what = kNotificationPostinitialize;
		GDExtensionBool reversed = 0;
		GDExtensionConstTypePtr args[2] = { &what, &reversed };
		api.object_method_bind_ptrcall(api.object_notification, object, args, nullptr);
	}
	return object;
}

void free_instance(void * /*class_userdata*/, GDExtensionClassInstancePtr p_instance) {
	delete static_cast<Instance *>(p_instance);
	Core::get().on_instance_freed();
}

GDExtensionClassCallVirtual get_virtual(void * /*class_userdata*/, GDExtensionConstStringNamePtr /*name*/, uint32_t /*hash*/) {
	return nullptr;
}

void register_class() {
	GDStringName class_name(kClassName);
	GDStringName parent(kParentClass);
	GDExtensionClassCreationInfo6 info = {};
	info.is_virtual = 0;
	info.is_abstract = 0;
	info.is_exposed = 1;
	info.is_runtime = 0;
	info.icon_path = nullptr;
	info.create_instance_func = &create_instance;
	info.free_instance_func = &free_instance;
	info.get_virtual_func = &get_virtual;
	info.class_userdata = nullptr;
	api.classdb_register_extension_class6(api.library, class_name.ptr(), parent.ptr(), &info);

	bind_method<&m_backend_name>("backend_name", {});
	bind_method<&m_is_supported>("is_supported", {});
	bind_method<&m_start>("start", {});
	bind_method<&m_stop>("stop", {});
	bind_method<&m_transient>("transient", { "intensity", "sharpness" });
	bind_method<&m_continuous>("continuous", { "intensity", "sharpness", "duration" });
	bind_method<&m_register_pattern>("register_pattern", { "name", "ahap_json" });
	bind_method<&m_play_registered>("play_registered", { "name" });
	bind_method<&m_play_pattern>("play_pattern", { "ahap_json" });
	bind_method<&m_selection>("selection", {});
	bind_method<&m_impact>("impact", { "style", "intensity" });
	bind_method<&m_prepare>("prepare", {});
	bind_method<&m_thermal_state>("thermal_state", {});
	bind_method<&m_is_low_power_mode>("is_low_power_mode", {});
	bind_method<&m_thermal_change_count>("thermal_change_count", {});
	bind_method<&m_debug_state>("debug_state", {});
	bind_method<&m_build_info>("build_info", {});
}

void initialize(void * /*userdata*/, GDExtensionInitializationLevel p_level) {
	if (p_level != GDEXTENSION_INITIALIZATION_SCENE) {
		return;
	}
	register_class();
	if (api.object_notification == nullptr) {
		GDStringName object_class("Object");
		GDStringName notification("notification");
		api.object_notification = api.classdb_get_method_bind(object_class.ptr(), notification.ptr(), kObjectNotificationHash);
	}
}

void deinitialize(void * /*userdata*/, GDExtensionInitializationLevel p_level) {
	if (p_level != GDEXTENSION_INITIALIZATION_SCENE) {
		return;
	}
	Core::shutdown();
	GDStringName class_name(kClassName);
	api.classdb_unregister_extension_class(api.library, class_name.ptr());
}

bool load_api() {
	bool ok = true;
	ok &= load_proc(api.print_warning, "print_warning");
	ok &= load_proc(api.string_name_new_with_latin1_chars, "string_name_new_with_latin1_chars");
	ok &= load_proc(api.string_new_with_utf8_chars_and_len2, "string_new_with_utf8_chars_and_len2");
	ok &= load_proc(api.string_to_utf8_chars, "string_to_utf8_chars");
	ok &= load_proc(api.variant_get_ptr_destructor, "variant_get_ptr_destructor");
	ok &= load_proc(api.get_variant_from_type_constructor, "get_variant_from_type_constructor");
	ok &= load_proc(api.get_variant_to_type_constructor, "get_variant_to_type_constructor");
	ok &= load_proc(api.variant_get_type, "variant_get_type");
	ok &= load_proc(api.variant_destroy, "variant_destroy");
	ok &= load_proc(api.classdb_construct_object3, "classdb_construct_object3");
	ok &= load_proc(api.object_set_instance, "object_set_instance");
	ok &= load_proc(api.classdb_register_extension_class6, "classdb_register_extension_class6");
	ok &= load_proc(api.classdb_register_extension_class_method, "classdb_register_extension_class_method");
	ok &= load_proc(api.classdb_unregister_extension_class, "classdb_unregister_extension_class");
	ok &= load_proc(api.classdb_get_method_bind, "classdb_get_method_bind");
	ok &= load_proc(api.object_method_bind_ptrcall, "object_method_bind_ptrcall");
	if (!ok) {
		warn("lane1_haptics: Godot is missing a GDExtension interface function (needs 4.7+); IOSHaptics not registered");
		return false;
	}
	api.string_destructor = api.variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_STRING);
	api.string_name_destructor = api.variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_STRING_NAME);
	api.variant_from_bool = api.get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_BOOL);
	api.variant_from_int = api.get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_INT);
	api.variant_from_float = api.get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_FLOAT);
	api.variant_from_string = api.get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_STRING);
	api.bool_from_variant = api.get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_BOOL);
	api.int_from_variant = api.get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_INT);
	api.float_from_variant = api.get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_FLOAT);
	api.string_from_variant = api.get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_STRING);
	return api.string_destructor && api.string_name_destructor && api.variant_from_bool && api.variant_from_int &&
			api.variant_from_float && api.variant_from_string && api.bool_from_variant && api.int_from_variant &&
			api.float_from_variant && api.string_from_variant;
}

} // namespace

// Entry symbol named in haptics.gdextension. On iOS the library is linked statically and Godot's generated
// dummy.cpp registers this symbol by name (weak reference + -Wl,-U, so a stub build still links).
extern "C" LANE1_HAPTICS_EXPORT GDExtensionBool lane1_haptics_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	api.get_proc_address = p_get_proc_address;
	api.library = p_library;
	if (!load_api()) {
		return 0;
	}
	r_initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	r_initialization->userdata = nullptr;
	r_initialization->initialize = &initialize;
	r_initialization->deinitialize = &deinitialize;
	return 1;
}
