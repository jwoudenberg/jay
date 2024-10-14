platform ""
    requires {} { main : {} -> Task {} [] }
    exposes [Site, Html]
    packages {}
    imports []
    provides [mainForHost]

mainForHost : Task {} []
mainForHost = main {}
