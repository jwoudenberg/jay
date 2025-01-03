{
    title: "Layouts",
    order: 2,
}

Jay generated a layout for us that will be used for our markdown pages.

```roc
# build.roc

layout = \{ content } ->
    Html.html {} [
        Html.head {} [],
        Html.body {} [content],
    ]
```

For starters, let's link our stylesheet by adding it to the `<head/>` element.
While we're at it we'll also add some other common `head` elements, and a title to be shown on all pages.

```roc
# build.roc

layout = \{ content, meta } ->
    Html.html {} [
        Html.head {} [
            Html.meta { charset: "utf-8" } [],
            Html.meta { name: "viewport", content: "width=device-width, initial-scale=1.0" } [],
            Html.link { rel: "stylesheet", href: "/assets/style.css" } [],
            Html.title {} [Html.text "My Blog - $(meta.title)"],
        ],
        Html.body {} [
            Html.h1 {} [Html.text "My Blog!"],
            Html.h2 {} [Html.text meta.title],
            content,
        ],
    ]
```

The `meta` attribute passed to our `layout` function contains our markdown frontmatter.
In this case we're expecting it to have a `title` field of type `Str`, so all markdown pages making use of this layout need to define at least that attribute in their frontmatter.
See the previous page of this guide to learn more about markdown frontmatters.

Let's add some styles to our stylesheet:

```css
/* assets/style.css */

body {
    color: red;
}
```

If you refresh your browser you should see that the text on the home page is now red!

You can look at your posts too.
If you have a file `posts/my-first-post.md`, it is served under `localhost:8080/posts/my-first-post`.
It'd be more convenient to have a list of posts linked from the home page though, so let's add that next.
