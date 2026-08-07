```@meta
CurrentModule = RocksDB
```

# Tier 2 API Reference

The mid-level, idiomatic wrappers over the full C API: sensible defaults,
finalizer-managed lifetimes, exceptions instead of the C API's `errptr`
pattern. See the tutorials (starting with [Getting Started](@ref)) for
narrative walkthroughs; this page is a reference, organized by theme.

## Errors

```@docs
RocksDBException
```

## Options and tuning

```@docs
Options
Cache
FilterPolicy
Env
```

## Opening and closing a database

```@docs
DB
opendb
```

## Reads and writes

```@docs
put!(::DB, ::Any, ::Any)
get(::DB, ::Any)
delete!(::DB, ::Any)
haskey(::DB, ::Any)
WriteOptions
ReadOptions
```

## Write batches

```@docs
WriteBatch
put!(::WriteBatch, ::Any, ::Any)
delete!(::WriteBatch, ::Any)
empty!(::WriteBatch)
write!
batch(::Function, ::DB)
```

## Iteration

```@docs
DBIterator
seek_to_first!
seek_to_last!
seek!
advance!
valid
key
value
```

## Column families

```@docs
ColumnFamily
create_column_family(::DB, ::AbstractString)
column_families
```

## Point-in-time reads (`Snapshot`)

```@docs
Snapshot
```

## Introspection

```@docs
property
```

## Compaction (`compact!`)

```@docs
compact!
```

## Backups (`BackupEngine`)

```@docs
BackupEngine
BackupEngine(::Function, ::AbstractString)
BackupInfo
create_backup!
backup_info
verify_backup
purge_old_backups!
restore_backup!
restore_latest_backup!
```
