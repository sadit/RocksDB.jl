@testset "midlevel (tier 2)" begin
    dir = mktempdir()

    @testset "put!/get/delete!" begin
        path = joinpath(dir, "db1")
        RocksDB.opendb(path) do db
            put!(db, "k1", "v1")
            put!(db, "k2", "v2")
            @test get(db, "k1") == Vector{UInt8}("v1")
            @test get(db, "missing") === nothing
            @test haskey(db, "k2")
            delete!(db, "k1")
            @test get(db, "k1") === nothing
        end
    end

    @testset "all compression backends round-trip" begin
        for (i, c) in enumerate((:none, :snappy, :zlib, :bzip2, :lz4, :lz4hc, :zstd))
            path = joinpath(dir, "db_compression_$i")
            RocksDB.opendb(path; compression = c) do db
                put!(db, "key", "some repeated value "^50)
                @test String(get(db, "key")) == "some repeated value "^50
            end
        end
    end

    @testset "WriteBatch" begin
        path = joinpath(dir, "db_batch")
        RocksDB.opendb(path) do db
            wb = RocksDB.WriteBatch()
            put!(wb, "a", "1")
            put!(wb, "b", "2")
            delete!(wb, "a")
            write!(db, wb)
            @test get(db, "a") === nothing
            @test String(get(db, "b")) == "2"
        end
    end

    @testset "iteration is in sorted key order" begin
        path = joinpath(dir, "db_iter")
        RocksDB.opendb(path) do db
            for k in ("c", "a", "b")
                put!(db, k, k)
            end
            it = RocksDB.DBIterator(db)
            ks = [String(k) for (k, v) in it]
            @test ks == ["a", "b", "c"]
        end
    end

    @testset "column families" begin
        path = joinpath(dir, "db_cf")
        RocksDB.opendb(path) do db
            cf = create_column_family(db, "other")
            put!(db, "k", "default-value")
            put!(db, "k", "cf-value"; cf = cf)
            @test String(get(db, "k")) == "default-value"
            @test String(get(db, "k"; cf = cf)) == "cf-value"
        end
    end

    @testset "snapshot" begin
        path = joinpath(dir, "db_snap")
        RocksDB.opendb(path) do db
            put!(db, "k", "before")
            snap = RocksDB.Snapshot(db)
            put!(db, "k", "after")
            ro = RocksDB.ReadOptions(; snapshot = snap)
            @test String(get(db, "k"; options = ro)) == "before"
            @test String(get(db, "k")) == "after"
        end
    end

    @testset "exceptions" begin
        path = joinpath(dir, "db_exists")
        close(RocksDB.opendb(path))  # create it, then close so it's not locked
        opts = RocksDB.Options(; create_if_missing = false, error_if_exists = true)
        @test_throws RocksDB.RocksDBException RocksDB.opendb(path; options = opts)
    end
end
