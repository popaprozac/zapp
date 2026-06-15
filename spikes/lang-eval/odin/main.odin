package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:encoding/json"

// Hand-declared C ABI surface (Odin has no C-header import; declare the
// symbols directly). The relative path resolves the prebuilt ObjC object
// file from the source-file location at link time.
foreign import probe "../shared/probe_cocoa.o"

@(default_calling_convention="c")
foreign probe {
	spike_cocoa_open_window :: proc(w, h: i32, title: cstring) ---
	spike_print_windows :: proc() ---
}

main :: proc() {
	// Defaults; overwritten by the real parse below.
	w: i32 = 640
	h: i32 = 480
	title_str := "zapp-spike"

	// os.read_entire_file requires an explicit allocator in this Odin version
	// and returns (data: []byte, err: os.Error) — err is a union, compare to nil.
	data, read_err := os.read_entire_file(
		"spikes/lang-eval/shared/sample.json",
		context.allocator,
	)
	if read_err != nil {
		fmt.eprintln("[spike] could not read sample.json:", read_err)
		os.exit(1)
	}
	defer delete(data)

	// json.parse returns (Value, Error). With parse_integers=false (default)
	// every JSON number decodes as json.Float (f64) — even integers — so we
	// cast to i32. Value is a union; Object is distinct map[string]Value.
	value, err := json.parse(data)
	if err != nil {
		fmt.eprintln("[spike] json parse error:", err)
		os.exit(1)
	}
	defer json.destroy_value(value)

	if obj, obj_ok := value.(json.Object); obj_ok {
		if v, has := obj["w"]; has {
			if f, fok := v.(json.Float); fok {
				w = i32(f)
			}
		}
		if v, has := obj["h"]; has {
			if f, fok := v.(json.Float); fok {
				h = i32(f)
			}
		}
		if v, has := obj["title"]; has {
			if s, sok := v.(json.String); sok {
				title_str = s
			}
		}
	}

	title := strings.clone_to_cstring(title_str)
	defer delete(title)

	when ODIN_OS == .Darwin {
		spike_cocoa_open_window(w, h, title)
	} else {
		spike_print_windows()
	}
}
