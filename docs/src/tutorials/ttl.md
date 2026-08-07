# TTL Databases

RocksDB can open a database where entries expire after a configurable
number of seconds. Pass `ttl` to [`opendb`](@ref) -- there's no separate
type or function for this, it's just another keyword argument.

## Opening with a TTL

```julia
using RocksDB

db = RocksDB.opendb(mktempdir() * "/ttldb"; ttl = 60)
put!(db, "session:abc", "alice")
String(get(db, "session:abc"))   # "alice" -- reads normally, ttl or not
close(db)
```

## Expiry only happens during compaction

This is the part that surprises people coming from e.g. Redis: RocksDB
does **not** filter expired entries out of `get`/iteration on every read.
An entry past its TTL is only actually removed the next time a compaction
runs over the SST file it lives in -- until then, `get` still returns it.
Quoting RocksDB's own `db_ttl.h`:

> Expired TTL values deleted in compaction only ... Get/Iterator may
> return expired entries (compaction not run on them yet)

If you want to *see* an entry expire without waiting for a background
compaction (typical outside of demos: it happens on its own eventually),
force one with [`compact!`](@ref) -- see the [Compaction](@ref) tutorial
for the rest of what it can do:

```julia
db2 = RocksDB.opendb(mktempdir() * "/ttldb2"; ttl = 1)
put!(db2, "a", "1")

sleep(2)   # past the 1-second ttl
String(get(db2, "a"))   # still "1" -- no compaction has run yet

compact!(db2)
get(db2, "a")   # nothing -- swept during that compaction

close(db2)
```

A non-positive or omitted `ttl` means "never expires" -- it isn't "expire
immediately."

## Per-column-family TTL

Combined with `column_families`, `ttl` can be a single value shared by
every column family, or a vector giving each one its own TTL (same order
as `column_families`):

```julia
db3 = RocksDB.opendb(mktempdir() * "/ttldb3";
                      column_families = ["default", "cache", "audit_log"],
                      create_missing_column_families = true,
                      ttl = [0, 30, 86400])   # cache: 30s, audit_log: 1 day, default: never

put!(db3, "hit:1", "x"; cf = "cache")
close(db3)
```

## Constraints

- **`read_only` cannot be combined with `ttl`** -- RocksDB's C API has no
  such open mode; `opendb(path; read_only = true, ttl = 60)` throws
  `ArgumentError`.
- **Reopen consistently.** A database ever opened with `ttl` stores a
  hidden 4-byte timestamp alongside every value. Reopening it later
  *without* `ttl` doesn't restore the old behavior -- it exposes that
  timestamp as if it were part of the value. Always pass `ttl` again on
  every subsequent `opendb` for that database (the value itself can
  change between opens).

## What's not covered here

Encryption at rest was asked for alongside TTL, but RocksDB's plain C API
(`rocksdb/c.h`, which this package's Tier 1 is generated from) has no
function to create an encrypted `Env` -- `NewEncryptedEnv` only exists in
a C++-only header. There's currently no way to reach it from this
package; see `CLAUDE.md`'s "Suggested follow-ups" for what adding it
would take.
