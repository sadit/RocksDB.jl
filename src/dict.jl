# Tier 3: a Dict-like facade over Tier 2, with knobs for the things that
# matter most in practice (compression, environment/cache sizing, batches)
# surfaced directly in the constructor.

"""
    RocksDBDict{K,V}(path; compression=:zstd, create_if_missing=true, kwargs...)

An `AbstractDict{K,V}` backed by a RocksDB database. Keys/values that are
`AbstractString` or byte vectors are stored as-is; anything else is
(de)serialized with the Julia `Serialization` stdlib.

Unlike `Base.Dict`, iteration order is the **sorted key order** RocksDB
stores keys in -- a useful bonus, not just an implementation detail.

Keyword arguments accepted here on top of what [`Options`](@ref) takes:
`column_family` (a `String`, default `"default"`) and everything
`RocksDB.opendb`/`Options` accepts (`compression`, `block_cache_size`,
`bloom_bits_per_key`, `max_open_files`, `max_background_jobs`, `env`, ...).

# Batches

```julia
RocksDB.batch(dict) do b
    b["k1"] = "v1"
    b["k2"] = "v2"
end
```
commits all writes atomically (and not at all if the block throws).
"""
mutable struct RocksDBDict{K,V} <: AbstractDict{K,V}
    db::DB
    cf::String

    function RocksDBDict{K,V}(path::AbstractString; column_family::AbstractString = "default",
                               kwargs...) where {K,V}
        db = opendb(path; kwargs...)
        return new{K,V}(db, String(column_family))
    end

    """
        RocksDBDict{K,V}(db::DB, column_family::AbstractString)

    Wrap an *already-open* [`DB`](@ref) (and one of its column families) as
    a `RocksDBDict`, instead of opening a new connection. This is the
    supported way to bridge Tier 2 to Tier 3: open a `DB` yourself via
    [`opendb`](@ref) for anything the `RocksDBDict{K,V}(path; kwargs...)`
    constructor doesn't expose (`read_only=true`, a shared/custom `Env`,
    several column families opened together, ...), then get convenient
    dict-style access to it with this constructor. [`ColumnFamilies`](@ref)
    is built entirely out of this constructor, one call per column family.

    ```julia
    db = RocksDB.opendb("mydb"; read_only = true, column_families = ["default", "users"])
    users = RocksDB.RocksDBDict{String,String}(db, "users")
    users["alice"]              # read normally through the dict API
    # users["alice"] = "x"      # would throw: db was opened read_only
    close(db)                   # closes db -- `users` shares its connection, not a separate one
    ```
    """
    RocksDBDict{K,V}(db::DB, column_family::AbstractString) where {K,V} = new{K,V}(db, String(column_family))
end

RocksDBDict(path::AbstractString; kwargs...) = RocksDBDict{Any,Any}(path; kwargs...)

Base.close(d::RocksDBDict) = close(d.db)
Base.isopen(d::RocksDBDict) = isopen(d.db)

# ------------------------------------------------------------------------
# (de)serialization: pass bytes/strings through untouched, otherwise use
# the Serialization stdlib so `RocksDBDict{Any,Any}` "just works".
# ------------------------------------------------------------------------

_cf_arg(d::RocksDBDict) = d.cf == "default" ? nothing : d.cf

_encode(::Type{V}, v::V) where {V<:AbstractVector{UInt8}} = v
_encode(::Type{V}, v::V) where {V<:AbstractString} = v
function _encode(::Type{V}, v) where {V}
    io = IOBuffer()
    serialize(io, v)
    return take!(io)
end

_decode(::Type{V}, bytes::Vector{UInt8}) where {V<:AbstractVector{UInt8}} = convert(V, bytes)
_decode(::Type{V}, bytes::Vector{UInt8}) where {V<:AbstractString} = V(String(bytes))
_decode(::Type{V}, bytes::Vector{UInt8}) where {V} = deserialize(IOBuffer(bytes))::V

_encode_key(d::RocksDBDict{K}, k::K) where {K} = _encode(K, k)

# ------------------------------------------------------------------------
# AbstractDict protocol
# ------------------------------------------------------------------------

