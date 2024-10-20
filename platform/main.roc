platform "jay"
    requires {} { main : Task {} * }
    exposes [Site, Html]
    packages {}
    imports []
    provides [mainForHost]

mainForHost : Task {} I32 as Fx
mainForHost = main
