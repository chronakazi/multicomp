package plugin

import clap "proj:clap-odin"
import ext "proj:clap-odin/ext"

// State format
//
//   magic    [4]u8  "MCMP"
//   version  u32    STATE_VERSION
//   count    u32    number of parameter entries that follow
//   entries  count x { id: u32, value: f64 }
//
// Parameters are stored as explicit (id, value) pairs rather than a positional array.
// That is what makes the format survive the parameter set changing: an id we no longer
// recognise is skipped, and a parameter absent from an old session keeps its default.
// Reordering PARAMS can therefore never silently corrupt a saved session.

STATE_MAGIC :: [4]u8{'M', 'C', 'M', 'P'}
STATE_VERSION :: u32(1)

state_ext := ext.Plugin_State {
	save = proc "c" (plugin: ^clap.Plugin, stream: ^clap.Ostream) -> bool {
		self := from_plugin(plugin)

		magic := STATE_MAGIC
		if !write_full(stream, &magic, size_of(magic)) {
			return false
		}

		version := STATE_VERSION
		if !write_full(stream, &version, size_of(version)) {
			return false
		}

		count := u32(len(PARAMS))
		if !write_full(stream, &count, size_of(count)) {
			return false
		}

		for _, id in PARAMS {
			entry_id := u32(id)
			value := self.values[id]
			if !write_full(stream, &entry_id, size_of(entry_id)) {
				return false
			}
			if !write_full(stream, &value, size_of(value)) {
				return false
			}
		}
		return true
	},

	load = proc "c" (plugin: ^clap.Plugin, stream: ^clap.Istream) -> bool {
		self := from_plugin(plugin)

		magic: [4]u8
		if !read_full(stream, &magic, size_of(magic)) {
			return false
		}
		if magic != STATE_MAGIC {
			return false
		}

		version: u32
		if !read_full(stream, &version, size_of(version)) {
			return false
		}
		if version > STATE_VERSION {
			return false // written by a newer build than this one
		}

		count: u32
		if !read_full(stream, &count, size_of(count)) {
			return false
		}

		// Anything the saved state does not mention keeps its default.
		reset_to_defaults(self)

		for _ in 0 ..< count {
			entry_id: u32
			value: f64
			if !read_full(stream, &entry_id, size_of(entry_id)) {
				return false
			}
			if !read_full(stream, &value, size_of(value)) {
				return false
			}
			if !is_valid_param(entry_id) {
				continue // parameter removed in a later version; ignore it
			}
			id := Param_Id(entry_id)
			self.values[id] = clamp_param(id, value)
		}

		// A loaded lookahead only takes effect on the next activation, because latency
		// is latched while active. If the value disagrees with the latched latency,
		// announce it and ask for a restart - the same path an automation edit takes.
		// Inactive plugins need nothing: activate latches the loaded value.
		if self.activated && lookahead_samples(self) != self.latency_samples {
			request_latency_update(self)
		}
		return true
	},
}

// Hosts may satisfy a read or write partially, so both directions have to loop.
// The validator exercises this with deliberately tiny chunk sizes.
write_full :: proc "contextless" (stream: ^clap.Ostream, data: rawptr, size: int) -> bool {
	bytes := ([^]u8)(data)
	written := 0
	for written < size {
		n := stream.write(stream, &bytes[written], u64(size - written))
		if n <= 0 {
			return false
		}
		written += int(n)
	}
	return true
}

read_full :: proc "contextless" (stream: ^clap.Istream, data: rawptr, size: int) -> bool {
	bytes := ([^]u8)(data)
	read := 0
	for read < size {
		n := stream.read(stream, &bytes[read], u64(size - read))
		if n <= 0 {
			return false // 0 is end of file, -1 is an error; both are failures here
		}
		read += int(n)
	}
	return true
}
