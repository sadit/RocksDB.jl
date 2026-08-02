# Compression

RocksDB.jl's [bindings](https://github.com/sadit/RocksDB.jl/blob/main/bindings/README.md)
are built with all five compression backends RocksDB supports. Pick one
with the `compression` keyword, accepted anywhere [`Options`](@ref) is
built (`opendb`, `RocksDBDict`, `ColumnFamilies`, ...):

| Symbol      | Backend                                    |
|:----------- |:------------------------------------------- |
| `:none`     | no compression                              |
| `:snappy`   | Snappy -- fast, modest ratio                |
| `:zlib`     | zlib/DEFLATE -- slower, better ratio         |
| `:bzip2`    | bzip2 -- slower still, often better ratio    |
| `:lz4`      | LZ4 -- very fast, modest ratio               |
| `:lz4hc`    | LZ4 high-compression mode -- slower than lz4, better ratio |
| `:zstd`     | Zstandard -- good balance of speed and ratio (the **default**) |

## Toy example: round-tripping through every backend

```julia
using RocksDB

for c in (:none, :snappy, :zlib, :bzip2, :lz4, :lz4hc, :zstd)
    opendb(mktempdir() * "/db_$c"; compression = c) do db
        put!(db, "key", "some repeated value " ^ 50)
        @assert String(get(db, "key")) == "some repeated value " ^ 50
        println(c, ": round-trip OK")
    end
end
```

Compression is applied per *SST file block* (not per key), so it matters
most for larger values and larger databases -- a toy example like this
mainly confirms that all five backends are actually linked in and
functional, which is exactly what
[`test/test_midlevel.jl`](https://github.com/sadit/RocksDB.jl/blob/main/test/test_midlevel.jl)'s
own "all compression backends round-trip" test checks.

## Why `:zstd` by default

Zstandard is RocksDB upstream's own recommended default for new
applications: close to zlib/bzip2 compression ratios at speeds much closer
to Snappy/LZ4. Unless you have a specific reason to change it (e.g.
matching an existing database's setting, or `:lz4` if write throughput
matters more than storage size), the default is the right choice.

## Tier 3 equivalent

Every Tier 3 constructor ([`RocksDBDict`](@ref), [`ColumnFamilies`](@ref))
forwards `compression` (and every other `Options` keyword) the same way:

```julia
using RocksDB

d = RocksDBDict{String,String}(mktempdir() * "/dict_lz4"; compression = :lz4)
d["k"] = "v"
close(d)
```
