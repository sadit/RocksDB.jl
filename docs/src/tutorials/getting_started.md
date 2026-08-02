# Getting Started

## Installation

`RocksDB.jl` is not yet registered. Until the underlying `RocksDB_jll` is
registered in [Yggdrasil](https://github.com/JuliaPackaging/Yggdrasil) (see
[`bindings/README.md`](https://github.com/sadit/RocksDB.jl/blob/main/bindings/README.md)),
build it locally and develop the package against that local artifact:

```sh
julia --project=bindings bindings/build_tarballs.jl --verbose --deploy=local x86_64-linux-gnu-cxx11
julia --project=. -e 'import Pkg; Pkg.develop(path=joinpath(homedir(), ".julia", "dev", "RocksDB_jll"))'
```

## Opening a database

The mid-level (Tier 2) API is the natural starting point: [`opendb`](@ref)
opens (creating if needed) a database at a filesystem path.

```julia
using RocksDB

db = opendb("mydb")
put!(db, "hello", "world")
String(get(db, "hello"))    # "world"
haskey(db, "hello")         # true
delete!(db, "hello")
get(db, "hello")             # nothing
close(db)
```

Keys and values are `AbstractString` or byte vectors -- `get` always
returns raw bytes (`Vector{UInt8}`, or `nothing` if the key doesn't exist),
so wrap the result in `String(...)` when you know it's text, as above.

## The `do`-block form

`opendb(f, path; kwargs...)` closes the database automatically, even if
`f` throws:

```julia
using RocksDB

opendb("mydb2") do db
    put!(db, "k", "v")
    String(get(db, "k"))
end   # db is already closed here
```

Prefer this form whenever the database doesn't need to outlive a single
function/script -- it's one less thing to remember to clean up.

## Beyond the defaults: tuning `Options`

`opendb`'s keyword arguments (besides `column_families`/`read_only`) are
forwarded to [`Options`](@ref), which controls everything about how the
database is opened and tuned. The defaults (`create_if_missing=true`,
`compression=:zstd`, a 10-bits-per-key bloom filter, an 8 MiB block cache)
are chosen to work well without any tuning, but the knobs are there when
you need them:

```julia
using RocksDB

db = opendb(
    "mydb3";
    max_open_files = 256,        # cap the number of open SST file descriptors
    max_background_jobs = 4,     # more parallelism for compaction/flush
    write_buffer_size = 32 * 1024^2,  # bigger memtable before it's flushed to disk
    bloom_bits_per_key = nothing,      # disable the bloom filter entirely
)
close(db)
```

See the [Tier 2 API Reference](@ref) for the full list of `Options`
keywords, and the [Compression](@ref) tutorial for the `compression`
keyword specifically.

## Where to next

- [Compression](@ref) -- all five compression backends, toy example.
- [Iteration and Range Scans](@ref) -- sorted iteration and prefix scans.
- [Write Batches](@ref) -- atomic multi-key writes.
- [Column Families](@ref) -- separate keyspaces in one database.
- [Snapshots](@ref) -- consistent point-in-time reads.
- [Mixing Tier 2 and Tier 3](@ref) -- when and how to combine the
  dict-like API with the mid-level API directly.
