# Jay

<div class="description">
A build system for your blog, guide, cookbook, or any static site.
</div>

- Markdown support, including syntax highlighting using tree-sitter.
- Write your own HTML layouts and widgets in Roc, a language inspired by Elm.
- Development preview with code watching and automatic rebuilds.

To get a taste, the configuration below sets up a simple blog.

```roc
#!/usr/bin/env roc
app [main] { pf: platform "https://github.com/jwoudenberg/jay/releases/download/0.4.0/jCnKKg_Vu-ho7TbfZIF5CAJIFTl3xCOhMSUO4eTH0JM.tar.br" }

import pf.Pages
import pf.Html

main = Pages.collect [
    Pages.ignore ["README.md"],
    Pages.files ["assets/*"],
    Pages.files ["index.md", "posts/*.md"]
        |> Pages.from_markdown
        |> Pages.wrap_html layout,
]

layout = \{ content, meta } ->
    Html.html {} [
        Html.head {} [
            Html.link {
                rel: "stylesheet",
                href: "/assets/style.css",
            } [],
        ],
        Html.body {} [
            Html.h1 {} [Html.text meta.title],
            content,
        ],
    ]
```
