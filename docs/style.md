# C++ style

How Orca's C++ is written. It follows [Tiger
Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md),
adapted to C++23 and to Orca's shape: a library with external dependencies,
a database, and a real-time audio thread. Design goals in order: safety,
performance, developer experience. `clang-format` decides formatting; this
page governs everything the formatter cannot.

## Safety

- Put a limit on everything. Every loop, queue, page, retry count and
  response size has a fixed upper bound, and reaching the bound is an
  error, never a clamp. Where a loop must not terminate (the host event
  loop), say so with an `ORCA_ASSERT` beside it.
- Use explicitly-sized types everywhere: `std::uint32_t`, not `unsigned`
  or `size_t`, for anything that is stored, transmitted or persisted.
  `size_t` is for in-memory spans only.
- No recursion. Every path that could recurse is rewritten with an
  explicit bound.
- Assertions detect programmer errors and crash the process; operating
  errors are expected and return `orca::expected`. Never assert what a
  caller could legitimately get wrong, and never return what only a
  broken program could produce.
- Assert function arguments, return values and invariants with
  `ORCA_ASSERT`; assert preconditions that also run in release with
  `ORCA_CHECK`. Meaty functions average at least two assertions.
- Pair assertions: check data on both sides of a boundary — before
  writing and after reading, before dispatch and in the worker.
- Assert the positive space you expect and the negative space you do
  not. State invariants positively:

  ```cpp
  if (index < count) {
  } else {
      ORCA_ASSERT(false && "index past count");
  }
  ```

- `static_assert` the relationships of compile-time constants, struct
  sizes and every ABI layout, and split compound assertions into one
  condition each.
- Declare variables at the smallest possible scope and introduce them
  only where they are used.
- A function fits in 70 lines, hard limit. Split by pushing `if`s up
  into the parent and `for`s down into helpers; the parent owns all
  control flow and the leaves stay pure.
- Split compound conditions into nested `if`/`else`; write `else { if
  () {} }` instead of `else if` chains, so every branch shows its
  negative space.
- Braces on every `if`, `for` and `while`, even single statements.
- The render callback never allocates, frees, locks, waits, performs I/O
  or touches SQLite. It and the code it calls are the data plane;
  everything else is control plane and may assume it.

## Errors

- Fallible functions return `orca::expected<T>`; every error is handled
  at some level, including in tests. A switch over an `enum class`
  covers every case with no `default`.
- Simpler return types win: `void` over `bool` over an integer over
  `std::optional` over `orca::expected`.
- Arithmetic that can overflow goes through `orca::checked` and its
  result is handled like any other error; silent wraparound is a bug.
- Exceptions are for gtkmm and nothing else: engine code never throws,
  and nothing throws across the C ABI.

## Naming

- `snake_case` for files, functions and variables; `PascalCase` for
  types (`Id3Tag`, `TrackQueue`). No abbreviations. Acronyms keep their
  capitals in type names (`Id3Tag`, not `IdThreeTag` or `Id3tag`).
  (Type naming deviates from Tiger Style, which snake_cases types in
  Zig; recorded here once.)
- Units and qualifiers go last, sorted by descending significance:
  `latency_ms_max`, `track_count`, `queue_index_max`. An `index` is
  0-based, a `count` is 1-based, a `size` is a count times its unit;
  the three never mix without a named conversion.
- Related names have matching length so lines line up: `source` and
  `target`, `source_offset` and `target_offset`.
- Callbacks and callables go last in a parameter list. A helper called
  from one place is prefixed with its caller: `read_sector` and
  `read_sector_callback`.
- A class is ordered fields, then types, then methods, most important
  first. When order does not matter, sort alphabetically.
- Never overload a name with a second meaning that the codebase already
  uses.

## Cache invalidation

- Do not duplicate or alias state; derive it where it is used or name
  the relationship.
- Pass anything larger than two machine words as `const&`; a by-value
  parameter is a copy and must be intended.
- Construct large objects in place (`emplace`, out-parameters) instead
  of moving intermediate copies.
- Group a resource's acquisition and its RAII release with blank lines
  so leaks stand out.
- Zero padding that leaves a buffer partially used; a read never
  returns uninitialized bytes.

## Performance

- Sketch the cost of a design against the four resources — network,
  disk, memory, CPU — before writing it, and batch work so the slow
  ones are amortized.
- Extract hot loops into standalone functions over primitive types, so
  the reader and the compiler both see what is invariant.
- Bounds and batching are the first optimization; the render path and
  the write lane are the second.

## Testing

- Test the negative space: every suite covers valid input, invalid
  input, and valid input becoming invalid at each boundary.
- Tests use injected transports, clocks and local mocks, never live
  services or wall-clock sleeps.
- Every parser and every on-disk format gets a fuzz target; assertions
  are what make the fuzzer productive.

## Comments

Orca deviates from Tiger Style here: comments are rare. Write one only
for a non-obvious constraint whose removal would break something badly.
When one exists it is a complete sentence that says why. The workings
and the rationale live where Tiger Style says they are read: the commit
message body and the opening description of each test.

## Formatting

`clang-format` at the repository root is the only formatter and its
output is not up for debate. It sets 4-space indent and a 100-column
limit. Braces attach to the statement (a deliberate deviation from
Tiger Style's Zig layout; recorded here once).

## Dependencies

Orca deviates from Tiger Style's zero-dependency policy: dependencies
are chosen on technical merit, kept to the minimum set, and pinned by
commit; the repository holds no third-party source. Everything else in
this page applies to the code Orca writes itself.
