```@meta
CurrentModule = RocksDB
```

# RocksDB.jl

Julia bindings for [RocksDB](https://rocksdb.org/), Facebook's embedded
persistent key-value store, built on a from-scratch
[BinaryBuilder.jl](https://github.com/JuliaPackaging/BinaryBuilder.jl)
recipe with support for all five compression backends RocksDB offers
(Snappy, zlib, bzip2, LZ4, Zstd) plus io_uring on Linux -- see
[`bindings/README.md`](https://github.com/sadit/RocksDB.jl/blob/main/bindings/README.md).

The package is organized in three tiers, so you can pick the level of
control you need:

1. **`RocksDB.LibRocksDB`** -- near-direct, auto-generated `ccall`
   wrappers over RocksDB's entire C API. Anything the C API can do, this
   can do; it's the escape hatch, not meant for everyday use -- see
   [Tier 1 Escape Hatch](@ref) for how and when to drop down to it.
2. **Tier 2** ([`opendb`](@ref), [`DB`](@ref), [`put!`](@ref)/[`get`](@ref)/
   [`delete!`](@ref), [`WriteBatch`](@ref), [`DBIterator`](@ref),
   [`Snapshot`](@ref), [`BackupEngine`](@ref), [`compact!`](@ref), ...) --
   idiomatic Julia wrappers with sensible defaults, for everyday use.
3. **Tier 3** ([`RocksDBDict`](@ref), [`ColumnFamilies`](@ref),
   [`RocksDBSnapshotView`](@ref)) -- an `AbstractDict`-like facade with
   compression/cache/environment knobs surfaced directly in the
   constructor, atomic batch writes, column families as dict-like
   sub-namespaces, and read-only point-in-time snapshot views.

The tiers aren't an either/or choice -- see [Mixing Tier 2 and Tier 3](@ref)
for how to combine Tier 2 and Tier 3, and [Tier 1 Escape Hatch](@ref) for
Tier 1 and Tier 2.

## Where to start

New to the package? Start with the tutorials, in order:

1. [Getting Started](@ref)
2. [Compression](@ref)
3. [Iteration and Range Scans](@ref)
4. [Write Batches](@ref)
5. [Column Families](@ref)
6. [TTL Databases](@ref)
7. [Compaction](@ref)
8. [Snapshots](@ref)
9. [Backups](@ref)
10. [Tier 1 Escape Hatch](@ref)
11. [Mixing Tier 2 and Tier 3](@ref)

Already know what you're looking for? Jump to the
[Tier 2 API Reference](@ref) or [Tier 3 API Reference](@ref).

## Development

See [`CLAUDE.md`](https://github.com/sadit/RocksDB.jl/blob/main/CLAUDE.md)
for the project's internal architecture notes (version pins, why things
are built the way they are, what's deferred).

## License

MIT. See [`LICENSE`](https://github.com/sadit/RocksDB.jl/blob/main/LICENSE).
