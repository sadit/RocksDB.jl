# Mixing Tier 2 and Tier 3

The Tier 3 dict-like API ([`RocksDBDict`](@ref), [`ColumnFamilies`](@ref),
[`RocksDBSnapshotView`](@ref)) is convenient for everyday application
code, but it deliberately doesn't expose every knob Tier 2 has. The two
levels aren't an either/or choice: every Tier 3 type is a thin wrapper
around a Tier 2 [`DB`](@ref), and it's normal (and supported) to reach
through one to get at the other whenever a task needs both.

## Pattern 1: drop down from Tier 3 to Tier 2

Every `RocksDBDict`/`ColumnFamilies` stores its underlying connection in a
`.db` field. Reach into it for anything the dict API doesn't expose --
raw properties, a custom `ReadOptions`, or a `DBIterator` seeked to a
specific starting point:

```julia
using RocksDB

d = RocksDBDict{String,String}(mktempdir() * "/dropdown")
d["a"] = "1"; d["b"] = "2"; d["c"] = "3"

# 1. A raw property the Dict API has no method for:
property(d.db, "rocksdb.estimate-num-keys")

# 2. A manual, seeked iterator (see the Iteration tutorial for seek!/valid/key/value):
it = DBIterator(d.db)
seek!(it, "b")
String(key(it))   # "b" -- positioned directly, skipping "a"

close(d)
```

This works the same way for a `ColumnFamilies` entry
(`store["users"].db`) and for a `RocksDBSnapshotView` (`view.db`).

## Pattern 2: lift a Tier 2 `DB` up to Tier 3

Open the database yourself via [`opendb`](@ref) when you need something
only Tier 2 exposes -- `read_only=true`, a shared/custom [`Env`](@ref),
several column families opened together with fine-grained `Options` --
then wrap one or more of its column families as a `RocksDBDict` for
convenient application-level access afterward, using the
`RocksDBDict{K,V}(db::DB, column_family)` constructor:

```julia
using RocksDB

path = mktempdir() * "/liftup"
# Set it up first (as a plain Tier 2 DB) with two column families:
setup = opendb(path; column_families = ["default", "users"], create_missing_column_families = true)
put!(setup, "alice", "admin"; cf = "users")
close(setup)

# Now reopen read-only, with a tuned Env, and use the Tier 3 dict API on top:
env = Env(; background_threads = 2)
db = opendb(path; read_only = true, env = env, column_families = ["default", "users"])
users = RocksDBDict{String,String}(db, "users")

users["alice"]              # "admin" -- ordinary dict-style access
# users["alice"] = "x"      # would throw: db was opened read_only

close(db)   # closes db; `users` shared its connection, not a separate one
```

## Pattern 3: a combined toy task

A small "user directory + audit log" service: bulk application code uses
Tier 3 dicts for ergonomics, while a periodic maintenance check drops back
to Tier 2 for a raw property query -- showing both levels used side by
side in one program, not as a one-time choice made up front.

```julia
using RocksDB

path = mktempdir() * "/combined"

# Open with a tuned cache, shared across both column families:
db = opendb(path; column_families = ["default", "users", "audit_log"],
            create_missing_column_families = true, block_cache_size = 32 * 1024^2)

users = RocksDBDict{String,String}(db, "users")
audit = RocksDBDict{String,String}(db, "audit_log")

# Application code: plain dict-style access.
users["alice"] = "admin"
audit["evt:1"] = "alice created"

# Maintenance check: drop to Tier 2 for a detailed stats dump Tier 3 doesn't
# expose at all (property() is scoped per column family, same as put!/get/cf=):
println(property(db, "rocksdb.stats"; cf = "users"))
println("users column family has ~", length(users), " keys")   # Tier 3's length() is cf-scoped too

close(db)   # closes everything: db itself and both RocksDBDicts share it
```

## Summary

| Need                                             | Use                                                                 |
|:------------------------------------------------- |:-------------------------------------------------------------------- |
| Everyday get/put/delete/iterate on one keyspace   | [`RocksDBDict`](@ref)                                               |
| Several named keyspaces in one database           | [`ColumnFamilies`](@ref)                                            |
| A consistent read view unaffected by later writes | [`RocksDBSnapshotView`](@ref)/[`RocksDB.snapshot`](@ref)             |
| Anything else (raw properties, custom `Env`/`ReadOptions`, manual iterator seeking, `read_only`, ...) | Drop to the `.db` field, or open the `DB` yourself and lift it up with `RocksDBDict{K,V}(db, cf)` |
