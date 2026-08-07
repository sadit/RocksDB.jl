# Tier 1 Escape Hatch

Tier 2 wraps the parts of RocksDB's C API that come up often, but it
doesn't wrap everything -- and it never will, on purpose (see the "escape
hatch" note in [Where to start](@ref)). When you need something Tier 2
doesn't expose, drop down to `RocksDB.LibRocksDB`, Tier 1's near-direct,
auto-generated `ccall` wrappers over the full C API.

## Pattern: drop down from Tier 2 to Tier 1

Every Tier 2 struct that wraps a C pointer stores it in a `.ptr` field --
`db.ptr`, `options.ptr`, `env.ptr`, and so on. That's the same pointer
Tier 1's functions expect, so you can call them directly:

```julia
using RocksDB

db = RocksDB.opendb(mktempdir() * "/mydb")
put!(db, "a", "1")

# rocksdb.jl has no Checkpoint wrapper -- but the C API does. Call it
# directly on db.ptr:
errptr = Ref{Ptr{Cchar}}(C_NULL)
cp = RocksDB.LibRocksDB.rocksdb_checkpoint_object_create(db.ptr, errptr)
errptr[] != C_NULL && error(unsafe_string(errptr[]))

checkpoint_dir = mktempdir() * "/checkpoint"
errptr2 = Ref{Ptr{Cchar}}(C_NULL)
RocksDB.LibRocksDB.rocksdb_checkpoint_create(cp, checkpoint_dir, UInt64(0), errptr2)
errptr2[] != C_NULL && error(unsafe_string(errptr2[]))

RocksDB.LibRocksDB.rocksdb_checkpoint_object_destroy(cp)  # your responsibility -- no finalizer down here
close(db)

# The checkpoint is a fully independent, openable database:
db2 = RocksDB.opendb(checkpoint_dir; create_if_missing = false)
String(get(db2, "a"))   # "1"
close(db2)
```

A [checkpoint](https://github.com/facebook/rocksdb/wiki/Checkpoints) is a
cheap, hard-linked (same-filesystem) point-in-time copy of a database --
conceptually a lighter-weight cousin of the [Backups](@ref) this package
*does* wrap in Tier 2, useful when you want a fast local snapshot on disk
rather than a versioned, prunable backup archive.

## What you give up

Tier 1 has none of Tier 2's conveniences:

- **No finalizers.** Every `rocksdb_*_create`/`_open` you call has a
  matching `_destroy`/`_close` you must call yourself, in a `try`/`finally`
  if there's any chance of an exception in between -- as in the checkpoint
  example above.
- **No exceptions.** Every fallible Tier 1 function takes a `char **errptr`
  out-parameter instead of throwing. You check it yourself:

  ```julia
  errptr = Ref{Ptr{Cchar}}(C_NULL)
  result = RocksDB.LibRocksDB.rocksdb_some_function(..., errptr)
  if errptr[] != C_NULL
      msg = unsafe_string(errptr[])
      RocksDB.LibRocksDB.rocksdb_free(errptr[])
      error(msg)   # or throw(RocksDB.RocksDBException(msg)) to match Tier 2's own exception type
  end
  ```

  This is exactly what Tier 2's internal `checked` helper automates for
  every Tier 2 function -- it isn't exported, but it's four lines you can
  replicate by hand, or call as `RocksDB.checked` if you're comfortable
  reaching into an internal.
- **No defaults.** Tier 2's `Options` sets zstd compression, a bloom
  filter, a block cache, and `create_if_missing=true` for you; Tier 1's
  `rocksdb_options_create()` starts from RocksDB's own bare defaults.

## When this was exactly backups

Until [`BackupEngine`](@ref) was added to Tier 2, backups were the
textbook case for this tutorial: the only way to call
`rocksdb_backup_engine_open_opts` was through `RocksDB.LibRocksDB`
directly on `db.ptr`, managing the backup engine options object, the
`errptr`, and the close call all by hand. See the [Backups](@ref) tutorial
for what moving that into Tier 2 bought: a `BackupEngine` struct with a
finalizer, keyword arguments with sensible defaults, `RocksDBException` on
failure, and a `do`-block form. That's the trade this tutorial is
about -- Tier 1 access whenever you need it, Tier 2 wrappers for whatever
comes up often enough to be worth writing one.
