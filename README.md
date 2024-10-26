# Jay - a static site generator for Roc

**IMPORTANT: this project is not nearly done yet! The README below is aspirational!**

Jay takes a directory of files and turns it into a website.
Let's say you have the following source files:

```
index.md
blog.md
posts/
  a-great-day.md
static/
  image.jpg
  style.css
main.roc
```

Jay will turn those markdown files into HTML and produce a site with the following paths:

```
/index.html
/blog.html
/posts/a-great-day.html
/static/image.jpg
/static/style.css
```

You define the markdown conversion and any other transformations in main.roc.

## Getting started

In a directory with some source files, create a file `main.roc` with the following contents:

```roc
#!/usr/bin/env roc
app [main] { pf: platform "github.com/jwoudenberg/roc-static-site" }

import Pages

main = Pages.bootstrap
```

The shebang on the first line makes it a script. Run it by typing `./main.roc`. This will:

- Replace `main.roc` with a draft site generation script that you can customize.
- Build an initial version of the site and serve it on a local port.
- Rebuild the site if you make changes to main.roc or source files.
