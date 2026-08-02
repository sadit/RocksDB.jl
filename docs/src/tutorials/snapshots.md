# Snapshots

A snapshot pins a consistent, point-in-time view of the database: reads
through it are unaffected by writes made *after* the snapshot was taken,
even while those writes keep happening on the live database.

## Toy example: a report that shouldn't see concurrent writes

## Tier 2: `Snapshot` and `ReadOptions`

```julia
using RocksDB

db = opendb(mktempdir() * "/snapdb")
put!(db, "balance", "100")

snap = Snapshot(db)                          # pin the current state
ro = ReadOptions(; snapshot = snap)

put!(db, "balance", "150")                   # a concurrent write happens...
put!(db, "new_account", "50")

String(get(db, "balance"; options = ro))     # "100" -- the snapshot's view
get(db, "new_account"; options = ro)         # nothing -- didn't exist at snapshot time

String(get(db, "balance"))                   # "150" -- the live database sees everything
close(db)
```

A [`DBIterator`](@ref) built with the same `options` scans the
snapshot's view too, so a whole report/scan can be made
point-in-time-consistent, not just single reads.

## Tier 3: `RocksDB.snapshot` and `RocksDBSnapshotView`

```julia
using RocksDB

d = RocksDBDict{String,String}(mktempdir() * "/snapdict")
d["balance"] = "100"

view = RocksDB.snapshot(d)     # or: RocksDB.snapshot(d) do view ... end
d["balance"] = "150"
d["new_account"] = "50"

view["balance"]                  # "100"
haskey(view, "new_account")      # false
collect(view)                    # only ["balance" => "100"]

d["balance"]                     # "150" -- the live dict, unaffected by the view

view["balance"] = "nope"   # errors: RocksDBSnapshotView is read-only
close(view)                # releases only the snapshot
d["still"] = "works"        # d itself is completely unaffected by closing the view
close(d)
```

## Two things a snapshot does *not* freeze

- **`length(view)`** is *not* point-in-time consistent. RocksDB's
  key-count estimate (`"rocksdb.estimate-num-keys"`, see [`property`](@ref))
  has no snapshot parameter in the C API at all -- it always reflects the
  live database, unlike every other read through the view.
- **`close(view)`** releases only the snapshot, not the shared
  connection. This is deliberate and different from `close(d::RocksDBDict)`,
  which *does* close the whole database -- closing a view must never
  affect whoever else (including the dict it came from) is still using
  that connection.
