{
    title: "Listing Posts",
    order: 3,
}

An important feature missing from our blog is a list of posts. Let's add that!

First, we'll mark the location where we want to render the list of posts using a made up HTML element.
For this example we'll use `<list-of-posts/>` and put it on our index page.

```markdown
<!-- index.md -->

# My Blog

A list of all my previous posts!

<list-of-posts/>
```

Next we'll change the pipeline for `index.md` to replace `<list-of-posts/>` with some other `HTML`.
For this we can use the `replace_html` function.
We pass it the `HTML` tag we'd like to replace, along with a function returning the replacement `HTML`.

```roc
main = Pages.collect [
    ...
    Pages.files ["posts/*.md", "*.md"]
    |> Pages.from_markdown
    |> Pages.wrap_html layout,
    |> Pages.replace_html "list-of-posts" list_of_posts!
]

list_of_posts! = \_ -> Html.text "coming soon!"
```

To avoid needing to manually write individual links to our blog posts we can use the `list!` function.
It takes a pattern matching some source files and returns information about those files.
Let's use it to create a list of links that will automatically update when we add a blog post.

```roc
list_of_posts! = \_ ->
    posts =
        Pages.list! "posts/*"
        |> List.sortWith \a, b -> Num.compare a.meta.order b.meta.order

    links = List.map posts \post ->
        Html.li {} [
            Html.a
                { href: post.path }
                [Html.text post.meta.title],
        ]

    Html.ul {} links
```

Notice that we sorted the posts based on a `order` property in the metadata.
For that to work we'd need to add such a property to the frontmatter of each blog post:

```
# posts/having-fun-with-jay.md

{
    title: "Having Fun with Jay",
    order: 2,
}
```

We now have a very basic blog.
We can improve our blog in many ways, some of which are discussed in other sections of this guide.
We'll conclude this blog example with a look at how we can publish the result of our work.
