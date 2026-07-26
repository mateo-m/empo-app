// Ruby island static-entry stubs.
//
// The engine's instance manager (mkxp-z-apple-mobile/src/
// ruby_instance.cpp) references one static entry point per Ruby
// version as its last-resort fallback when no RubyIsland<NN>
// framework is present. Empo ships the islands exclusively as
// dlopen'd frameworks (see the "Embed Ruby island frameworks" build
// phase in project.yml), so the static entries resolve to these
// NULL-returning stubs: the manager sees "no static island" and uses
// the frameworks. Builds whose dep tree lacks the frameworks still
// link and run; game sessions then fail at acquire with a clear
// engine error instead of an undefined-symbol link failure.

struct ScriptBinding;

struct ScriptBinding *mkxp_get_script_binding_18(void) { return 0; }
struct ScriptBinding *mkxp_get_script_binding_19(void) { return 0; }
struct ScriptBinding *mkxp_get_script_binding_31(void) { return 0; }
