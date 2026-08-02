using RocksDB
using Documenter

DocMeta.setdocmeta!(RocksDB, :DocTestSetup, :(using RocksDB); recursive=true)

makedocs(;
    modules=[RocksDB],
    authors="Eric S. Tellez <donsadit@gmail.com>",
    sitename="RocksDB.jl",
    format=Documenter.HTML(;
        canonical="https://sadit.github.io/RocksDB.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/sadit/RocksDB.jl",
    devbranch="main",
)
