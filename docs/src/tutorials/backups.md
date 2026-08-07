# Backups

RocksDB has a dedicated backup engine, separate from the database itself:
a [`BackupEngine`](@ref) points at its own directory and can take
incremental backups of one or more [`DB`](@ref)s over time, list and
verify them, prune old ones, and restore any of them back into a database
directory later -- without needing a `DB` open at all for the restore
step.

## Taking backups

```julia
using RocksDB

db = RocksDB.opendb(mktempdir() * "/mydb")
put!(db, "a", "1")

be = RocksDB.BackupEngine(mktempdir() * "/backups")
create_backup!(be, db)

put!(db, "b", "2")
create_backup!(be, db)   # a second, incremental backup

close(db)
```

Each [`create_backup!`](@ref) call only copies what changed since the last
backup in that directory -- RocksDB shares unchanged SST files between
backups on disk (`share_table_files=true`, [`BackupEngine`](@ref)'s
default).

## Inspecting backups

[`backup_info`](@ref) lists every backup currently stored, oldest first,
as a [`BackupInfo`](@ref) per backup:

```julia
infos = backup_info(be)
length(infos)          # 2
infos[1].backup_id     # 1
infos[2].backup_id     # 2
infos[2].size           # bytes
infos[2].num_files      # files in that backup
```

[`verify_backup`](@ref) checks a specific backup's files and checksums,
throwing [`RocksDBException`](@ref) if anything is missing or corrupt:

```julia
verify_backup(be, 1)       # fine -- no exception
verify_backup(be, 99)      # throws RocksDB.RocksDBException: no such backup
```

## Purging old backups

[`purge_old_backups!`](@ref) keeps only the N most recent backups,
deleting the rest (and reclaiming the disk space of any SST files no
longer shared by a surviving backup):

```julia
purge_old_backups!(be, 1)
length(backup_info(be))    # 1 -- only the most recent backup remains
```

## Restoring

[`restore_backup!`](@ref) restores a specific backup by id;
[`restore_latest_backup!`](@ref) restores the most recent one. Both take a
plain directory path, not an open [`DB`](@ref) -- restoring writes
directly to `db_dir` (and `wal_dir`, which defaults to `db_dir`),
overwriting whatever is already there:

```julia
restored = mktempdir() * "/restored"
restore_latest_backup!(be, restored)
close(be)

db2 = RocksDB.opendb(restored; create_if_missing = false)
String(get(db2, "a"))   # "1"
String(get(db2, "b"))   # "2"
close(db2)
```

## `do`-block form

Like [`opendb`](@ref) and [`Snapshot`](@ref), [`BackupEngine`](@ref) has a
`do`-block form that closes the engine automatically, even if the block
throws:

```julia
db = RocksDB.opendb(mktempdir() * "/mydb2")
put!(db, "a", "1")

RocksDB.BackupEngine(mktempdir() * "/backups2") do be
    create_backup!(be, db)
    println("stored ", length(backup_info(be)), " backup(s)")
end

close(db)
```
