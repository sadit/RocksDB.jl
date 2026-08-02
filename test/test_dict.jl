@testset "RocksDBDict (tier 3)" begin
    dir = mktempdir()

    @testset "basic Dict protocol, byte/string passthrough" begin
        path = joinpath(dir, "dict1")
        d = RocksDB.RocksDBDict{String,String}(path)
        try
            d["a"] = "1"
            d["b"] = "2"
            @test d["a"] == "1"
            @test get(d, "missing", "default") == "default"
            @test get(() -> "computed", d, "missing2") == "computed"
            @test haskey(d, "b")
            @test !haskey(d, "nope")
            delete!(d, "a")
            @test !haskey(d, "a")
            @test_throws KeyError d["a"]
        finally
            close(d)
        end
    end

    @testset "iteration in sorted key order" begin
        path = joinpath(dir, "dict2")
        d = RocksDB.RocksDBDict{String,String}(path)
        try
            for k in ("banana", "apple", "cherry")
                d[k] = uppercase(k)
            end
            @test collect(keys(d)) == ["apple", "banana", "cherry"]
            @test d["apple"] == "APPLE"
        finally
            close(d)
        end
    end

    @testset "collect() right after a few writes (length() is only an estimate)" begin
        # Regression test: `length` is RocksDB's approximate key count, which
        # can undercount right after small writes -- `collect` must not rely
        # on it for pre-allocation (that requires IteratorSize != HasLength).
        path = joinpath(dir, "dict2b")
        d = RocksDB.RocksDBDict{String,String}(path)
        try
            d["a"] = "1"
            d["b"] = "2"
            @test length(collect(d)) == 2
            @test Set(collect(d)) == Set(["a" => "1", "b" => "2"])
        finally
            close(d)
        end
    end

    @testset "Any,Any falls back to Serialization" begin
        path = joinpath(dir, "dict3")
        d = RocksDB.RocksDBDict(path)
        try
            d[1] = [1, 2, 3]
            d[:sym] = (a = 1, b = "two")
            @test d[1] == [1, 2, 3]
            @test d[:sym] == (a = 1, b = "two")
        finally
            close(d)
        end
    end

    @testset "batch commits atomically" begin
        path = joinpath(dir, "dict4")
        d = RocksDB.RocksDBDict{String,String}(path)
        try
            RocksDB.batch(d) do b
                b["x"] = "1"
                b["y"] = "2"
            end
            @test d["x"] == "1"
            @test d["y"] == "2"

            @test_throws ErrorException RocksDB.batch(d) do b
                b["z"] = "3"
                error("boom")
            end
            @test !haskey(d, "z")
        finally
            close(d)
        end
    end

    @testset "column_family keyword" begin
        path = joinpath(dir, "dict5")
        db = RocksDB.opendb(path)
        create_column_family(db, "extra")
        close(db)

        d = RocksDB.RocksDBDict{String,String}(path; column_family = "extra",
                                                 column_families = ["default", "extra"])
        try
            d["k"] = "v"
            @test d["k"] == "v"
        finally
            close(d)
        end
    end

    @testset "ColumnFamilies two-level container" begin
        path = joinpath(dir, "dict6")
        store = RocksDB.ColumnFamilies{String,String}(path; column_families = ["default", "users", "sessions"])
        try
            @test length(store) == 3
            @test haskey(store, "users")
            @test haskey(store, :sessions)
            @test !haskey(store, "nope")

            store["users"]["alice"] = "admin"
            store[:sessions]["tok-1"] = "active"
            store["default"]["top"] = "value"

            @test store["users"]["alice"] == "admin"
            @test store["sessions"]["tok-1"] == "active"
            @test store["default"]["top"] == "value"
            # column families are genuinely separate keyspaces
            @test !haskey(store["sessions"], "alice")

            new_dict = create_column_family(store, "logs")
            new_dict["l1"] = "started"
            @test haskey(store, "logs")
            @test store["logs"]["l1"] == "started"
            @test length(store) == 4

            names = Set(keys(store))
            @test names == Set(["default", "users", "sessions", "logs"])
        finally
            close(store)
        end
    end
end
