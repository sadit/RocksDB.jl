# RocksDB bindings (BinaryBuilder recipe)

This directory holds a [BinaryBuilder.jl](https://github.com/JuliaPackaging/BinaryBuilder.jl)
recipe (`build_tarballs.jl`) that compiles [RocksDB](https://github.com/facebook/rocksdb)
from source and packages it as a Julia JLL artifact (`RocksDB_jll`).

## What this recipe builds

- RocksDB v11.1.2 (commit `3b446089141659fad25328c5ea3e7ed283df46e4`), shared library only
  (`librocksdb`), no bundled CLI tools/tests/benchmarks.
- All five compression backends RocksDB supports through BinaryBuilder JLLs:
  Snappy, zlib, bzip2, LZ4, Zstd.
- io_uring (`WITH_LIBURING`) on Linux, for RocksDB's faster async I/O backend.
- Intel TBB, NUMA, and the sanitizer build variants (ASAN/TSAN/UBSAN) are
  **not** enabled -- left as documented future extensions (see below).
- Windows is excluded from the default platform list: Liburing_jll and
  RocksDB's own Windows CMake path aren't exercised here.

### jemalloc was tried and reverted

`WITH_JEMALLOC=1` was enabled initially (per an explicit request to include
it as a recommended feature) but caused a **reproducible segfault on every
`DB::Open`**, tracked down to a real upstream incompatibility:
`PosixHelper::GetQueueSysfsFileValueOfFd` in RocksDB's `env/io_posix.cc` calls
glibc's `getline()` (which allocates its line buffer via glibc's `malloc`)
and then `free()`s that same buffer. Under `WITH_JEMALLOC`, RocksDB's build
macro-redefines `free` to `je_free` for that translation unit, so the
`getline`-allocated (glibc-malloc'd) pointer gets handed to jemalloc's
allocator, which doesn't recognize it and crashes in its radix-tree lookup
(`rtree_leaf_elm_lookup_hard`). This is a bug in how RocksDB's jemalloc
integration interacts with a libc call it doesn't control, not something
particular to this recipe or to BinaryBuilder's toolchain -- it would
reproduce in any `WITH_JEMALLOC=1` build of RocksDB 11.1.2 on Linux the
moment `DB::Open` probes the underlying block device (which it always does).
Revisiting this would mean patching `io_posix.cc` upstream (or building
jemalloc with a symbol prefix and auditing every RocksDB call site that
might cross the same boundary) -- out of scope here; `jemalloc_jll` was
removed from `dependencies` accordingly.

## Relationship to the existing `RocksDB_jll.jl`

An official `RocksDB_jll.jl` already exists
(`JuliaBinaryWrappers/RocksDB_jll.jl`), built from
[`Yggdrasil/R/RocksDB/build_tarballs.jl`](https://github.com/JuliaPackaging/Yggdrasil/blob/master/R/RocksDB/build_tarballs.jl).
It's pinned to RocksDB 8.9.1 and only enables snappy/lz4/zlib/zstd (no bzip2,
jemalloc, or liburing). This recipe is a superset, meant to eventually
**replace/upgrade** that Yggdrasil recipe via a pull request -- not to publish
a competing package under a different name. Until that PR lands, this package
is built and consumed purely locally (see "Local testing" below); nothing
here is uploaded or registered anywhere.

## Local testing

BinaryBuilder supports building for a single host platform and writing the
resulting JLL wrapper straight to `~/.julia/dev/` (no GitHub release, no
registry) via `--deploy=local`. From this directory:

```bash
julia --project=. -e 'import Pkg; Pkg.instantiate()'
julia --project=. build_tarballs.jl --verbose --deploy=local x86_64-linux-gnu-cxx11
```

Adjust the platform triplet to your host (`julia --project=. build_tarballs.jl --help`
explains the triplet syntax; `supported_platforms()` in a Julia REPL with
BinaryBuilder loaded lists everything the recipe covers). This produces a
`RocksDB_jll` package at `~/.julia/dev/RocksDB_jll` that the `RocksDB.jl`
package in the parent directory is `Pkg.develop`-ed against for now, in place
of the (older, less complete) registered one.

If the build fails on your GCC/toolchain combination, note that RocksDB
11.x requires C++20 (`using enum`, added in GCC 11); this recipe pins
`preferred_gcc_version=v"12"` for headroom.

## Registering in Yggdrasil (future work)

This step is intentionally deferred. When ready:

1. Fork [`JuliaPackaging/Yggdrasil`](https://github.com/JuliaPackaging/Yggdrasil).
2. Create a branch (e.g. `rocksdb-11`) and replace
   `Yggdrasil/R/RocksDB/build_tarballs.jl` with (an updated version of) the
   `build_tarballs.jl` in this directory. Yggdrasil recipes import
   `../../platforms/macos_sdks.jl` and similar shared helpers relative to the
   monorepo root -- reintroduce that plumbing if this recipe still needs a
   macOS SDK bump (check `require_macos_sdk` usage in the current upstream
   recipe first).
3. Open a PR against Yggdrasil. Its CI builds and audits **every** platform
   in `platforms` (all of them, not just the host triplet used for local
   testing here) -- expect this to surface platform-specific issues (notably
   macOS/FreeBSD/Windows, none of which were exercised locally) that will
   need fixing before CI is green.
4. Once merged and CI passes, commenting `@JuliaRegistrator register` (per
   Yggdrasil's usual flow) publishes new `RocksDB_jll` versions to the
   General registry automatically -- no manual registration step needed.
5. After that, `RocksDB.jl`'s `Project.toml` should switch its `RocksDB_jll`
   entry from a `Pkg.develop`-ed local path back to a normal registered
   version bound, and the `[compat]` entry should be tightened accordingly.

## Future extensions (not built here)

- **Intel TBB** (`WITH_TBB`, via `oneTBB_jll`): used by RocksDB for some
  parallel memtable/insert paths; skipped for now as a heavier, less-common
  dependency most users won't need.
- **NUMA** (`WITH_NUMA`): Linux-only policy support, low value for a
  general-purpose binding.
- **Sanitizer builds** (ASAN/TSAN/UBSAN): useful for debugging RocksDB
  itself, not for a release artifact.
