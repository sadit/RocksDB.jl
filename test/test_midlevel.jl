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

    @testset "batch do-block" begin
        path = joinpath(dir, "db_batch_do")
        RocksDB.opendb(path) do db
            RocksDB.batch(db) do wb
                put!(wb, "a", "1")
                put!(wb, "b", "2")
            end
            @test String(get(db, "a")) == "1"
            @test String(get(db, "b")) == "2"

            @test_throws ErrorException RocksDB.batch(db) do wb
                put!(wb, "c", "3")
                error("boom")
            end
            @test get(db, "c") === nothing  # discarded, not partially applied
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

    @testset "property is column-family-scoped" begin
        # Regression test: property(db, name) and RocksDBDict/RocksDBSnapshotView's
        # length() used to always report the *default* column family's value,
        # even when scoped to a different one.
        path = joinpath(dir, "db_prop_cf")
        RocksDB.opendb(path) do db
            cf = create_column_family(db, "other")
            put!(db, "k1", "v1")
            put!(db, "k2", "v2"; cf = cf)
            @test property(db, "rocksdb.estimate-num-keys") == "1"
            @test property(db, "rocksdb.estimate-num-keys"; cf = cf) == "1"
            @test property(db, "rocksdb.estimate-num-keys"; cf = "other") == "1"
            @test property(db, "rocksdb.no-such-property") === nothing
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

    @testset "Snapshot do-block" begin
        path = joinpath(dir, "db_snap_do")
        RocksDB.opendb(path) do db
            put!(db, "k", "before")
            captured = nothing
            result = RocksDB.Snapshot(db) do snap
                captured = snap
                put!(db, "k", "after")
                ro = RocksDB.ReadOptions(; snapshot = snap)
                String(get(db, "k"; options = ro))
            end
            @test result == "before"
            @test String(get(db, "k")) == "after"
            @test captured.ptr == C_NULL  # released automatically

            # released even when the block throws
            captured2 = nothing
            @test_throws ErrorException RocksDB.Snapshot(db) do snap
                captured2 = snap
                error("boom")
            end
            @test captured2.ptr == C_NULL
        end
    end

    @testset "exceptions" begin
        path = joinpath(dir, "db_exists")
        close(RocksDB.opendb(path))  # create it, then close so it's not locked
        opts = RocksDB.Options(; create_if_missing = false, error_if_exists = true)
        @test_throws RocksDB.RocksDBException RocksDB.opendb(path; options = opts)
    end

    @testset "backups" begin
        path = joinpath(dir, "db_backup_src")
        backup_dir = joinpath(dir, "db_backup_store")
        db = RocksDB.opendb(path)
        put!(db, "a", "1")
        be = RocksDB.BackupEngine(backup_dir)
        create_backup!(be, db)
        put!(db, "b", "2")
        create_backup!(be, db)
        close(db)

        infos = backup_info(be)
        @test length(infos) == 2
        @test infos[1].backup_id == 1
        @test infos[2].backup_id == 2
        @test all(i -> i.num_files > 0, infos)

        verify_backup(be, 1)  # does not throw
        @test_throws RocksDB.RocksDBException verify_backup(be, 99)

        restored1 = joinpath(dir, "db_backup_restored1")
        restore_backup!(be, 1, restored1)
        RocksDB.opendb(restored1; create_if_missing = false) do rdb
            @test String(get(rdb, "a")) == "1"
            @test get(rdb, "b") === nothing  # backup 1 predates "b"
        end

        purge_old_backups!(be, 1)
        @test length(backup_info(be)) == 1

        restored_latest = joinpath(dir, "db_backup_restored_latest")
        restore_latest_backup!(be, restored_latest)
        RocksDB.opendb(restored_latest; create_if_missing = false) do rdb
            @test String(get(rdb, "a")) == "1"
            @test String(get(rdb, "b")) == "2"
        end

        close(be)
        @test !isopen(be)
        close(be)  # double close is a no-op
    end

    @testset "BackupEngine do-block" begin
        path = joinpath(dir, "db_backup_src_do")
        backup_dir = joinpath(dir, "db_backup_store_do")
        db = RocksDB.opendb(path)
        put!(db, "a", "1")

        captured = nothing
        RocksDB.BackupEngine(backup_dir) do be
            captured = be
            create_backup!(be, db)
            @test length(backup_info(be)) == 1
        end
        @test captured.ptr == C_NULL  # closed automatically
        close(db)
    end

    @testset "TTL" begin
        # Expiry is only enforced during compaction (see opendb's docstring) --
        # compact! forces it deterministically instead of waiting on a
        # background compaction that may never run in a short-lived test.
        path = joinpath(dir, "db_ttl")
        db = RocksDB.opendb(path; ttl = 1)
        put!(db, "a", "1")
        @test String(get(db, "a")) == "1"  # readable immediately, ttl or not
        sleep(3)  # generous margin past ttl=1 -- the filter keys off whole seconds elapsed
        compact!(db)
        @test get(db, "a") === nothing     # expired and swept by compaction
        close(db)

        path_cf = joinpath(dir, "db_ttl_cf")
        db_cf = RocksDB.opendb(path_cf; column_families = ["default", "short", "long"],
                                create_missing_column_families = true, ttl = [100, 1, 100])
        put!(db_cf, "a", "1"; cf = "default")
        put!(db_cf, "b", "2"; cf = "short")
        put!(db_cf, "c", "3"; cf = "long")
        sleep(3)
        compact!(db_cf; cf = "default")
        compact!(db_cf; cf = "short")
        compact!(db_cf; cf = "long")
        @test String(get(db_cf, "a"; cf = "default")) == "1"
        @test get(db_cf, "b"; cf = "short") === nothing  # expired (ttl=1)
        @test String(get(db_cf, "c"; cf = "long")) == "3"
        close(db_cf)

        @test_throws ArgumentError RocksDB.opendb(joinpath(dir, "db_ttl_ro"); read_only = true, ttl = 1)
        @test_throws ArgumentError RocksDB.opendb(joinpath(dir, "db_ttl_vec_no_cf"); ttl = [1, 2])
        @test_throws ArgumentError RocksDB.opendb(joinpath(dir, "db_ttl_vec_mismatch");
                                                   column_families = ["default", "other"],
                                                   create_missing_column_families = true, ttl = [1, 2, 3])
    end

    @testset "compact!" begin
        path = joinpath(dir, "db_compact")
        db = RocksDB.opendb(path)
        for i in 1:20
            put!(db, "k$(lpad(i, 3, '0'))", "v$i")
        end
        compact!(db)  # whole range, plain path
        @test String(get(db, "k010")) == "v10"

        compact!(db; from = "k005", to = "k010")  # range-bounded
        @test String(get(db, "k005")) == "v5"
        @test String(get(db, "k015")) == "v15"

        cf = create_column_family(db, "other")
        put!(db, "x", "1"; cf = cf)
        compact!(db; cf = "other")  # column-family-scoped
        @test String(get(db, "x"; cf = cf)) == "1"

        compact!(db; change_level = true)  # exercises the CompactOptions/_opt path
        @test String(get(db, "k001")) == "v1"

        close(db)
    end
end
