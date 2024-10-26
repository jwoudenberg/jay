platform "jay"
    requires {} { main : List (Pages.Pages a) }
    exposes [Pages, Html]
    packages {}
    imports [PagesInternal, Pages]
    provides [mainForHost]

mainForHost : {} -> List PagesInternal.PagesInternal
mainForHost = \_ -> List.map main PagesInternal.unwrap
