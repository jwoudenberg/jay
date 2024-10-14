platform ""
    requires {} { main : {} -> Task {} [] }
    exposes [Site, Html]
    packages {}
    provides [mainForHost]

mainForHost : Task {} []
mainForHost = main {}