function Base.setindex!(d::RocksDBDict{K,V}, v, k) where {K,V}
    put!(d.db, _encode_key(d, convert(K, k)), _encode(V, convert(V, v)); cf = _cf_arg(d))
    return d
end

function Base.getindex(d::RocksDBDict{K,V}, k) where {K,V}
    raw = get(d.db, _encode_key(d, convert(K, k)); cf = _cf_arg(d))
    raw === nothing && throw(KeyError(k))
    return _decode(V, raw)
end

function Base.get(d::RocksDBDict{K,V}, k, default) where {K,V}
    raw = get(d.db, _encode_key(d, convert(K, k)); cf = _cf_arg(d))
    raw === nothing && return default
    return _decode(V, raw)
end

function Base.get(f::Union{Function,Type}, d::RocksDBDict{K,V}, k) where {K,V}
    raw = get(d.db, _encode_key(d, convert(K, k)); cf = _cf_arg(d))
    raw === nothing && return f()
    return _decode(V, raw)
end

Base.haskey(d::RocksDBDict{K}, k) where {K} = get(d.db, _encode_key(d, convert(K, k)); cf = _cf_arg(d)) !== nothing

function Base.delete!(d::RocksDBDict{K}, k) where {K}
    delete!(d.db, _encode_key(d, convert(K, k)); cf = _cf_arg(d))
    return d
end

"""
    length(d::RocksDBDict)

**Approximate** key count, via RocksDB's O(1) `"rocksdb.estimate-num-keys"`
property (it can undercount, e.g. for very recently written, not-yet-
flushed data). For an exact count, `count(Returns(true), d)` (which
actually iterates) is available like for any other `AbstractDict`.
"""
function Base.length(d::RocksDBDict)
    s = property(d.db, "rocksdb.estimate-num-keys"; cf = _cf_arg(d))
    return s === nothing ? 0 : parse(Int, s)
end

# `length` above is only approximate, so unlike Base.Dict this dict's
# IteratorSize must NOT be the AbstractDict default of `HasLength()` --
# that trait tells generic consumers (`collect`, etc.) to pre-allocate
# exactly `length(d)` slots, which breaks (`ArgumentError: destination has
# fewer elements than required`) the moment the estimate undercounts.
Base.IteratorSize(::Type{<:RocksDBDict}) = Base.SizeUnknown()

# For the same reason, `isempty` must check via the iterator (exact, and
# still O(1): it only looks at the first entry) rather than `length(d) == 0`.
Base.isempty(d::RocksDBDict) = iterate(d) === nothing

function Base.iterate(d::RocksDBDict{K,V}, state = nothing) where {K,V}
    it = state === nothing ? DBIterator(d.db; cf = _cf_arg(d)) : state
    r = iterate(it, state === nothing ? nothing : true)
    r === nothing && return nothing
    (kraw, vraw), _ = r
    return (_decode(K, kraw) => _decode(V, vraw)), it
end

"""
    batch(f, dict::RocksDBDict)

Run `f` with a batch-like handle supporting `b[k] = v` and `delete!(b, k)`;
all writes are committed atomically when `f` returns normally, and
discarded if `f` throws.
"""
function batch(f, d::RocksDBDict{K,V}) where {K,V}
    wb = WriteBatch()
    proxy = RocksDBBatchProxy{K,V}(d, wb)
    f(proxy)
    write!(d.db, wb)
    return d
end

struct RocksDBBatchProxy{K,V}
    dict::RocksDBDict{K,V}
    wb::WriteBatch
end

function Base.setindex!(p::RocksDBBatchProxy{K,V}, v, k) where {K,V}
    put!(p.wb, _encode_key(p.dict, convert(K, k)), _encode(V, convert(V, v)); cf = nothing)
    return p
end

function Base.delete!(p::RocksDBBatchProxy{K}, k) where {K}
    delete!(p.wb, _encode_key(p.dict, convert(K, k)); cf = nothing)
    return p
end

# ------------------------------------------------------------------------
# ColumnFamilies: a two-level container. Indexing it by column-family name
# returns a plain RocksDBDict scoped to that column family, sharing one
# underlying DB connection -- so `store[name]` always means "pick a
# namespace" and the RocksDBDict's own `[]` always means "pick a key",
# with no ambiguity regardless of K.
# ------------------------------------------------------------------------

