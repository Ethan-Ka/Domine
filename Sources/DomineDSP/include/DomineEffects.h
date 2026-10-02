#ifndef DOMINE_EFFECTS_H
#define DOMINE_EFFECTS_H

// Effect module contract (SPEC section 5a). Every built-in effect (EQ, bass
// enhancer, compressor/limiter) follows this shape, with X the module's type
// and x its function prefix:
//
//   typedef struct X X;
//   X *x_create(double sampleRate);               // allocates; not real-time
//   void x_destroy(X *x);                         // frees; NULL is safe
//   void x_set_params(X *x, const XParams *p);    // any thread, never blocks
//   void x_process(X *x, float *samples, uint32_t frames); // in place, one
//                                                 // position's mono stream
//
// Rules:
//   - x_create and x_destroy are the only functions that allocate or free.
//     The kernel calls them from domine_kernel_create and
//     domine_kernel_destroy, never while an IOProc is running.
//   - x_set_params may be called from any thread (one writer at a time).
//     Parameters cross to the render thread through C11 atomics only: a
//     seqlock over atomic words, or a double buffer swapped by an atomic
//     index. The render thread never waits and never sees a torn set.
//   - x_process is real-time safe: no allocation, no locks, no logging, no
//     I/O, no Objective-C or Swift. It picks up new parameters itself and
//     must smooth changes (about 10 ms) so they cause no zipper noise or
//     step discontinuity. Any frame count, including 1, is valid.
//   - A disabled module, or one whose parameters make it a no-op, leaves the
//     samples bit for bit unchanged once any smoothing has settled. Disabling
//     fades to the no-op state rather than switching abruptly.
//   - int x_is_idle(const X *x) (expected) returns nonzero when the module is
//     settled in that no-op state with no pending parameters, so the kernel
//     can skip the call entirely.
//   - The module owns one mono stream. The kernel creates one instance per
//     output position (A and B) so the two sides never share state.
//   - Each module has its own header, DomineX.h, listed in module.modulemap
//     and included by DomineDSP.h, and its own source file x.c.

#include <stdint.h>

#endif
