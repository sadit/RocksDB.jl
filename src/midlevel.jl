# Tier 2: idiomatic mid-level API over LibRocksDB, with sane defaults and
# Julia-style resource management (finalizers, exceptions, do-blocks).

const Lib = LibRocksDB

"""
    RocksDBException(msg)

Thrown whenever a RocksDB C API call reports an error (i.e. sets a non-NULL
`errptr`).
"""
struct RocksDBException <: Exception
    msg::String
end
Base.showerror(io::IO, e::RocksDBException) = print(io, "RocksDBException: ", e.msg)

# Every RocksDB C API "fallible" call takes a `char **errptr` as its last
# argument. This runs `f` with a fresh errptr, checks it, and frees the
# C-allocated error string on failure.
function checked(f::Function)
    errptr = Ref{Ptr{Cchar}}(C_NULL)
    result = f(errptr)
    err = errptr[]
    if err != C_NULL
        msg = unsafe_string(err)
        Lib.rocksdb_free(err)
        throw(RocksDBException(msg))
    end
    return result
end

const COMPRESSION_TYPES = (
    none = Lib.rocksdb_no_compression,
    snappy = Lib.rocksdb_snappy_compression,
    zlib = Lib.rocksdb_zlib_compression,
    bzip2 = Lib.rocksdb_bz2_compression,
    lz4 = Lib.rocksdb_lz4_compression,
    lz4hc = Lib.rocksdb_lz4hc_compression,
    zstd = Lib.rocksdb_zstd_compression,
)

compression_code(c::Integer) = Cint(c)
function compression_code(c::Symbol)
    haskey(COMPRESSION_TYPES, c) ||
        throw(ArgumentError("unknown compression $c, expected one of $(keys(COMPRESSION_TYPES))"))
    return Cint(getfield(COMPRESSION_TYPES, c))
end

# ------------------------------------------------------------------------
# Cache / FilterPolicy: small standalone wrappers so their lifetime can be
# managed by Julia's GC independently of any particular `Options`/`DB`.
# ------------------------------------------------------------------------

mutable struct Cache
    ptr::Ptr{Lib.rocksdb_cache_t}
    function Cache(capacity_bytes::Integer)
        ptr = Lib.rocksdb_cache_create_lru(Csize_t(capacity_bytes))
        cache = new(ptr)
        finalizer(c -> c.ptr != C_NULL && Lib.rocksdb_cache_destroy(c.ptr), cache)
        return cache
    end
end

# Unlike `Cache` (which is stored as a `shared_ptr` copy, safe to destroy
# our handle to independently of RocksDB's use of it), a `FilterPolicy`
# handed to `rocksdb_block_based_options_set_filter_policy` has its
# ownership transferred: RocksDB does `options.filter_policy.reset(ptr)`,
# taking sole ownership of that exact C++ object. So once a FilterPolicy has
# been attached to a table's options, our finalizer must NOT also destroy
# it (that would be a double free) -- `owned` tracks this.
mutable struct FilterPolicy
    ptr::Ptr{Lib.rocksdb_filterpolicy_t}
    owned::Bool
    function FilterPolicy(; bits_per_key::Real = 10.0)
        ptr = Lib.rocksdb_filterpolicy_create_bloom_full(Cdouble(bits_per_key))
        fp = new(ptr, true)
        finalizer(f -> f.owned && f.ptr != C_NULL && Lib.rocksdb_filterpolicy_destroy(f.ptr), fp)
        return fp
    end
end

# ------------------------------------------------------------------------
# Env: RocksDB's OS-facing environment (background thread pools, etc).
# ------------------------------------------------------------------------

mutable struct Env
    ptr::Ptr{Lib.rocksdb_env_t}
    function Env(; background_threads::Union{Nothing,Integer} = nothing,
                 high_priority_background_threads::Union{Nothing,Integer} = nothing)
        ptr = Lib.rocksdb_create_default_env()
        env = new(ptr)
        background_threads !== nothing &&
            Lib.rocksdb_env_set_background_threads(ptr, Cint(background_threads))
        high_priority_background_threads !== nothing &&
            Lib.rocksdb_env_set_high_priority_background_threads(ptr, Cint(high_priority_background_threads))
        finalizer(e -> e.ptr != C_NULL && Lib.rocksdb_env_destroy(e.ptr), env)
        return env
    end
end

# ------------------------------------------------------------------------
# Options
# ------------------------------------------------------------------------

