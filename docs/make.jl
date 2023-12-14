using AFLplusplus
using Documenter

DocMeta.setdocmeta!(AFLplusplus, :DocTestSetup, :(using AFLplusplus); recursive=true)

makedocs(;
    modules=[AFLplusplus],
    authors="Eric P. Hanson",
    repo="https://github.com/ericphanson/AFLplusplus.jl/blob/{commit}{path}#{line}",
    sitename="AFLplusplus.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://ericphanson.github.io/AFLplusplus.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/ericphanson/AFLplusplus.jl",
    devbranch="main",
)
