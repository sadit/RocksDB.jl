# RocksDB

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://sadit.github.io/RocksDB.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://sadit.github.io/RocksDB.jl/dev/)
[![Build Status](https://github.com/sadit/RocksDB.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/sadit/RocksDB.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/sadit/RocksDB.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/sadit/RocksDB.jl)

Julia bindings for [RocksDB](https://rocksdb.org/), Facebook's embedded
persistent key-value store, built on a from-scratch
[BinaryBuilder.jl](https://github.com/JuliaPackaging/BinaryBuilder.jl) recipe
(see [`bindings/`](bindings/)) with support for all five compression
backends RocksDB offers (Snappy, zlib, bzip2, LZ4, Zstd), plus io_uring on
Linux (jemalloc was tried and reverted -- see
[`bindings/README.md`](bindings/README.md) for why).

The package exposes RocksDB at three levels:

1. **`RocksDB.LibRocksDB`** -- near-direct, auto-generated `ccall` wrappers
   over RocksDB's entire C API. Anything the C API can do, this can do.
2. **Mid-level API** (`RocksDB.opendb`, `RocksDB.DB`, `put!`, `get`,
   `delete!`, `RocksDB.WriteBatch`, `RocksDB.DBIterator`, ...) -- idiomatic
   Julia wrappers with sensible defaults, for everyday use.
3. **`RocksDBDict`**, **`RocksDB.ColumnFamilies`**, and
   **`RocksDB.RocksDBSnapshotView`** -- an `AbstractDict`-like facade with
   compression and cache/environment knobs surfaced directly in its
   constructor, atomic batch writes, column families as dict-like
   sub-namespaces, and read-only point-in-time snapshot views.

## Installation

The package can be installed with the Julia package manager.
From the Julia REPL, type `]` to enter the Pkg REPL mode and run:

```julia
pkg> add RocksDB
```

## Quick start

### Tier 2: mid-level API

```julia
using RocksDB

RocksDB.opendb("mydb"; compression = :zstd) do db
    put!(db, "hello", "world")
    get(db, "hello")            # UInt8[...] ("world")
    delete!(db, "hello")

    wb = RocksDB.WriteBatch()
    put!(wb, "a", "1")
    put!(wb, "b", "2")
    write!(db, wb)

    for (k, v) in RocksDB.DBIterator(db)   # sorted key order
        println(String(k), " => ", String(v))
    end
end
```

### Tier 3: `RocksDBDict`

```julia
using RocksDB

d = RocksDBDict{String,String}("mydb2"; compression = :lz4, block_cache_size = 64 * 1024^2)
d["a"] = "1"
d["b"] = "2"
collect(keys(d))   # sorted, unlike Base.Dict

RocksDB.batch(d) do b
    b["c"] = "3"
    b["d"] = "4"
end   # committed atomically

close(d)
```

### Tier 3: column families as sub-namespaces

```julia
using RocksDB

store = RocksDB.ColumnFamilies{String,String}("mydb3"; column_families = ["default", "users", "sessions"])

store["users"]["alice"] = "admin"      # each column family is its own RocksDBDict,
store[:sessions]["tok-1"] = "active"   # sharing one underlying DB connection
store["default"]["site_name"] = "example.org"

haskey(store["sessions"], "alice")     # false -- column families are separate keyspaces
new_cf = create_column_family(store, "logs")
new_cf["l1"] = "started"

close(store)   # closes the shared DB and every RocksDBDict handed out
```

### Tier 3: point-in-time snapshot views

```julia
using RocksDB

d = RocksDBDict{String,String}("mydb4")
d["k1"] = "before"

view = RocksDB.snapshot(d)   # or: RocksDB.snapshot(d) do view ... end
d["k1"] = "after"
d["k2"] = "added after the snapshot"

view["k1"]            # "before" -- unaffected by writes made after the snapshot
haskey(view, "k2")     # false
collect(view)          # only ["k1" => "before"]

view["k1"] = "nope"    # errors: RocksDBSnapshotView is read-only

close(view)            # releases only the snapshot -- `d` (and its underlying
                        # connection) keeps working normally afterward
d["k3"] = "still fine"
```

Note: `length(view)` is **not** point-in-time consistent (RocksDB's
key-count estimate has no snapshot parameter in the C API) -- only
indexing and iteration are.

### Tier 1: escape hatch

```julia
using RocksDB

opts = RocksDB.LibRocksDB.rocksdb_options_create()
RocksDB.LibRocksDB.rocksdb_options_set_create_if_missing(opts, true)
# ... anything in rocksdb/c.h is available under RocksDB.LibRocksDB
```

## Development

See [`CLAUDE.md`](CLAUDE.md) for the project's internal architecture notes
(version pins, why things are built the way they are, what's deferred).

## License

MIT. See [`LICENSE`](LICENSE).