"""
    Options(; kwargs...)

Wraps `rocksdb_options_t` with defaults that work well for most uses:
zstd compression, a 10-bits-per-key bloom filter, an 8 MiB block cache,
and `create_if_missing = true`.

Keyword arguments: `create_if_missing`, `error_if_exists`,
`create_missing_column_families` (like `create_if_missing`, but for column
families named in `opendb`'s `column_families` list that don't exist yet),
`compression` (a `Symbol` in `keys(RocksDB.COMPRESSION_TYPES)` or an integer
compression code), `max_open_files`, `max_background_jobs`,
`write_buffer_size`, `bloom_bits_per_key` (set to `nothing` to disable the
bloom filter), `block_cache_size` (bytes; set to `nothing` to disable the
block cache), `env`, `parallelism` (passed to
`rocksdb_options_increase_parallelism`).
"""
mutable struct Options
    ptr::Ptr{Lib.rocksdb_options_t}
    cache::Union{Nothing,Cache}
    filter::Union{Nothing,FilterPolicy}
    env::Union{Nothing,Env}

    function Options(;
        create_if_missing::Bool = true,
        error_if_exists::Bool = false,
        create_missing_column_families::Bool = false,
        compression::Union{Symbol,Integer} = :zstd,
        max_open_files::Union{Nothing,Integer} = nothing,
        max_background_jobs::Union{Nothing,Integer} = nothing,
        write_buffer_size::Union{Nothing,Integer} = nothing,
        bloom_bits_per_key::Union{Nothing,Real} = 10.0,
        block_cache_size::Union{Nothing,Integer} = 8 * 1024 * 1024,
        env::Union{Nothing,Env} = nothing,
        parallelism::Union{Nothing,Integer} = nothing,
    )
        ptr = Lib.rocksdb_options_create()
        opts = new(ptr, nothing, nothing, nothing)

        Lib.rocksdb_options_set_create_if_missing(ptr, create_if_missing)
        Lib.rocksdb_options_set_error_if_exists(ptr, error_if_exists)
        Lib.rocksdb_options_set_create_missing_column_families(ptr, create_missing_column_families)
        Lib.rocksdb_options_set_compression(ptr, compression_code(compression))
        max_open_files !== nothing &&
            Lib.rocksdb_options_set_max_open_files(ptr, Cint(max_open_files))
        max_background_jobs !== nothing &&
            Lib.rocksdb_options_set_max_background_jobs(ptr, Cint(max_background_jobs))
        write_buffer_size !== nothing &&
            Lib.rocksdb_options_set_write_buffer_size(ptr, Csize_t(write_buffer_size))
        parallelism !== nothing &&
            Lib.rocksdb_options_increase_parallelism(ptr, Cint(parallelism))

        if env !== nothing
            opts.env = env
            Lib.rocksdb_options_set_env(ptr, env.ptr)
        end

        if bloom_bits_per_key !== nothing || block_cache_size !== nothing
            table_opts = Lib.rocksdb_block_based_options_create()
            try
                if bloom_bits_per_key !== nothing
                    opts.filter = FilterPolicy(; bits_per_key = bloom_bits_per_key)
                    Lib.rocksdb_block_based_options_set_filter_policy(table_opts, opts.filter.ptr)
                    opts.filter.owned = false  # ownership transferred to the table options, see FilterPolicy
                end
                if block_cache_size !== nothing
                    opts.cache = Cache(block_cache_size)
                    Lib.rocksdb_block_based_options_set_block_cache(table_opts, opts.cache.ptr)
                end
                Lib.rocksdb_options_set_block_based_table_factory(ptr, table_opts)
            finally
                Lib.rocksdb_block_based_options_destroy(table_opts)
            end
        end

        finalizer(o -> o.ptr != C_NULL && Lib.rocksdb_options_destroy(o.ptr), opts)
        return opts
    end
end

# ------------------------------------------------------------------------
# WriteOptions / ReadOptions (thin, most users just want the defaults)
# ------------------------------------------------------------------------

mutable struct WriteOptions
    ptr::Ptr{Lib.rocksdb_writeoptions_t}
    function WriteOptions(; sync::Bool = false)
        ptr = Lib.rocksdb_writeoptions_create()
        wo = new(ptr)
        sync && Lib.rocksdb_writeoptions_set_sync(ptr, true)
        finalizer(w -> w.ptr != C_NULL && Lib.rocksdb_writeoptions_destroy(w.ptr), wo)
        return wo
    end
end

mutable struct Snapshot
    ptr::Ptr{Lib.rocksdb_snapshot_t}
    db::Any  # keep the owning DB alive
end

