platform "jay"
    requires {} { main : Task {} * }
    exposes [Site, Html]
    packages {}
    imports [Helpers]
    provides [mainForHost]

mainForHost : Task {} I32 as Fx
mainForHost =
    main!
    run!

run : Task {} I32
run =
    pages = Helpers.storedPages! {}
    if (pages == [Files ["index.md"], FilesIn "/posts"]) then
        Task.ok {}
    else
        Task.err 5