"""
    ColumnFamilies{K,V}(path; column_families=["default"], kwargs...)

An `AbstractDict{String,RocksDBDict{K,V}}` where each value is a
[`RocksDBDict`](@ref) scoped to one column family of the same underlying
RocksDB database at `path`. All the column families listed in
`column_families` are opened (and must already exist in the database,
except `"default"`, which is created automatically if missing).

```julia
store = RocksDB.ColumnFamilies("mydb"; column_families=["default", "users", "sessions"])
store["users"]["alice"] = "admin"
store[:sessions]["tok-1"] = "active"
close(store)   # closes the shared DB and every RocksDBDict handed out
```

Use [`create_column_family`](@ref)`(store, name)` to add a new column
family (and its `RocksDBDict`) after construction. `kwargs...` are
forwarded to [`Options`](@ref) (`compression`, `block_cache_size`, ...),
applied to every column family opened here.
"""
mutable struct ColumnFamilies{K,V} <: AbstractDict{String,RocksDBDict{K,V}}
    db::DB
    dicts::Dict{String,RocksDBDict{K,V}}

    function ColumnFamilies{K,V}(path::AbstractString;
                                  column_families::Vector{<:AbstractString} = ["default"],
                                  create_missing_column_families::Bool = true,
                                  kwargs...) where {K,V}
        names = collect(String, column_families)
        db = opendb(path; column_families = names,
                    create_missing_column_families, kwargs...)
        dicts = Dict(name => RocksDBDict{K,V}(db, name) for name in names)
        return new{K,V}(db, dicts)
    end
end

ColumnFamilies(path::AbstractString; kwargs...) = ColumnFamilies{Any,Any}(path; kwargs...)

Base.close(s::ColumnFamilies) = close(s.db)
Base.isopen(s::ColumnFamilies) = isopen(s.db)

_cfname(name::AbstractString) = String(name)
_cfname(name::Symbol) = String(name)

function Base.getindex(s::ColumnFamilies, name::Union{AbstractString,Symbol})
    n = _cfname(name)
    haskey(s.dicts, n) || throw(KeyError(name))
    return s.dicts[n]
end

Base.haskey(s::ColumnFamilies, name::Union{AbstractString,Symbol}) = haskey(s.dicts, _cfname(name))
Base.length(s::ColumnFamilies) = length(s.dicts)
Base.isempty(s::ColumnFamilies) = isempty(s.dicts)
Base.iterate(s::ColumnFamilies, state...) = iterate(s.dicts, state...)

"""
    create_column_family(store::ColumnFamilies, name) -> RocksDBDict

Create a new column family on `store`'s underlying database and return its
(now registered) `RocksDBDict`.
"""
function create_column_family(s::ColumnFamilies{K,V}, name::Union{AbstractString,Symbol}) where {K,V}
    n = _cfname(name)
    create_column_family(s.db, n)
    d = RocksDBDict{K,V}(s.db, n)
    s.dicts[n] = d
    return d
end

# ------------------------------------------------------------------------
# RocksDBSnapshotView: a read-only view of a RocksDBDict pinned to a
# point-in-time snapshot, so reads/iteration are unaffected by writes made
# after the snapshot was taken. Purely additive on top of RocksDBDict's own
# methods (see `RocksDB.snapshot` below) -- no existing method signatures
# change.
# ------------------------------------------------------------------------

"""
    RocksDBSnapshotView{K,V}

A read-only `AbstractDict{K,V}` view of a [`RocksDBDict`](@ref)'s column
family, pinned to a point-in-time [`Snapshot`](@ref): writes made to the
underlying dict *after* the view was created are invisible to it, both via
indexing and iteration. Construct with [`snapshot`](@ref); writing to a
view (`setindex!`, `delete!`, `empty!`) throws.

`length` is **not** point-in-time consistent -- RocksDB's
`"rocksdb.estimate-num-keys"` property has no snapshot/`ReadOptions`
parameter in the C API, so it always reflects the live database, unlike
`getindex`/`haskey`/iteration on the same view.

`close(view)` releases only the snapshot (and its `ReadOptions`), **not**
the shared underlying `DB` -- that connection is owned by whichever
`RocksDBDict`/`ColumnFamilies` it came from and keeps working after the
view is closed.
"""
mutable struct RocksDBSnapshotView{K,V} <: AbstractDict{K,V}
    db::DB
    cf::String
    snapshot::Snapshot
    read_options::ReadOptions
