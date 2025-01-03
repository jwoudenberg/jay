{
    title: "Introduction",
    order: 0,
}

Jay processes all the files in a project directory to build a site.

For example, below on the left are the files of a simple blog.
On the right are the pages Jay will create for these files.

```
index.md           => /index.html
posts/
  a-great-day.md   => /posts/a-great-day.html
static/
  image.jpg        => /static/image.jpg
  style.css        => /static/style.css
README.md
build.roc
```

The `build.roc` file describes the processing Jay needs to perform for every
source file in the project. The following `build.roc` would produce the
example blog above:

```roc
#!/usr/bin/env roc
app [main] { pf: platform "github.com/jwoudenberg/roc-static-site" }

import pf.Pages

main = Pages.collect [
    Pages.files ["*.md", "posts/*.md"] |> Pages.from_markdown,
    Pages.files ["static/*"],
    Pages.ignore ["README.md"],
]
```

Output files always have the same relative path as the source files they
were created from. A markdown source file `posts/2024/trying-jay.md` will
always produce an output path `/posts/2024/trying-jay.html`. Jay offers no
way to override this.

Once you have a `build.roc` file you can run it as a script:

```sh
./build.roc --linker=legacy
```

This will start Jay in development mode. It will serve a preview of your
site and automatically rebuild it when you make changes to source files.
