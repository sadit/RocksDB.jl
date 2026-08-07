using RocksDB
using Documenter

DocMeta.setdocmeta!(RocksDB, :DocTestSetup, :(using RocksDB); recursive=true)

makedocs(;
    modules=[RocksDB],
    checkdocs=:all,
    checkdocs_ignored_modules=[RocksDB.LibRocksDB],
    authors="Eric S. Tellez <donsadit@gmail.com>",
    sitename="RocksDB.jl",
    format=Documenter.HTML(;
        canonical="https://sadit.github.io/RocksDB.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Tutorials" => [
            "tutorials/getting_started.md",
            "tutorials/compression.md",
            "tutorials/iteration.md",
            "tutorials/batches.md",
            "tutorials/column_families.md",
            "tutorials/ttl.md",
            "tutorials/compaction.md",
            "tutorials/snapshots.md",
            "tutorials/backups.md",
            "tutorials/tier1_escape_hatch.md",
            "tutorials/mixing_tiers.md",
        ],
        "API Reference" => [
            "Tier 2" => "reference/tier2.md",
            "Tier 3" => "reference/tier3.md",
        ],
    ],
)

deploydocs(;
    repo="github.com/sadit/RocksDB.jl",
    devbranch="main",
)
