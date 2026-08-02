```@meta
CurrentModule = RocksDB
```

# Tier 3 API Reference

The `Dict`-like facade over Tier 2: compression/cache/environment knobs
surfaced directly in each constructor, atomic batches, column families as
sub-namespaces, and point-in-time snapshot views. See the tutorials
(starting with [Getting Started](@ref)) for narrative walkthroughs; this
page is a reference, organized by theme.

## `RocksDBDict`

```@docs
RocksDBDict
length(::RocksDBDict)
```

## Batches

```@docs
batch
```

## Column families as sub-namespaces

```@docs
ColumnFamilies
create_column_family(::ColumnFamilies{K,V}, ::Union{AbstractString,Symbol}) where {K,V}
```

## Point-in-time snapshot views

```@docs
RocksDBSnapshotView
snapshot
length(::RocksDBSnapshotView)
```
