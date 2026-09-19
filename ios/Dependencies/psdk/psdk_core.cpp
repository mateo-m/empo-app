#include "psdk_core.h"

#include "ruby.h"

#include <string>
#include <unistd.h>

extern "C" void Init_LiteRGSS();

// SFML's iOS input backend keeps a scancode bitset that polling engines
// read, and a UIKit event queue that event-driven engines read. LiteRGSS
// reads both, so the shim below fills both. It lives in
// sources/sfml/src/SFML/Window/iOS/InputImpl.mm.
extern "C" void sfml_ios_inject_key_event(int sfScan, int pressed);

namespace {

int loadRubyFile(const std::string &path) {
    int state = 0;
    rb_protect(
        [](VALUE arg) -> VALUE {
            rb_load(arg, 0);
            return Qnil;
        },
        rb_str_new_cstr(path.c_str()), &state);
    if (state == 0) {
        return 0;
    }
    VALUE error = rb_errinfo();
    rb_set_errinfo(Qnil);
    // A released PSDK game calls `exit` on a clean quit. That arrives
    // here as SystemExit, which is not a failure.
    if (!NIL_P(error) && rb_obj_is_kind_of(error, rb_eSystemExit)) {
        return 0;
    }
    if (!NIL_P(error)) {
        VALUE message = rb_funcall(error, rb_intern("message"), 0);
        fprintf(stderr, "[psdk] %s raised %s: %s\n", path.c_str(),
                rb_obj_classname(error), StringValueCStr(message));
    }
    return -1;
}

} // namespace

int psdk_run(int argc, char **argv, const char *gameDir, const char *supportDir,
             const char *preludePath) {
    if (!supportDir || !supportDir[0]) {
        fprintf(stderr, "[psdk] no support folder\n");
        return PSDK_SUPPORT_MISSING;
    }

    // PSDK builds the path to its native extensions from this, as
    // "#{ENV['GAMEDEPS']}/ruby-dist/lib" on macOS. The support folder
    // holds an empty LiteRGSS.rb there, so PSDK's require succeeds
    // against the classes Init_LiteRGSS already registered.
    //
    // Set before ruby_options. ruby_init_setproctitle replaces environ
    // with a copy of its own, so a later setenv is not safe.
    setenv("GAMEDEPS", supportDir, 1);

    if (!gameDir || chdir(gameDir) != 0) {
        fprintf(stderr, "[psdk] cannot enter %s\n", gameDir ? gameDir : "(null)");
        return PSDK_CHDIR_FAILED;
    }

    // The real argv, not a made-up one. Ruby writes the process title
    // into the argv region on a `$0 =`, and the kernel's argv is the only
    // block that is writable and next to the environment. With a stack
    // array of string literals instead, that write lands in read-only
    // memory and the process stops with a bus error.
    ruby_sysinit(&argc, &argv);
    RUBY_INIT_STACK;
    ruby_init();

    // The `-e ` argument gives ruby_options an empty script to finish
    // setup with (default encoding, $0, ARGV) without running anything.
    // mkxp-z's binding-mri.cpp uses the same trick.
    const char *rubyArgs[] = {"psdk", "-EUTF-8", "-e ", nullptr};
    int state = 0;
    void *node = ruby_options(3, const_cast<char **>(rubyArgs));
    if (!ruby_executable_node(node, &state) || ruby_exec_node(node) != 0) {
        fprintf(stderr, "[psdk] ruby_options failed\n");
        return PSDK_RUBY_BOOT_FAILED;
    }

    // Ruby was cross-compiled, so its built-in $LOAD_PATH points at a
    // prefix that does not exist on the device. Without this, the game's
    // `require 'uri'` raises LoadError.
    rb_ary_unshift(rb_gv_get("$LOAD_PATH"), rb_str_new_cstr(supportDir));

    // Every released PSDK game runs as `ruby Game.rb`, and its scripts
    // read $0. ruby_script sets it without the process-title hook that a
    // Ruby-level `$0 =` goes through.
    ruby_script("Game.rb");

    Init_LiteRGSS();
    // Registering the classes is not enough. PSDK still calls
    // `require 'LiteRGSS'`, which would search $LOAD_PATH for a shared
    // library and raise LoadError. iOS allows no shared library load, so
    // mark the name satisfied.
    rb_provide("LiteRGSS");

    state = 0;
    VALUE hasModule = rb_eval_string_protect("defined?(LiteRGSS::Sprite) ? true : false", &state);
    if (state != 0 || hasModule != Qtrue) {
        rb_set_errinfo(Qnil);
        fprintf(stderr, "[psdk] LiteRGSS classes are not registered\n");
        return PSDK_LITERGSS_MISSING;
    }

    if (preludePath && preludePath[0] && loadRubyFile(preludePath) != 0) {
        return PSDK_PRELUDE_RAISED;
    }

    // Game.rb is one line in every released PSDK game:
    // `RubyVM::InstructionSequence.load_from_binary(File.binread('Game.yarb')).eval`
    //
    // The full path, not "Game.rb". rb_load searches $LOAD_PATH for a
    // bare name, and the current folder has not been on $LOAD_PATH since
    // Ruby 1.9.2.
    if (loadRubyFile(std::string(gameDir) + "/Game.rb") != 0) {
        return PSDK_GAME_RAISED;
    }
    return PSDK_OK;
}

void psdk_inject_scancode(int scancode, int pressed) {
    sfml_ios_inject_key_event(scancode, pressed);
}
