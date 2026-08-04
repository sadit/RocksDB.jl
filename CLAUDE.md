# RocksDB.jl -- project notes for Claude

This repo has two parts sharing one working directory (both under version
control together, deliberately -- see `bindings/README.md` for why):

1. **`bindings/`** -- a BinaryBuilder.jl recipe (`build_tarballs.jl`) that
   builds RocksDB from source and produces a `RocksDB_jll` artifact.
2. **The `RocksDB` package itself** (`src/`, `test/`, `Project.toml`, ...) --
   a three-tier Julia binding on top of that artifact.

All code/docs are in English. License is MIT throughout (see `LICENSE`).

## `bindings/`: what's built and why

- RocksDB version pinned to **v11.1.2**
  (commit `3b446089141659fad25328c5ea3e7ed283df46e4`).
- Compression: all five backends RocksDB supports via JLLs --
  Snappy, zlib, bzip2, LZ4, Zstd (`snappy_jll`, `Zlib_jll`, `Bzip2_jll`,
  `Lz4_jll`, `Zstd_jll`).
- Extra native features: **io_uring** (Linux only, via `Liburing_jll`) is
  enabled. **jemalloc** was tried per explicit user choice but reverted --
  it causes a reproducible segfault on every `DB::Open` (RocksDB's
  `io_posix.cc` frees a glibc-`getline`-allocated buffer through a
  `je_free`-redefined `free()`, which jemalloc's allocator doesn't
  recognize). This is a real upstream RocksDB/jemalloc incompatibility, not
  specific to this recipe -- full analysis in `bindings/README.md`. Intel
  TBB, NUMA, and sanitizer builds were considered and deliberately left out
  too (documented as future work in `bindings/README.md`).
