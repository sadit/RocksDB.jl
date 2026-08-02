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

    @testset "RocksDBDict length() is column-family-scoped" begin
        # Regression test: length(d::RocksDBDict) used to always report the
        # *default* column family's estimate, even for a dict scoped to a
        # different one (found while writing the mixing-tiers tutorial).
        path = joinpath(dir, "dict6b")
        store = RocksDB.ColumnFamilies{String,String}(path; column_families = ["default", "users"])
        try
            store["default"]["a"] = "1"
            store["users"]["b"] = "2"
            store["users"]["c"] = "3"
            @test length(store["default"]) == 1
            @test length(store["users"]) == 2
        finally
            close(store)
        end
    end

    @testset "RocksDBSnapshotView" begin
        @testset "point-in-time consistency: indexing" begin
            path = joinpath(dir, "dict7")
            d = RocksDB.RocksDBDict{String,String}(path)
            try
                d["k1"] = "before"
                view = RocksDB.snapshot(d)
                try
                    d["k1"] = "after"
                    d["k2"] = "added after snapshot"

                    @test view["k1"] == "before"
                    @test !haskey(view, "k2")
                    @test get(view, "k2", "default") == "default"
                    @test_throws KeyError view["k2"]

                    # the live dict sees everything, unaffected by the view
                    @test d["k1"] == "after"
                    @test d["k2"] == "added after snapshot"
                finally
                    close(view)
                end
            finally
                close(d)
            end
        end

        @testset "point-in-time consistency: iteration" begin
            path = joinpath(dir, "dict8")
            d = RocksDB.RocksDBDict{String,String}(path)
            try
                d["a"] = "1"
                d["b"] = "2"
                view = RocksDB.snapshot(d)
                try
                    d["c"] = "3"
                    delete!(d, "a")

                    @test Set(collect(view)) == Set(["a" => "1", "b" => "2"])
                    @test Set(collect(d)) == Set(["b" => "2", "c" => "3"])
                finally
                    close(view)
                end
            finally
                close(d)
            end
        end

        @testset "writes are rejected" begin
            path = joinpath(dir, "dict9")
            d = RocksDB.RocksDBDict{String,String}(path)
            try
                d["k"] = "v"
                view = RocksDB.snapshot(d)
                try
                    @test_throws ErrorException view["k"] = "nope"
                    @test_throws ErrorException delete!(view, "k")
                    @test_throws ErrorException empty!(view)
                    @test view["k"] == "v"  # untouched
                finally
                    close(view)
                end
            finally
                close(d)
            end
        end

        @testset "close(view) does not close the shared db" begin
            path = joinpath(dir, "dict10")
            d = RocksDB.RocksDBDict{String,String}(path)
            d["k"] = "v"
            view = RocksDB.snapshot(d)
            close(view)
            @test !isopen(view)
            @test isopen(d)
            @test d["k"] == "v"  # d still fully usable
            d["k2"] = "v2"
            @test d["k2"] == "v2"
            close(d)
        end

        @testset "do-block form auto-closes" begin
            path = joinpath(dir, "dict11")
            d = RocksDB.RocksDBDict{String,String}(path)
            try
                d["k"] = "v"
                captured = nothing
                RocksDB.snapshot(d) do view
                    captured = view
                    @test view["k"] == "v"
                end
                @test !isopen(captured)

                # released even when the block throws
                captured2 = nothing
                @test_throws ErrorException RocksDB.snapshot(d) do view
                    captured2 = view
                    error("boom")
                end
                @test !isopen(captured2)
            finally
                close(d)
            end
        end

        @testset "snapshot of a ColumnFamilies entry" begin
            path = joinpath(dir, "dict12")
            store = RocksDB.ColumnFamilies{String,String}(path; column_families = ["default", "users"])
            try
                store["users"]["alice"] = "before"
                view = RocksDB.snapshot(store["users"])
                try
                    store["users"]["alice"] = "after"
                    store["users"]["bob"] = "new"
                    @test view["alice"] == "before"
                    @test !haskey(view, "bob")
                    # other column families are unaffected/inaccessible via this view
                    @test !haskey(view, "top") # never existed anywhere
                finally
                    close(view)
                end
            finally
                close(store)
            end
        end
    end
end
