# Architecture

The full architecture is specified in
[`../Orca_Full_Implementation_Plan_v1.0.md`](../Orca_Full_Implementation_Plan_v1.0.md).
Focused architecture decisions will be recorded here as subsystem contracts
become executable.

The non-negotiable boundary is that `liborca` owns all music, library, audio,
metadata, mutation, and job behavior. Applications are clients of its public Zig
API or controlled C ABI.
