# Column Families

A RocksDB database can have more than one *column family* -- an
independent keyspace sharing the same underlying database files/write
path. Every database has at least `"default"`.

## Tier 2: `create_column_family` and multi-column-family `opendb`

```julia
using RocksDB

path = mktempdir() * "/cfdb"
db = opendb(path)
users = create_column_family(db, "users")
put!(db, "alice", "admin"; cf = users)
put!(db, "alice", "top-level value")   # a different entry in the default column family

String(get(db, "alice"; cf = users))   # "admin"
String(get(db, "alice"))               # "top-level value" -- separate keyspaces
close(db)
```

Reopening a database that has more than just `"default"` requires listing
*every* column family it has (a real RocksDB requirement, not a
`RocksDB.jl` limitation):

```julia
using RocksDB

path = mktempdir() * "/cfdb2"
setup = opendb(path; column_families = ["default", "users"], create_missing_column_families = true)
put!(setup, "alice", "admin"; cf = "users")
close(setup)

# ... later, or in a different process:
db2 = opendb(path; column_families = ["default", "users"])
String(get(db2, "alice"; cf = "users"))   # "admin" -- cf also accepts a plain name
close(db2)
```

## Tier 3: `RocksDB.ColumnFamilies`

`RocksDB.ColumnFamilies` is a two-level container: indexing it by column
family name returns a plain [`RocksDBDict`](@ref) scoped to that column
family, sharing one underlying connection. Unlike a bare `RocksDBDict`,
its constructor defaults to `create_missing_column_families=true`, so
listing a new name is enough to create it:

```julia
using RocksDB

store = ColumnFamilies{String,String}(mktempdir() * "/cfstore";
                                       column_families = ["default", "users", "sessions"])

store["users"]["alice"] = "admin"
store[:sessions]["tok-1"] = "active"     # Symbol or String both work
store["default"]["site_name"] = "example.org"

haskey(store["sessions"], "alice")       # false -- genuinely separate keyspaces
new_cf = create_column_family(store, "logs")
new_cf["l1"] = "started"

sort(collect(keys(store)))   # ["default", "logs", "sessions", "users"]
close(store)                  # closes the shared DB and every RocksDBDict handed out
```

The outer `store[...]` always means "pick a column family"; the inner
`store["users"][...]` always means "pick a key" -- no ambiguity, even for
`ColumnFamilies{Any,Any}` (the default when you don't specify `{K,V}`).
