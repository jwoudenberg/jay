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
build.roc
```

Jay will turn those markdown files into HTML and produce a site with the following paths:

```
/index.html
/blog.html
/posts/a-great-day.html
/static/image.jpg
/static/style.css
```

You define the markdown conversion and any other transformations in build.roc.

## Getting started

In a directory with some source files, create a file `build.roc` with the following contents:

```roc
#!/usr/bin/env roc
app [main] { pf: platform "github.com/jwoudenberg/roc-static-site" }

import pf.Pages

main = Pages.bootstrap
```

The shebang on the first line makes it a script. Run it by typing `./build.roc`. This will:

- Replace `build.roc` with a draft site generation script that you can customize.
- Build an initial version of the site and serve it on a local port.
- Rebuild the site if you make changes to build.roc or source files.

## Custom 404 page

If you generate a `/404.html` path then it will be served by the preview file server when it receives a request for a path it doesn't know.

Note that you might need to configure the host for your production static site for it to serve your custom 404 page in the same manner.
