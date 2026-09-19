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

int psdk_run(const char *gameDir, const char *preludePath) {
    if (!gameDir || chdir(gameDir) != 0) {
        fprintf(stderr, "[psdk] cannot enter %s\n", gameDir ? gameDir : "(null)");
        return PSDK_CHDIR_FAILED;
    }

    {
        int argc = 0;
        char **argv = nullptr;
        ruby_sysinit(&argc, &argv);
    }
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
    if (loadRubyFile("Game.rb") != 0) {
        return PSDK_GAME_RAISED;
    }
    return PSDK_OK;
}

void psdk_inject_scancode(int scancode, int pressed) {
    sfml_ios_inject_key_event(scancode, pressed);
}
