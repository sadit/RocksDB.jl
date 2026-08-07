# Compaction

RocksDB normally decides when to compact on its own, in the background.
[`compact!`](@ref) forces a compaction to happen right now instead --
useful whenever something else you did only takes effect at compaction
time and you don't want to wait for it, such as [TTL Databases](@ref) expiry.

## Compacting everything

```julia
using RocksDB

db = RocksDB.opendb(mktempdir() * "/compactdb")
for i in 1:20
    put!(db, "k$(lpad(i, 3, '0'))", "v$i")
end

compact!(db)   # from=nothing, to=nothing means the whole key range
String(get(db, "k010"))   # "v10" -- compaction never changes what reads see
close(db)
```

## Compacting a range or a column family

`from`/`to` accept the same key types as `put!`/`get` (`AbstractString` or
byte vectors); `cf` scopes the compaction to one column family, same
convention as [`property`](@ref)/[`put!`](@ref):

```julia
db2 = RocksDB.opendb(mktempdir() * "/compactdb2";
                      column_families = ["default", "logs"],
                      create_missing_column_families = true)
for i in 1:20
    put!(db2, "k$(lpad(i, 3, '0'))", "v$i")
    put!(db2, "l$(lpad(i, 3, '0'))", "entry $i"; cf = "logs")
end

compact!(db2; from = "k005", to = "k010")   # only that key range
compact!(db2; cf = "logs")                   # only the "logs" column family
close(db2)
```

## Tuning the compaction itself

Pass any of `exclusive`, `change_level`, `target_level`,
`bottommost_level_compaction`, `max_subcompactions` and `compact!` builds
a RocksDB `CompactRangeOptions` for you (left alone otherwise, since
building one has a small extra cost):

```julia
db3 = RocksDB.opendb(mktempdir() * "/compactdb3")
put!(db3, "a", "1")
compact!(db3; change_level = true, target_level = 0)
close(db3)
```

See [RocksDB's own documentation](https://github.com/facebook/rocksdb/blob/main/include/rocksdb/options.h)
for what each of these controls -- they're forwarded as-is, with no
RocksDB.jl-specific behavior layered on top.
