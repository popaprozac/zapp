// C3 interop + size probe for Zapp's native-language eval.
//
// Mirrors Zapp's darwin/*.m C-ABI surface (ObjC behind plain C):
//   orchestration lang -> C ABI -> ObjC. C3 has no C-header import; we
//   hand-declare the two externs that the prebuilt probe_cocoa.o exports.
module spike;

import std::io;
import std::io::file;
import std::encoding::json;

// --- C interop: hand-declared externs for probe_cocoa.o / probe_stub.c -------
// C3 doesn't consume probe.h; the symbol name is taken from the fn name and
// ZString is `inline char*`, so it bridges directly to C `const char*`.
extern fn void spike_cocoa_open_window(int w, int h, ZString title);
extern fn void spike_print_windows();

fn void main()
{
	// --- JSON: parse sample.json with C3's stdlib (std::encoding::json) -------
	// Defaults so an unreadable/malformed config still produces a window.
	int w = 640;
	int h = 480;
	String title = "zapp-spike";

	if (try data = file::load_temp("spikes/lang-eval/shared/sample.json"))
	{
		// json::tparse returns a temp-allocated Object* tagged union.
		if (try cfg = json::tparse((String)data))
		{
			// JSON numbers parse as floats; get_int/get_string coerce + type-check.
			if (try v = cfg.get_int("w")) w = v;
			if (try v = cfg.get_int("h")) h = v;
			if (try v = cfg.get_string("title")) title = v;
		}
	}

	// --- Compile-time platform branch (env::DARWIN, dead branch elided) -------
	$if env::DARWIN:
		spike_cocoa_open_window(w, h, title.zstr_tcopy());
	$else
		spike_print_windows();
	$endif
}