mutable struct ReadOptions
    ptr::Ptr{Lib.rocksdb_readoptions_t}
    snapshot::Union{Nothing,Snapshot}
    function ReadOptions(; snapshot::Union{Nothing,Snapshot} = nothing)
        ptr = Lib.rocksdb_readoptions_create()
        ro = new(ptr, snapshot)
        snapshot !== nothing && Lib.rocksdb_readoptions_set_snapshot(ptr, snapshot.ptr)
        finalizer(r -> r.ptr != C_NULL && Lib.rocksdb_readoptions_destroy(r.ptr), ro)
        return ro
    end
end

# ------------------------------------------------------------------------
# Column family handle
# ------------------------------------------------------------------------

mutable struct ColumnFamily
    ptr::Ptr{Lib.rocksdb_column_family_handle_t}
    name::String
end

# ------------------------------------------------------------------------
# DB
# ------------------------------------------------------------------------

"""
    DB

A handle to an open RocksDB database. Construct with [`opendb`](@ref); close
with `close` (or let the finalizer do it). Supports the `do`-block form:

```julia
RocksDB.opendb(path) do db
    put!(db, "k", "v")
end
```
"""
mutable struct DB
    ptr::Ptr{Lib.rocksdb_t}
    options::Options
    column_families::Dict{String,ColumnFamily}
    default_write_options::WriteOptions
    default_read_options::ReadOptions
    children::Vector{WeakRef}  # live DBIterators/Snapshots -- see _close!
end

Base.isopen(db::DB) = db.ptr != C_NULL

# RocksDB requires every iterator/snapshot derived from a DB to be destroyed
# before the DB itself is closed. Since Julia finalizers run at the GC's
# discretion (not necessarily before this runs), we can't rely on a
# `DBIterator`/`Snapshot` finalizing itself in time -- so `DB` tracks its
# children and proactively finalizes any still-live ones first.
function _close!(db::DB)
    if db.ptr != C_NULL
        for wr in db.children
            child = wr.value
            child !== nothing && finalize(child)
        end
        empty!(db.children)
        Lib.rocksdb_close(db.ptr)
        db.ptr = Ptr{Lib.rocksdb_t}(C_NULL)
    end
    return nothing
end

Base.close(db::DB) = _close!(db)

"""
    opendb(path; kwargs...) -> DB
    opendb(f, path; kwargs...)

Open (creating if needed, by default) the RocksDB database at `path`.
Keyword arguments not related to column families are forwarded to
[`Options`](@ref) unless an `options::Options` is given directly.
Pass `column_families = ["default", "other", ...]` to open multiple
column families at once (all opened with the same `Options` unless you
pass `options` yourself).

The `do`-block form guarantees the database is closed even if an
exception is thrown.
"""
function opendb(path::AbstractString; options::Union{Nothing,Options} = nothing,
              column_families::Union{Nothing,Vector{<:AbstractString}} = nothing,
              read_only::Bool = false, kwargs...)
    opts = options === nothing ? Options(; kwargs...) : options

    if column_families === nothing
        dbptr = checked() do errptr
            if read_only
                Lib.rocksdb_open_for_read_only(opts.ptr, path, false, errptr)
            else
                Lib.rocksdb_open(opts.ptr, path, errptr)
            end
        end
        cfs = Dict{String,ColumnFamily}()
    else
        names = collect(String, column_families)
        n = length(names)
        name_ptrs = [Ptr{Cchar}(pointer(nm)) for nm in names]
        cf_opts_ptrs = fill(opts.ptr, n)
        cf_handles = Vector{Ptr{Lib.rocksdb_column_family_handle_t}}(undef, n)
        dbptr = GC.@preserve names checked() do errptr
            if read_only
                Lib.rocksdb_open_for_read_only_column_families(
                    opts.ptr, path, Cint(n),
                    pointer(name_ptrs), pointer(cf_opts_ptrs), pointer(cf_handles), false, errptr,
                )
            else
                Lib.rocksdb_open_column_families(
                    opts.ptr, path, Cint(n),
                    pointer(name_ptrs), pointer(cf_opts_ptrs), pointer(cf_handles), errptr,
                )
            end
        end
        cfs = Dict(names[i] => ColumnFamily(cf_handles[i], names[i]) for i in 1:n)
    end

    db = DB(dbptr, opts, cfs, WriteOptions(), ReadOptions(), WeakRef[])
    finalizer(_close!, db)
    return db
end

function opendb(f::Function, path::AbstractString; kwargs...)
    db = opendb(path; kwargs...)
    try
        return f(db)
    finally
        close(db)
    end
end

