@testset "LibRocksDB (tier 1)" begin
    Lib = RocksDB.LibRocksDB

    dir = mktempdir()
    path = joinpath(dir, "lowlevel_db")

    opts = Lib.rocksdb_options_create()
    Lib.rocksdb_options_set_create_if_missing(opts, true)

    errptr = Ref{Ptr{Cchar}}(C_NULL)
    db = Lib.rocksdb_open(opts, path, errptr)
    @test errptr[] == C_NULL
    @test db != C_NULL

    wopts = Lib.rocksdb_writeoptions_create()
    ropts = Lib.rocksdb_readoptions_create()

    errptr[] = C_NULL
    Lib.rocksdb_put(db, wopts, "hello", 5, "world", 5, errptr)
    @test errptr[] == C_NULL

    vallen = Ref{Csize_t}(0)
    errptr[] = C_NULL
    valptr = Lib.rocksdb_get(db, ropts, "hello", 5, vallen, errptr)
    @test errptr[] == C_NULL
    @test valptr != C_NULL
    @test unsafe_string(Ptr{UInt8}(valptr), Int(vallen[])) == "world"
    Lib.rocksdb_free(valptr)

    Lib.rocksdb_writeoptions_destroy(wopts)
    Lib.rocksdb_readoptions_destroy(ropts)
    Lib.rocksdb_close(db)
    Lib.rocksdb_options_destroy(opts)
end
