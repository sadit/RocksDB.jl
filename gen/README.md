# Tier 1 binding generator

`generator.jl` uses [Clang.jl](https://github.com/JuliaInterop/Clang.jl) to
auto-generate `../src/lib/LibRocksDB.jl` from RocksDB's C API header
(`rocksdb_headers/rocksdb/c.h`), pinned to the same commit as
`../bindings/build_tarballs.jl`.

## Regenerating

1. If bumping the RocksDB version, update the commit SHA in
   `../bindings/build_tarballs.jl` first, then re-fetch the headers at the
   new commit:

   ```bash
   commit=<new-commit-sha>
   for f in c.h export.h version.h; do
     curl -s "https://raw.githubusercontent.com/facebook/rocksdb/$commit/include/rocksdb/$f" \
       -o rocksdb_headers/rocksdb/$f
   done
   ```

2. Run the generator:

   ```bash
   julia --project=. generator.jl
   ```

This overwrites `../src/lib/LibRocksDB.jl` -- review the diff before
committing (macro/enum handling occasionally needs a manual tweak; see
`generator.toml` comments and `prologue.jl`).

Notes:

- On Linux, `rocksdb/c.h` is self-contained (it only pulls in `export.h`'s
  macro logic on `_WIN32`), so `export.h` doesn't actually need to be
  present/valid for generation to work correctly here.
- `library_name = "librocksdb"` in `generator.toml` must match the
  `LibraryProduct` symbol name in `bindings/build_tarballs.jl`, since that's
  the binding (`RocksDB_jll.librocksdb`) every generated `ccall` references.
