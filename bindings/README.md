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
- Windows and ARM (aarch64) are both in the default platform list and have
  been locally build-tested end to end (see "Windows and ARM support"
  below); liburing stays Linux-only, both via the script's `${target}` check
  and via `Liburing_jll`'s own `platforms=linux_platforms` restriction.

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

## Windows and ARM support

Both were locally build-tested (`--deploy=local`, host-native emulation via
BinaryBuilder's cross-toolchain shards) ahead of Yggdrasil submission:

- **ARM (aarch64-linux-gnu)** needed **no changes at all**. The historical
  Yggdrasil `arm64.patch` for older RocksDB versions forces
  `util/crc32c_arm64.cc` to always compile, bypassing a `HAS_ARMV8_CRC`
  `CHECK_C_COMPILER_FLAG` detection that supposedly didn't work reliably
  under cross-compilation on old RocksDB/CMake combinations. That detection
  works correctly under cross-compilation as of RocksDB v11.1.2/CMake used
  here -- the aarch64 build compiled, linked, passed BinaryBuilder's audit,
  and packaged cleanly with the recipe unmodified. 32-bit ARM (`armv7l`,
  `armv6l`) is still filtered out; RocksDB targets 64-bit platforms.
- **Windows (x86_64-w64-mingw32)** needed two fixes, both applied in
  `build_tarballs.jl`:
  1. `-DROCKSDB_INSTALL_ON_WINDOWS=1`. RocksDB's `CMakeLists.txt` gates its
     entire `install()` ruleset behind
     `if(NOT WIN32 OR ROCKSDB_INSTALL_ON_WINDOWS)`, and that option defaults
     `OFF` -- without it, `cmake --install .` on Windows is a **silent
     no-op** (the build itself succeeds, `cmake --build` produces the DLL,
     but nothing gets copied into `${prefix}`, so the result is an empty
     tarball). Confirmed by reproducing the no-op locally before adding the
     flag.
  2. `LibraryProduct(["librocksdb", "librocksdb-shared"], :librocksdb)`.
     RocksDB's `CMakeLists.txt` only applies `OUTPUT_NAME "rocksdb"` to the
     shared-lib target in its non-Windows (`else()`) branch; on Windows the
     target keeps its literal CMake target name `rocksdb-shared`, so the
     installed file is `librocksdb-shared.dll`, not `librocksdb.dll`. Without
     the second name, BinaryBuilder's product audit reports `librocksdb`
     "unsatisfied" even though the DLL built and installed correctly.
     `LibraryProduct` accepting multiple candidate names is the standard
     BinaryBuilder mechanism for a library that's named differently per
     platform -- no upstream CMake patch needed.
  MinGW (not MSVC) is the target; RocksDB's Windows port code
  (`port/win/*.cc`) has genuine non-MSVC-gated branches (plain `if(WIN32)`,
  explicit `if(MINGW)`), which is why MinGW cross-compilation works at all
  here.

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
registry) via `--deploy=local`. This project's `Manifest.toml` is pinned to
Julia 1.10 (BinaryBuilder/Pkg-internals compatibility; see `CLAUDE.md`), so
build with a specific `+1.10` juliaup channel rather than whatever `julia`
happens to default to -- if your default Julia is a different minor version,
`Pkg.instantiate()` will otherwise either fail outright (unresolvable compat)
or silently re-resolve the manifest against the wrong version and then fail
deep inside a `using BinaryBuilder` precompile with a confusing
`ArgumentError: Package ... is required but does not seem to be installed`.
From this directory:

```bash
julia +1.10 --project=. -e 'import Pkg; Pkg.instantiate()'
julia +1.10 --project=. build_tarballs.jl --verbose --deploy=local x86_64-linux-gnu-cxx11
```

Adjust the platform triplet to your host (`julia +1.10 --project=. build_tarballs.jl --help`
explains the triplet syntax; `supported_platforms()` in a Julia REPL with
BinaryBuilder loaded lists everything the recipe covers). Run **one platform
at a time** -- concurrent `--deploy=local` invocations against this same
`bindings/` environment race on Julia's precompilation lock/pidfiles and can
leave dependencies (observed: `MbedTLS_jll`) in a broken, only-partially-
installed state; if that happens, `julia +1.10 --project=. -e 'using Pkg;
Pkg.instantiate()'` again resolves it. This produces a `RocksDB_jll` package
at `~/.julia/dev/RocksDB_jll` that the `RocksDB.jl` package in the parent
directory is `Pkg.develop`-ed against for now, in place of the (older, less
complete) registered one.

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
