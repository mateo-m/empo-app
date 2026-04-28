// mkxp_setjmp_arm64.S
//
// Replacement for Apple's _setjmp / _longjmp used by Ruby 1.8's
// green-thread implementation in eval.c. Apple's setjmp signs the
// saved link register with PACIBSP (using SP as the modifier);
// _longjmp then verifies via AUTIBSP. Ruby 1.8's threading
// longjmps onto a *different* stack (it allocates a per-thread
// stack region and swaps SP), so the modifier doesn't match and
// PAC verification fails - SEGV in rb_thread_s_new on iOS arm64.
//
// JoiPlay's libmkxp18.so works on Android arm64 because Android
// (bionic) doesn't sign jmp_buf LR. To match that behavior on
// iOS we provide our own setjmp/longjmp that save/restore LR
// raw, no PAC.
//
// We DO save/restore the standard arm64 callee-saved set:
//   x19-x28   general-purpose
//   x29 (FP)  frame pointer
//   x30 (LR)  link register (raw, unsigned)
//   sp        stack pointer
//   d8-d15    SIMD/FP regs (lower 64 bits, callee-saved)
//
// Layout (160 bytes, fits within Apple's 200-byte jmp_buf):
//     0  x19, x20
//    16  x21, x22
//    32  x23, x24
//    48  x25, x26
//    64  x27, x28
//    80  x29, x30
//    96  sp
//   104  d8, d9
//   120  d10, d11
//   136  d12, d13
//   152  d14, d15

#if defined(__aarch64__) || defined(__arm64__)

    .text
    .p2align 2

    .globl _mkxp_ruby18_setjmp
_mkxp_ruby18_setjmp:
    stp x19, x20, [x0,  #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]
    mov x9, sp
    str x9,       [x0, #96]
    stp d8,  d9,  [x0, #104]
    stp d10, d11, [x0, #120]
    stp d12, d13, [x0, #136]
    stp d14, d15, [x0, #152]
    mov w0, wzr           // setjmp returns 0
    ret


    .globl _mkxp_ruby18_longjmp
_mkxp_ruby18_longjmp:
    // DEBUG: log entry. Save callee-saved scratch first.
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x0, x1, [sp, #16]    // save jmp_buf and val for after log
    adrp x0, Lmkxp_lj_tag@PAGE
    add  x0, x0, Lmkxp_lj_tag@PAGEOFF
    adrp x1, Lmkxp_lj_src@PAGE
    add  x1, x1, Lmkxp_lj_src@PAGEOFF
    adrp x2, Lmkxp_lj_msg@PAGE
    add  x2, x2, Lmkxp_lj_msg@PAGEOFF
    bl   _mkxp_debugLog
    ldp x0, x1, [sp, #16]    // restore jmp_buf and val
    ldp x29, x30, [sp], #32

    ldp x19, x20, [x0,  #0]
    ldp x21, x22, [x0, #16]
    ldp x23, x24, [x0, #32]
    ldp x25, x26, [x0, #48]
    ldp x27, x28, [x0, #64]
    ldp x29, x30, [x0, #80]
    ldr x9,       [x0, #96]
    mov sp, x9
    ldp d8,  d9,  [x0, #104]
    ldp d10, d11, [x0, #120]
    ldp d12, d13, [x0, #136]
    ldp d14, d15, [x0, #152]
    // longjmp returns val to setjmp, but if val == 0 it returns 1
    // (so the caller can always distinguish initial vs longjmp).
    mov w2, #1
    cmp w1, #0
    csel w0, w1, w2, ne
    ret                   // br x30, no PAC verify

    .section __TEXT,__cstring,cstring_literals
Lmkxp_lj_tag:
    .asciz "MKXP18-ASM"
Lmkxp_lj_src:
    .asciz "longjmp"
Lmkxp_lj_msg:
    .asciz "asm longjmp entry, about to restore registers"
    .text

#endif
