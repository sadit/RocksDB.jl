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

If the block passed to `RocksDB.batch` throws, nothing staged in it is
written -- the exception simply propagates, and `write!` is never called:

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

The Tier 2 equivalent is just as simple: don't call `write!` if you decide
not to commit (e.g. inside a `try`/`catch`) -- an un-written `WriteBatch`
has no effect on the database at all.