end

_cf_arg(v::RocksDBSnapshotView) = v.cf == "default" ? nothing : v.cf
_encode_key(v::RocksDBSnapshotView{K}, k::K) where {K} = _encode(K, k)

"""
    snapshot(d::RocksDBDict) -> RocksDBSnapshotView
    snapshot(f, d::RocksDBDict)

Create a [`RocksDBSnapshotView`](@ref) of `d`'s column family as it is
right now. The do-block form releases the snapshot automatically (even if
`f` throws); otherwise release it with `close(view)` when done.

```julia
view = RocksDB.snapshot(d)
d["k"] = "changed after the snapshot"
view["k"]   # still the pre-snapshot value (or a KeyError if it didn't exist yet)
close(view)
```
"""
function snapshot(d::RocksDBDict{K,V}) where {K,V}
    snap = Snapshot(d.db)
    ro = ReadOptions(; snapshot = snap)
    return RocksDBSnapshotView{K,V}(d.db, d.cf, snap, ro)
end

function snapshot(f, d::RocksDBDict)
    view = snapshot(d)
    try
        return f(view)
    finally
        close(view)
    end
end

Base.close(v::RocksDBSnapshotView) = (finalize(v.read_options); finalize(v.snapshot); nothing)
Base.isopen(v::RocksDBSnapshotView) = v.snapshot.ptr != C_NULL

function Base.getindex(v::RocksDBSnapshotView{K,V}, k) where {K,V}
    raw = get(v.db, _encode_key(v, convert(K, k)); cf = _cf_arg(v), options = v.read_options)
    raw === nothing && throw(KeyError(k))
    return _decode(V, raw)
end

function Base.get(v::RocksDBSnapshotView{K,V}, k, default) where {K,V}
    raw = get(v.db, _encode_key(v, convert(K, k)); cf = _cf_arg(v), options = v.read_options)
    raw === nothing && return default
    return _decode(V, raw)
end

function Base.get(f::Union{Function,Type}, v::RocksDBSnapshotView{K,V}, k) where {K,V}
    raw = get(v.db, _encode_key(v, convert(K, k)); cf = _cf_arg(v), options = v.read_options)
    raw === nothing && return f()
    return _decode(V, raw)
end

Base.haskey(v::RocksDBSnapshotView{K}, k) where {K} =
    get(v.db, _encode_key(v, convert(K, k)); cf = _cf_arg(v), options = v.read_options) !== nothing

"""
    length(v::RocksDBSnapshotView)

**Not** point-in-time consistent -- see [`RocksDBSnapshotView`](@ref).
"""
function Base.length(v::RocksDBSnapshotView)
    s = property(v.db, "rocksdb.estimate-num-keys"; cf = _cf_arg(v))
    return s === nothing ? 0 : parse(Int, s)
end
Base.IteratorSize(::Type{<:RocksDBSnapshotView}) = Base.SizeUnknown()
Base.isempty(v::RocksDBSnapshotView) = iterate(v) === nothing

function Base.iterate(v::RocksDBSnapshotView{K,V}, state = nothing) where {K,V}
    it = state === nothing ? DBIterator(v.db; cf = _cf_arg(v), options = v.read_options) : state
    r = iterate(it, state === nothing ? nothing : true)
    r === nothing && return nothing
    (kraw, vraw), _ = r
    return (_decode(K, kraw) => _decode(V, vraw)), it
end

Base.setindex!(::RocksDBSnapshotView, _v, _k) =
    error("RocksDBSnapshotView is read-only (backed by a point-in-time snapshot)")
Base.delete!(::RocksDBSnapshotView, _k) =
    error("RocksDBSnapshotView is read-only (backed by a point-in-time snapshot)")
Base.empty!(::RocksDBSnapshotView) =
    error("RocksDBSnapshotView is read-only (backed by a point-in-time snapshot)")