"""
    create_column_family(db, name; options=db.options) -> ColumnFamily

Create (and register on `db`) a new column family.
"""
function create_column_family(db::DB, name::AbstractString; options::Options = db.options)
    ptr = checked(errptr -> Lib.rocksdb_create_column_family(db.ptr, options.ptr, name, errptr))
    cf = ColumnFamily(ptr, String(name))
    db.column_families[String(name)] = cf
    return cf
end

column_families(db::DB) = db.column_families

_cf_ptr(db::DB, cf::Nothing) = C_NULL
_cf_ptr(db::DB, cf::ColumnFamily) = cf.ptr
function _cf_ptr(db::DB, cf::AbstractString)
    haskey(db.column_families, cf) ||
        throw(ArgumentError("no column family named $(repr(cf)) is open on this DB"))
    return db.column_families[cf].ptr
end

# ------------------------------------------------------------------------
# put! / get / delete!
# ------------------------------------------------------------------------

_bytes(x::AbstractVector{UInt8}) = x
_bytes(x::AbstractString) = codeunits(x)

"""
    put!(db, key, value; cf=nothing, options=db.default_write_options)

`key` and `value` may be any `AbstractString` or byte vector.
"""
function Base.put!(db::DB, key, value; cf::Union{Nothing,ColumnFamily,AbstractString} = nothing,
                    options::WriteOptions = db.default_write_options)
    k, v = _bytes(key), _bytes(value)
    GC.@preserve k v checked() do errptr
        if cf === nothing
            Lib.rocksdb_put(db.ptr, options.ptr, pointer(k), sizeof(k), pointer(v), sizeof(v), errptr)
        else
            Lib.rocksdb_put_cf(db.ptr, options.ptr, _cf_ptr(db, cf), pointer(k), sizeof(k), pointer(v), sizeof(v), errptr)
        end
    end
    return db
end

"""
    get(db, key; cf=nothing, options=db.default_read_options) -> Union{Vector{UInt8},Nothing}
"""
function Base.get(db::DB, key; cf::Union{Nothing,ColumnFamily,AbstractString} = nothing,
                   options::ReadOptions = db.default_read_options)
    k = _bytes(key)
    vallen = Ref{Csize_t}(0)
    valptr = GC.@preserve k checked() do errptr
        if cf === nothing
            Lib.rocksdb_get(db.ptr, options.ptr, pointer(k), sizeof(k), vallen, errptr)
        else
            Lib.rocksdb_get_cf(db.ptr, options.ptr, _cf_ptr(db, cf), pointer(k), sizeof(k), vallen, errptr)
        end
    end
    valptr == C_NULL && return nothing
    result = unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(valptr), Int(vallen[])) |> copy
    Lib.rocksdb_free(valptr)
    return result
end

"""
    delete!(db, key; cf=nothing, options=db.default_write_options)
"""
function Base.delete!(db::DB, key; cf::Union{Nothing,ColumnFamily,AbstractString} = nothing,
                       options::WriteOptions = db.default_write_options)
    k = _bytes(key)
    GC.@preserve k checked() do errptr
        if cf === nothing
            Lib.rocksdb_delete(db.ptr, options.ptr, pointer(k), sizeof(k), errptr)
        else
            Lib.rocksdb_delete_cf(db.ptr, options.ptr, _cf_ptr(db, cf), pointer(k), sizeof(k), errptr)
        end
    end
    return db
end

Base.haskey(db::DB, key) = get(db, key) !== nothing

# ------------------------------------------------------------------------
# WriteBatch
# ------------------------------------------------------------------------

"""
    WriteBatch()

An in-memory batch of writes; apply it atomically to a `DB` with `write!`.
"""
mutable struct WriteBatch
    ptr::Ptr{Lib.rocksdb_writebatch_t}
    function WriteBatch()
        ptr = Lib.rocksdb_writebatch_create()
        wb = new(ptr)
        finalizer(b -> b.ptr != C_NULL && Lib.rocksdb_writebatch_destroy(b.ptr), wb)
        return wb
    end
end

function Base.put!(batch::WriteBatch, key, value; cf::Union{Nothing,ColumnFamily} = nothing)
    k, v = _bytes(key), _bytes(value)
    GC.@preserve k v begin
        if cf === nothing
            Lib.rocksdb_writebatch_put(batch.ptr, pointer(k), sizeof(k), pointer(v), sizeof(v))
        else
            Lib.rocksdb_writebatch_put_cf(batch.ptr, cf.ptr, pointer(k), sizeof(k), pointer(v), sizeof(v))
        end
    end
    return batch
end

