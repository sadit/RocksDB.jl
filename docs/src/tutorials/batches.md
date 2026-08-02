# Write Batches

A batch groups several writes so they're applied atomically -- either all
of them take effect, or (if the process crashes before the batch is
written) none of them do. Both tiers offer this.

## Tier 2: `WriteBatch` and `write!`

```julia
using RocksDB

db = opendb(mktempdir() * "/batchdb")
wb = WriteBatch()
put!(wb, "a", "1")
put!(wb, "b", "2")
delete!(wb, "a")     # deletes can be staged in the same batch as puts
write!(db, wb)        # applied atomically

get(db, "a")                  # nothing
String(get(db, "b"))          # "2"
close(db)
```

Reuse a batch across multiple rounds of writes with `empty!(wb)` instead
of allocating a new one each time.

`RocksDB.batch(db) do wb ... end` is a `do`-block shortcut for the same
thing: it creates the batch, runs the block, and calls `write!` for you
automatically -- only if the block returns normally:

```julia
using RocksDB

db = opendb(mktempdir() * "/batchdb2")
RocksDB.batch(db) do wb
    put!(wb, "a", "1")
    put!(wb, "b", "2")
end   # write! called here, automatically
String(get(db, "a"))   # "1"
close(db)
```

## Tier 3: `RocksDB.batch`

```julia
using RocksDB

d = RocksDBDict{String,String}(mktempdir() * "/batchdict")
RocksDB.batch(d) do b
    b["x"] = "1"
    b["y"] = "2"
end   # committed atomically here
d["x"]   # "1"
close(d)
```

## Rollback on exception

If the block passed to `RocksDB.batch` throws (at either tier), nothing
staged in it is written -- the exception simply propagates, and `write!`
is never called:

```julia
using RocksDB

d = RocksDBDict{String,String}(mktempdir() * "/batchdict2")
try
    RocksDB.batch(d) do b
        b["z"] = "3"
        error("something went wrong downstream")
    end
catch e
    println("caught: ", e)
end
haskey(d, "z")   # false -- the batch was discarded, not partially applied
close(d)
```

Building a `WriteBatch` by hand (rather than through the `do`-block form)
gives you the same guarantee just as easily: don't call `write!` if you
decide not to commit (e.g. inside a `try`/`catch`) -- an un-written
`WriteBatch` has no effect on the database at all.
