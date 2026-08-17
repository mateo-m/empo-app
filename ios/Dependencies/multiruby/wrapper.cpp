// multi-Ruby per-version wrapper
//
// Compiled separately for each Ruby version (3.0, 3.1, 1.9, 1.8) and
// merged into that version's mkxp<NN>-merged.o. Exposes ONE
// `extern "C"` function per Ruby version — `mkxp_get_script_binding_<NN>()`
// — that returns a pointer to the version's `ScriptBinding` struct.
//
// This is the only globally-exported symbol from each merged .o.
// Everything else (Ruby's `_rb_*`, mkxp-z binding internals like
// `mriBindingExecute`, `bitmapBindingInit`, etc.) is demoted to
// private-extern by the `ld -r -unexported_symbols_list` step.
// That lets multiple merged .o files (one per Ruby version) coexist
// in the final Empo binary without symbol collisions.
//
// The host (mkxp-z's `EngineHost::runSessions` in main.cpp) calls
// `mkxp_get_script_binding_<NN>()` based on the active game's
// `rubyVersion` tag, then invokes the returned struct's
// `execute()`/`terminate()`/`reset()` function pointers like it
// does for the single-Ruby case today.
//
// MULTIRUBY_SUFFIX is set per build (e.g., `_30`, `_31`). The CPP
// concat trick produces `mkxp_get_script_binding_30()` for 3.0,
// etc.

#include "binding.h"

extern ScriptBinding *scriptBinding;

#define MULTIRUBY_CONCAT_(a, b) a##b
#define MULTIRUBY_CONCAT(a, b)  MULTIRUBY_CONCAT_(a, b)
#define MULTIRUBY_ENTRY \
    MULTIRUBY_CONCAT(mkxp_get_script_binding, MULTIRUBY_SUFFIX)

extern "C" ScriptBinding *MULTIRUBY_ENTRY(void) {
    return scriptBinding;
}