function Base.delete!(batch::WriteBatch, key; cf::Union{Nothing,ColumnFamily} = nothing)
    k = _bytes(key)
    GC.@preserve k begin
        if cf === nothing
            Lib.rocksdb_writebatch_delete(batch.ptr, pointer(k), sizeof(k))
        else
            Lib.rocksdb_writebatch_delete_cf(batch.ptr, cf.ptr, pointer(k), sizeof(k))
        end
    end
    return batch
end

Base.empty!(batch::WriteBatch) = (Lib.rocksdb_writebatch_clear(batch.ptr); batch)

"""
    write!(db, batch; options=db.default_write_options)

Atomically apply `batch` to `db`.
"""
function write!(db::DB, batch::WriteBatch; options::WriteOptions = db.default_write_options)
    checked(errptr -> Lib.rocksdb_write(db.ptr, options.ptr, batch.ptr, errptr))
    return db
end

# ------------------------------------------------------------------------
# Iteration
# ------------------------------------------------------------------------

"""
    DBIterator(db; cf=nothing, options=ReadOptions())

Iterates `(key, value)` pairs (as `Vector{UInt8}`) in ascending key order.
"""
mutable struct DBIterator
    ptr::Ptr{Lib.rocksdb_iterator_t}
    db::DB  # keep alive
    options::ReadOptions  # keep alive (may hold a snapshot)
    function DBIterator(db::DB; cf::Union{Nothing,ColumnFamily,AbstractString} = nothing,
                        options::ReadOptions = ReadOptions())
        ptr = cf === nothing ?
            Lib.rocksdb_create_iterator(db.ptr, options.ptr) :
            Lib.rocksdb_create_iterator_cf(db.ptr, options.ptr, _cf_ptr(db, cf))
        it = new(ptr, db, options)
        finalizer(i -> i.ptr != C_NULL && Lib.rocksdb_iter_destroy(i.ptr), it)
        push!(db.children, WeakRef(it))
        return it
    end
end

seek_to_first!(it::DBIterator) = (Lib.rocksdb_iter_seek_to_first(it.ptr); it)
seek_to_last!(it::DBIterator) = (Lib.rocksdb_iter_seek_to_last(it.ptr); it)
function seek!(it::DBIterator, key)
    k = _bytes(key)
    GC.@preserve k Lib.rocksdb_iter_seek(it.ptr, pointer(k), sizeof(k))
    return it
end
valid(it::DBIterator) = Lib.rocksdb_iter_valid(it.ptr) != 0

function _check_iter_error(it::DBIterator)
    checked(errptr -> Lib.rocksdb_iter_get_error(it.ptr, errptr))
    return nothing
end

function key(it::DBIterator)
    len = Ref{Csize_t}(0)
    p = Lib.rocksdb_iter_key(it.ptr, len)
    return copy(unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(p), Int(len[])))
end

function value(it::DBIterator)
    len = Ref{Csize_t}(0)
    p = Lib.rocksdb_iter_value(it.ptr, len)
    return copy(unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(p), Int(len[])))
end

function Base.iterate(it::DBIterator, _state = nothing)
    if _state === nothing
        seek_to_first!(it)
    end
    if !valid(it)
        _check_iter_error(it)
        return nothing
    end
    kv = (key(it), value(it))
    Lib.rocksdb_iter_next(it.ptr)
    return kv, true
end
Base.IteratorSize(::Type{DBIterator}) = Base.SizeUnknown()
Base.eltype(::Type{DBIterator}) = Tuple{Vector{UInt8},Vector{UInt8}}

# ------------------------------------------------------------------------
# Snapshots
# ------------------------------------------------------------------------

"""
    Snapshot(db)

A consistent point-in-time read view. Release it (or let the finalizer do
so) when done; pass it to `ReadOptions(; snapshot=...)` or directly as the
`options` argument's snapshot for reads.
"""
function Snapshot(db::DB)
    ptr = Lib.rocksdb_create_snapshot(db.ptr)
    snap = Snapshot(ptr, db)
    finalizer(snap) do s
        s.ptr != C_NULL && s.db.ptr != C_NULL && Lib.rocksdb_release_snapshot(s.db.ptr, s.ptr)
    end
    push!(db.children, WeakRef(snap))
    return snap
end

# ------------------------------------------------------------------------
# Properties
# ------------------------------------------------------------------------

"""
    property(db, name) -> Union{String,Nothing}

Read a RocksDB "property" (e.g. `"rocksdb.estimate-num-keys"`).
"""
function property(db::DB, name::AbstractString)
    p = Lib.rocksdb_property_value(db.ptr, name)
    p == C_NULL && return nothing
    s = unsafe_string(p)
    Lib.rocksdb_free(p)
    return s
end
