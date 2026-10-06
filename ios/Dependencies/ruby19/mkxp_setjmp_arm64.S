// mkxp_setjmp_arm64.S (Ruby 1.9)
//
// Thunks that tail-call Apple's libc _setjmp / _longjmp.
//
// Earlier versions of this file rolled a hand-written
// register save/restore on the theory that Apple's _setjmp
// signs LR with PACIBSP and Ruby fibers longjmp onto a
// different stack. On arm64 (not arm64e) the PAC ops are
// hint NOPs, so the PAC concern is moot for the binaries we
// ship. Forwarding to libc is simpler, matches what
// pulsejet/android-mkxp does on Android (which plays the
// same legacy-grammar games without crashing), and removes
// any risk that our hand-rolled asm misses a callee-saved
// register or alignment quirk that Apple's implementation
// handles correctly.
//
// `b` is a tail call: LR is unchanged from the caller of
// our thunk, so when _setjmp / _longjmp do `ret` they
// return to / branch to the caller of mkxp_ruby19_setjmp /
// mkxp_ruby19_longjmp respectively.

#if defined(__aarch64__) || defined(__arm64__)

    .text
    .p2align 2

    .globl _mkxp_ruby19_setjmp
_mkxp_ruby19_setjmp:
    b _setjmp

    .globl _mkxp_ruby19_longjmp
_mkxp_ruby19_longjmp:
    b _longjmp

#endif