- Requires `preferred_gcc_version=v"12"` -- RocksDB 11.x uses C++20's
  `using enum`, which needs GCC >= 11; GCC 10 (BinaryBuilder's usual default)
  fails to compile it. If you bump the RocksDB version again, re-check this.
- **Windows and ARM are enabled and locally build-tested** (not just
  present in `platforms` -- actually run through `--deploy=local` end to
  end). ARM (aarch64-linux-gnu) needed no changes: the old Yggdrasil
  `arm64.patch` that force-enables `crc32c_arm64.cc` isn't needed for
  v11.1.2, `HAS_ARMV8_CRC`'s `CHECK_C_COMPILER_FLAG` detection works fine
  under cross-compilation. Windows (x86_64-w64-mingw32) needed two fixes:
  `-DROCKSDB_INSTALL_ON_WINDOWS=1` (RocksDB's CMake gates its whole
  `install()` step behind `if(NOT WIN32 OR ROCKSDB_INSTALL_ON_WINDOWS)`,
  default `OFF` -- without it `cmake --install .` silently no-ops on
  Windows, build succeeds but the tarball ends up empty), and
  `LibraryProduct(["librocksdb", "librocksdb-shared"], :librocksdb)`
  (RocksDB's CMake only renames the shared-lib target to `rocksdb` on
  non-Windows; on Windows it keeps the literal target name `rocksdb-shared`,
  so the DLL is `librocksdb-shared.dll` -- giving `LibraryProduct` both
  names is the standard BinaryBuilder fix, no CMake patch needed). Full
  writeup in `bindings/README.md`'s "Windows and ARM support" section.
- **`RocksDB_jll.jl` already exists upstream**
  (`JuliaBinaryWrappers/RocksDB_jll.jl`, from
  `Yggdrasil/R/RocksDB/build_tarballs.jl`, RocksDB 8.9.1, only
  snappy/lz4/zlib/zstd). This recipe is meant to eventually replace/upgrade
  that one via a Yggdrasil PR -- it is not a differently-named competing
  package. See `bindings/README.md` for the registration path.
- Yggdrasil registration is **deliberately deferred**. For now the recipe is
  only built locally, for the host platform, via
  `julia --project=bindings bindings/build_tarballs.jl --verbose --deploy=local <triplet>`,
  which writes a local `RocksDB_jll` package straight to `~/.julia/dev/`
  (no GitHub release, no registry).

## `bindings/` must be run under Julia 1.10 specifically

`bindings/Manifest.toml` is pinned to Julia 1.10.11 -- BinaryBuilder/Pkg
internals are sensitive to the exact Julia version (CI hit this too: `pre`/
nightly Julia fails deep in BinaryBuilder with `MethodError: no method
matching registry_info(::Pkg.Registry.PkgEntry)`, which is why CI's bindings
build step pins a stable Julia setup independent of the test matrix's own
version -- see `.github/workflows/CI.yml`). If the machine's juliaup default
has since moved to a
newer channel (it did mid-session: 1.10 -> 1.12), running plain `julia
--project=bindings ...` doesn't error cleanly -- `Pkg.instantiate()` warns
about the manifest/Julia mismatch and can leave dependencies (observed:
`MbedTLS_jll`) half-installed, which then surfaces much later as a confusing
`ArgumentError: Package ... is required but does not seem to be installed`
buried inside a `using BinaryBuilder` precompile. Always invoke as `julia
+1.10 --project=bindings ...` (juliaup channel selector) for anything in
this directory, and re-run `Pkg.instantiate()` under `+1.10` if you ever hit
that error. Separately: running two `--deploy=local` builds concurrently
against this same environment races on Julia's own precompilation
lock/pidfiles and corrupts the same way -- build one platform at a time.

## Temporary dependency arrangement

Until Yggdrasil registration lands, the `RocksDB` package depends on the
**locally-built, `Pkg.develop`-ed** `RocksDB_jll` at `~/.julia/dev/RocksDB_jll`
rather than the (older, less complete) registered one. When registration
does land: switch `Project.toml`'s `RocksDB_jll` entry from a dev'd path back
to a normal registered version bound, tighten `[compat]` accordingly, and
update this note.

## Package architecture: three tiers

1. **Tier 1 -- `src/lib/LibRocksDB.jl`** (module `RocksDB.LibRocksDB`).
   Auto-generated by `gen/generator.jl` (Clang.jl) from RocksDB's
   `include/rocksdb/c.h` at the pinned commit -- one ccall wrapper per C
   function (~1049 of them), `CEnum`-based enums. Not re-exported at the
   top `RocksDB` module level on purpose: it's the escape hatch for
   "anything the C API can do" (transactions, backup engine, checkpoints,
   comparators/compaction filters via callbacks, SST file writer, etc.),
   accessed explicitly as `RocksDB.LibRocksDB.rocksdb_open(...)`.

   To regenerate after a RocksDB version bump: update the commit SHA in
   both `bindings/build_tarballs.jl` and the header fetch step used to
   populate `gen/rocksdb_headers/rocksdb/*.h`, then rerun
   `julia --project=gen gen/generator.jl`.

2. **Tier 2 -- `src/midlevel.jl`**. Idiomatic wrappers: `Options`, `DB`,
   `WriteBatch`, `WriteOptions`/`ReadOptions`, `DBIterator`, `Snapshot`,
   `Env`, `Cache`, `FilterPolicy`, column family support. Finalizer-based
   lifetime management (each opaque C pointer gets its own Julia wrapper
   type + finalizer; higher-level structs hold Julia references to
   dependencies -- e.g. `Options` holds its `Cache`/`FilterPolicy` -- so GC
   reachability keeps everything alive in the right order, rather than
   hand-rolled refcounting). Errors from the C API's `char **errptr`
   pattern become `RocksDBException`. Defaults: `create_if_missing=true`,
   zstd compression, 10-bits-per-key bloom filter, 8 MiB block cache.

   Every finalizer (`Cache`, `FilterPolicy`, `Env`, `Options`,
   `WriteOptions`, `ReadOptions`, `WriteBatch`, `DBIterator`, `Snapshot`)
   resets its `.ptr` field to `C_NULL` *after* calling the matching
   `rocksdb_*_destroy`/`_release_*` function, not just before (i.e. the
   guard is `if ptr != C_NULL; destroy(ptr); ptr = C_NULL; end`, not a
   one-shot `ptr != C_NULL && destroy(ptr)`). This was a real bug found
   while building `RocksDBSnapshotView`: calling `Base.finalize(x)`
   explicitly (as `close` on a snapshot view needs to, to release
   deterministically rather than wait for GC) would call the destroy
   function but never mark the object as released, so a later `isopen`
   check (or a second `finalize`) would see a stale non-null pointer --
   at best wrong, at worst a double free/release. `DB._close!` already had
   the correct pattern; the rest didn't, because nothing had previously
   called `finalize` on them explicitly. Follow this pattern for any new
   finalizer.

   `Snapshot(f, db)` and `batch(f, db::DB)` are `do`-block conveniences
   (the latter mirrors Tier 3's `RocksDB.batch(f, dict)`, just operating
   directly on a `DB`): `Snapshot` auto-releases via `finalize` in a
   `finally`, `batch` auto-`write!`s only if the block returns normally.
   Both are additive methods on existing exported names, not new exports.

3. **Tier 3 -- `src/dict.jl`**. `RocksDBDict{K,V} <: AbstractDict{K,V}`.
   Byte/string K/V pass through untouched; anything else goes through
   `Serialization.serialize`/`deserialize` so `RocksDBDict{Any,Any}` (the
   default via the no-type-params constructor) just works. Iterates in
   **sorted key order** (a bonus over `Base.Dict`, worth keeping visible in
   docs). `RocksDB.batch(f, dict)` gives atomic multi-key writes via a
   `do`-block over a batch proxy built on Tier 2's `WriteBatch`. `length`
   is only RocksDB's O(1) *estimate* of key count, so `IteratorSize` is
   `SizeUnknown()` (not the `AbstractDict` default `HasLength()`) and
   `isempty` checks via the iterator instead of `length(d) == 0` -- both
   were bugs caught by manual testing (`collect` raising "destination has
   fewer elements than required" right after a couple of small writes,
   since RocksDB's estimate can undercount fresh, unflushed data).

   `property(db, name)` (Tier 2) and `length` on `RocksDBDict`/
   `RocksDBSnapshotView` (Tier 3) used to always query RocksDB's
   **default** column family, even when scoped to a different one --
   RocksDB tracks most properties per column family, and
   `rocksdb_property_value` (no `cf`) vs `rocksdb_property_value_cf`
   (Tier 1) are genuinely different calls. Found while writing the
   "mixing tiers" tutorial (`length(store["users"])` silently reported
   the `"default"` column family's count instead of `"users"`'s). Fixed
   by adding a `cf` keyword to `property` and threading `_cf_arg(d)`
   through both `length` methods; see the regression tests added
   alongside ("property is column-family-scoped" in `test_midlevel.jl`,
   "RocksDBDict length() is column-family-scoped" in `test_dict.jl`).

   `RocksDB.ColumnFamilies{K,V}` is the column-family-as-sub-namespace API
   (four UX options were sketched for the user, who picked this one): a
   two-level `AbstractDict{String,RocksDBDict{K,V}}` where indexing by
   column-family name (`store["users"]`, `store[:sessions]`, `Symbol` or
   `String`) returns a plain `RocksDBDict` sharing the same underlying
   `DB` -- so the outer `[]` always means "pick a namespace" and the
   inner `[]` always means "pick a key", with no ambiguity regardless of
   `K` (unlike e.g. `dict[:cf_name]` on `RocksDBDict` itself, which would
   be genuinely ambiguous for `RocksDBDict{Any,Any}`). Defaults
   `create_missing_column_families=true` (via a new `Options` keyword),
   since the whole point of listing column families here is "give me
   these namespaces, creating them if new" -- opening column families
   that don't exist yet otherwise errors (`Column family not found`, a
   real RocksDB requirement, not a bug).

   `RocksDB.RocksDBSnapshotView{K,V}` is the read-only, point-in-time
   snapshot view: `RocksDB.snapshot(d::RocksDBDict)` (also has a do-block
   form) wraps Tier 2's existing `Snapshot`/`ReadOptions(; snapshot=...)`
   -- no new C-binding-level work was needed. It's purely additive next to
   `RocksDBDict` (a separate struct with its own near-identical
   `getindex`/`get`/`haskey`/`iterate` methods, each just passing a
   snapshot-bound `ReadOptions` instead of the DB's default) rather than a
   shared abstract supertype, to avoid touching `RocksDBDict`'s already
   -tested methods for the sake of ~25 lines of de-duplication. Two
   documented limitations: `length(view)` is **not** point-in-time
   consistent (RocksDB's key-count estimate has no snapshot parameter in
   the C API), and `close(view)` releases only the snapshot, deliberately
   **not** the shared `DB` (unlike `close(d::RocksDBDict)`, which does
   close the whole connection) -- closing a view must never affect
   whoever else is still using that `DB`. Writes through a view
   (`setindex!`/`delete!`/`empty!`) throw a clear `ErrorException` rather
   than a generic `MethodError`.

## Suggested follow-ups (not yet implemented)

- `ColumnFamily` handles (`src/midlevel.jl`) are never destroyed --
  `rocksdb_column_family_handle_destroy` has no caller anywhere. Found
  while auditing finalizers for the snapshot-view work; a real (small)
  resource leak, out of scope for that change.
- TBB/NUMA/sanitizer build variants in `bindings/`, if ever needed.

## Testing

- `test/test_lowlevel.jl`, `test/test_midlevel.jl`, `test/test_dict.jl`,
  wired up from `test/runtests.jl`. Run with
  `julia --project=. -e 'using Pkg; Pkg.test()'`.
- Tests require the locally-built `RocksDB_jll` (see above) to be
  `Pkg.develop`-ed into this environment first.
- `.github/workflows/CI.yml`'s `test` job does the same build+dev step
  before running `Pkg.test()`, for the same reason: `RocksDB_jll`'s UUID
  is deterministic, and an older, less complete version (missing
  bzip2/liburing) is already registered upstream under that exact UUID
  -- a fresh `Pkg.instantiate()` with no special handling would silently
  resolve to *that* instead of what `bindings/` actually builds. The
  `docs` job does **not** need this: it only extracts docstrings
  (`using RocksDB` succeeds against either JLL version; nothing calls
  into the library), and doctests are intentionally absent since every
  example is a plain ` ```julia ` fence, not ` ```jldoctest `.

## Documentation (`docs/`)

Every public Tier 2/Tier 3 struct and function has a docstring with a
plain ` ```julia ` example (never ` ```jldoctest ` -- these are
illustrative starting points, not Documenter-verified doctests, per an
explicit request; each was still manually run once while writing it).
Tier 1 (`RocksDB.LibRocksDB`) is deliberately excluded from the docs
build's "missing docstrings" enforcement
(`checkdocs_ignored_modules=[RocksDB.LibRocksDB]` in `docs/make.jl`) --
Clang.jl's doxygen-comment extraction gives some of its ~1049 functions
incidental docstrings, but Tier 1 is the escape hatch, not meant to be
curated function-by-function.

`docs/src/` layout: `index.md` (landing page) -> `tutorials/` (seven
pages, in nav order: getting started, compression, iteration, batches,
column families, snapshots, then a dedicated "mixing Tier 2 and Tier 3"
page covering drop-down/lift-up/combined patterns -- the user asked for
this discussion "above all else") -> `reference/tier2.md` and
`reference/tier3.md` (curated `@docs` blocks grouped by theme, not a
blanket `@autodocs` dump). Build with `julia --project=docs docs/make.jl`;
run `Pkg.develop(path=".")` in the `docs` environment first if
`RocksDB` isn't resolvable there.

Two things that bit this specific setup, worth knowing before editing
further:
- **Heading-slug collisions**: `@ref` resolves a bare heading name
  site-wide, so two pages both titled e.g. "Snapshots" is an error, not a
  warning. Reference-page section headings that echo a tutorial's title
  need to read differently (e.g. "Point-in-time reads (`Snapshot`)").
- **`@docs` entries for a function with more than one docstring split
  across the two reference pages** (e.g. `create_column_family`, one
  method on `DB` for Tier 2 and one on `ColumnFamilies` for Tier 3) need
  the *exact* method signature, type parameters and `where` clause
  included, or the docstring silently isn't picked up (caught by the
  build's "N docstrings not included in the manual" error, not a crash).

Writing the "mixing tiers" tutorial is what surfaced the `property`/
`length` column-family-scoping bug documented above -- exercising
multi-column-family Tier 3 dicts in a realistic combined example is what
existing tests hadn't done.
