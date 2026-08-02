# Iteration and Range Scans

## Sorted iteration

Unlike `Base.Dict`, RocksDB stores keys in sorted (byte-lexicographic)
order, and [`DBIterator`](@ref) walks them in that order -- a real bonus
over an ordinary hash-based dict:

```julia
using RocksDB

db = opendb(mktempdir() * "/orderdb")
put!(db, "banana", "2")
put!(db, "apple", "1")
put!(db, "cherry", "3")

for (k, v) in DBIterator(db)
    println(String(k), " => ", String(v))   # apple, banana, cherry -- in that order
end
close(db)
```

`RocksDBDict`'s own iteration (`for (k, v) in dict`, `keys(dict)`,
`values(dict)`) is sorted the same way -- see [Column Families](@ref) for
more on the dict-like API, or just:

```julia
using RocksDB

d = RocksDBDict{String,String}(mktempdir() * "/orderdict")
d["banana"] = "2"; d["apple"] = "1"; d["cherry"] = "3"
collect(keys(d))   # ["apple", "banana", "cherry"]
close(d)
```

## Manual control: `seek!`, `valid`, `key`, `value`, `advance!`

`for (k, v) in DBIterator(db)` is sugar built entirely from five lower-level
functions -- reach for them directly when you need to start somewhere
other than the beginning, or stop before the end. This is exactly how to
do a **prefix scan** (find every key starting with a given prefix), a very
common RocksDB pattern that sorted iteration makes possible:

```julia
using RocksDB

db = opendb(mktempdir() * "/prefixdb")
put!(db, "user:1", "alice")
put!(db, "user:2", "bob")
put!(db, "product:1", "widget")

it = DBIterator(db)
seek!(it, "user:")                       # jump to the first key >= "user:"
while valid(it) && startswith(String(key(it)), "user:")
    println(String(key(it)), " => ", String(value(it)))
    advance!(it)
end
close(db)
```

- [`seek_to_first!`](@ref)/[`seek_to_last!`](@ref)/[`seek!`](@ref) position
  the iterator.
- [`valid`](@ref) tells you whether the current position is a real entry
  (`false` once you've run off either end).
- [`key`](@ref)/[`value`](@ref) read the current entry.
- [`advance!`](@ref) moves to the next entry in ascending order.

## Point-in-time-consistent iteration

Pass a snapshot-bound `options` to `DBIterator` (or use
[`RocksDB.RocksDBSnapshotView`](@ref) at the Tier 3 level) so a long-running
scan isn't affected by writes made after it started -- see
[Snapshots](@ref).
