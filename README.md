# Jay - a static site generator for Roc

Jay works on a directory that mirrors the site we'd like to build. Jay maps each source file to a site file at the same relative path, but can transform a file's contents or change its extension.

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

Given the right `main.roc` (more on that below), Jay will generate a site with these paths:

```
/index.html
/blog.html
/posts/a-great-day.html
/static/image.jpg
/static/style.css
```

## Getting started

In a directory with some source files, create a file `main.roc` with the following contents:

```roc
#!/usr/bin/env roc
app [main] { pf: platform "github.com/jwoudenberg/roc-static-site" }

import Site

main = Site.bootstrap
```

The shebang on the first line makes it a script. Run it by typing `./main.roc`. This will:

- Replace `main.roc` with a draft site generation script that you can customize.
- Build an initial version of the site and serve it on a local port.
- Rebuild the site if you make changes to main.roc or source files.
