package plugin

import "base:runtime"

import clap "proj:clap-odin"
import "proj:src/dsp"

PLUGIN_ID :: "com.foesoft.multicomp"
PLUGIN_NAME :: "MultiComp"
PLUGIN_VENDOR :: "foesoft"
PLUGIN_VERSION :: "0.1.0"

// NULL-terminated, as the C API requires.
features := [?]cstring {
	clap.PLUGIN_FEATURE_AUDIO_EFFECT,
	clap.PLUGIN_FEATURE_COMPRESSOR,
	clap.PLUGIN_FEATURE_STEREO,
	nil,
}

descriptor := clap.Plugin_Descriptor {
	clap_version = clap.CLAP_VERSION,
	id           = PLUGIN_ID,
	name         = PLUGIN_NAME,
	vendor       = PLUGIN_VENDOR,
	url          = "https://example.invalid",
	manual_url   = "https://example.invalid",
	support_url  = "https://example.invalid",
	version      = PLUGIN_VERSION,
	description  = "Compressor",
	// `features` is filled in from clap_entry.init — taking the address of another
	// global is not something we can do in a global initialiser.
}

factory := clap.Plugin_Factory {
	get_plugin_count = proc "c" (factory: ^clap.Plugin_Factory) -> u32 {
		return 1
	},

	get_plugin_descriptor = proc "c" (
		factory: ^clap.Plugin_Factory,
		index: u32,
	) -> ^clap.Plugin_Descriptor {
		return index == 0 ? &descriptor : nil
	},

	create_plugin = proc "c" (
		factory: ^clap.Plugin_Factory,
		host: ^clap.Host,
		plugin_id: cstring,
	) -> ^clap.Plugin {
		context = runtime.default_context()
		if string(plugin_id) != PLUGIN_ID {
			return nil
		}

		self := new(Multicomp)
		self.host = host
		reset_to_defaults(self)

		// The meter slots decode zero bits as 0 dBFS, so a freshly created plugin would
		// otherwise show a phantom full-scale reading until audio decayed it away.
		publish(&self.meter_in, dsp.SILENCE_DB)
		publish(&self.meter_out, dsp.SILENCE_DB)

		self.plugin = clap.Plugin {
			desc             = &descriptor,
			plugin_data      = self,
			init             = init,
			destroy          = destroy,
			activate         = activate,
			deactivate       = deactivate,
			start_processing = start_processing,
			stop_processing  = stop_processing,
			reset            = reset,
			process          = process,
			get_extension    = get_extension,
			on_main_thread   = on_main_thread,
		}
		return &self.plugin
	},
}

// The one exported symbol. `@(export)` on a package-level variable named `clap_entry`
// produces the `_clap_entry` data symbol that hosts dlsym for.
// Verify with: nm -gU build/multicomp.dylib | grep clap_entry
@(export)
clap_entry := clap.Plugin_Entry {
	clap_version = clap.CLAP_VERSION,
	init = proc "c" (plugin_path: cstring) -> bool {
		descriptor.features = raw_data(features[:])
		return true
	},
	deinit = proc "c" () {},
	get_factory = proc "c" (factory_id: cstring) -> rawptr {
		context = runtime.default_context()
		return string(factory_id) == clap.PLUGIN_FACTORY_ID ? &factory : nil
	},
}
