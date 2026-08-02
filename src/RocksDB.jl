module RocksDB

using Serialization: serialize, deserialize

# Tier 1: near-direct, auto-generated ccall wrappers over the full RocksDB C
# API (see gen/generator.jl). Escape hatch for anything the C API can do;
# not re-exported at this level on purpose -- use `RocksDB.LibRocksDB.xxx`.
include("lib/LibRocksDB.jl")

# Tier 2: idiomatic mid-level API (Options, DB, WriteBatch, iterators, ...).
include("midlevel.jl")

# Tier 3: Dict-like facade (RocksDBDict).
include("dict.jl")

export opendb, Options, DB, WriteBatch, WriteOptions, ReadOptions, DBIterator, Snapshot,
       Env, Cache, FilterPolicy, ColumnFamily, RocksDBException,
       put!, write!, create_column_family, column_families, property,
       seek_to_first!, seek_to_last!, seek!, advance!, valid, key, value,
       RocksDBDict, batch, ColumnFamilies, RocksDBSnapshotView, snapshot

end
