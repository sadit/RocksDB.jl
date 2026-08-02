using Clang.Generators

const GEN_DIR = @__DIR__
const HEADER_DIR = joinpath(GEN_DIR, "rocksdb_headers")
const OUTPUT_FILE = joinpath(GEN_DIR, "..", "src", "lib", "LibRocksDB.jl")

options = load_options(joinpath(GEN_DIR, "generator.toml"))

args = get_default_args()
push!(args, "-I$HEADER_DIR")

headers = [joinpath(HEADER_DIR, "rocksdb", "c.h")]

ctx = create_context(headers, args, options)
build!(ctx)

mkpath(dirname(OUTPUT_FILE))
println("Generated: ", OUTPUT_FILE)
