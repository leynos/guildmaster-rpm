"""Bounded state-space check of the build, publication and cleanup machine.

**This is a bounded check, not a proof.** It samples a finite, seeded set of
scenarios and interleavings, so a pass demonstrates the absence of a violation
across whatever was sampled, and nothing more.

It has two layers, and they check different things:

*   An executed layer that drives the real ``scripts/build-rpm.sh`` and
    ``scripts/clean.sh`` through stub commands and FIFOs, over a generated
    combination of cache states, container-phase outcomes, publication modes
    and clean positions. What it checks is the shell code as written.
*   An abstract layer that models the same algorithm as a small transition
    system and samples interleavings of up to two concurrent builds and a
    clean. **This is an abstract model, not the executed script**: it is a
    hand-written transition system that can agree with the documentation and
    disagree with the shell. It covers what cannot be driven directly —
    arbitrary interleavings of two builds' internal steps against a clean.

Both layers are deterministic given a seed, which is printed on every run and
reported again with the offending case on failure. Neither layer needs a
network or a container runtime.

The fixed FIFO cases in ``test-build-rpm.sh`` remain the regression tests for
specific past defects; this checker is a breadth sweep over their state space,
not a replacement for them.

Invariants, stated once here and asserted in both layers:

I1  An observable published output is either absent — and then only while a
    fallback publication is between moving the previous output aside and
    promoting the new one, or after a failure that left nothing published —
    or exactly one complete generation. Never a partial or mixed set.
I2  Clean never removes the published output or the cache while any activity
    lock is held.
I3  A successful rollback restores the prior complete output; a failed one
    retains it as recovery data.
I4  A failed or cancelled invocation leaves no invocation-owned staging
    directory, no invocation-owned temporary tarball, no container or image
    of its own, and no held lock.

Two further guards keep a pass meaningful:

*   Non-vacuity: the abstract layer must actually reach publication
    contention, the fallback's absent window, and a retained-recovery state.
    A run that reached none of them proves nothing, and fails.
*   Self-test: deliberately broken models are run through the same checker,
    which must reject every one of them.
"""

from __future__ import annotations
