{
    title: "Building a Blog",
    order: 1,
}

To get to know Jay we'll use it to build a simple blog.
If you want to follow along then [Install Roc][1] and create a directory for your blog.

The directory should contain:

- An `index.md` file that will serve as the blog's homepage.
- A `posts/` directory containing a couple of `.md` files representing posts.
- An `assets/` directory with a `style.css` file and maybe some images to include in posts.

Jay can work with any directory structure, but this part of the guide will assume the above files and directories.

Finally, add a `build.roc` file to the root of the directory with the following contents:

```roc
#!/usr/bin/env roc
app [main] { pf: platform "https://github.com/jwoudenberg/jay/releases/download/0.5.0/2hou6qBqBlDV6fmDLkjYVmyvxofsVyeO6hlf5VQMqgg.tar.br" }

import pf.Pages

main = Pages.bootstrap
```

The above file is a script. Run it!

```sh
chmod +x build.roc
./build.roc --linker=legacy
```

Jay will have started in development mode and launched a preview of your blog in your browser. You should see the contents of your `index.md` file in the browser, albeit without any styling.

Jay also replaced `build.roc` with a starter configuration that will improve in this part of the guide. Let's look at two bits of code it generated for us:

```roc
main = Pages.collect [
    Pages.ignore [],
    Pages.files ["assets/*.css"],
    Pages.files ["posts/*.md", "*.md"]
    |> Pages.from_markdown
    |> Pages.wrap_html layout,
]
```

Jay recognized we have an `assets` directory containing some files that should be included in the site without processing:

```roc
main = Pages.collect [
    ...
    Pages.files ["assets/*.css"],
    ...
]
```

Jay also found some `MarkDown` files that need to be turned into `HTML`:

```roc
main = Pages.collect [
    ...
    Pages.files ["posts/*.md", "*.md"]
    |> Pages.from_markdown
    |> Pages.wrap_html layout,
    ...
]
```

The `from_markdown` function doesn't automatically add `<html/>` and `<body/>` tags around content.
For adding a layout around the content we use `wrap_html`, which is passed a `layout` function:

```roc
layout = \{ content } ->
    Html.html {} [
        Html.head {} [],
        Html.body {} [content],
    ]
```

This function receives a `content` argument containing the HTML `from_markdown` generated for a page.
We return the full HTML for the page, placing the `content` somewhere inside.
This `layout` function is very basic and we're going to improve it, but let's first take a closer look at how Jay handles markdown content.

[1]: https://www.roc-lang.org/install
