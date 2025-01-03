{
    title: "Markdown",
    order: 1,
}

We saw how we can use `Pages.from_markdown` to include markdown content in out site.

```roc
main = Pages.collect [
    ...
    Pages.files ["posts/*.md", "*.md"]
    |> Pages.from_markdown,
    ...
]
```

The `HTML` generated by `Pages.from_markdown` includes elements like `<h1/>`, `<ul/>`, and `<img/>` for Markdown headers, lists, and images.
However, `Pages.from_markdown` does not generate a page "layout" around the markdown content, because it does not know what kind of layout you would like.
The next page in this guide talks more about adding a layout to pages.

Jay plans to but does not currently support "Github-Flavored Markdown", which includes things like footnotes, task lists, and tables.

## Frontmatter

You can optionally add a frontmatter to markdown pages, containing some metadata about the page.
Frontmatters in Jay are Roc records placed directly at the start of the markdown page, like this:

```markdown
{
    title: "Having Fun with Jay",
    published_at: "2025-01-04",
    tags: ["blogging", "fun"],
}

## Getting Started

Let me tell you about the blog I built with **Jay**!
```

You're free to what keys to put in this record and what their values are.
However, to avoid errors, make sure all the markdown pages matching the same pattern have the same frontmatter structure.

Jay won't do anything with this data itself, only make it available to your `build.roc` code.
We're going to make use of this in the next section of this guide.