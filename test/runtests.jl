using RocksDB
using Test

@testset "RocksDB.jl" begin
    include("test_lowlevel.jl")
    include("test_midlevel.jl")
    include("test_dict.jl")
end
