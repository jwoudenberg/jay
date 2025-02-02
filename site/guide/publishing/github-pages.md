{
    title: "GitHub Pages",
    order: 1,
}

If you host the source code of your site on Github, you can use [Github Actions][1] to automatically deploy the latest version of a branch to [Github Pages][2].

To do so, add the following file to your project repo.

```yaml
# .github/workflows/publish.yaml

name: Publish a site

on:
  # Run when the `main` branch is changed
  push:
    branches:
      - main


jobs:
  publish:
    name: Bundle and release platform
    runs-on: [ubuntu-24.04]
    permissions:
      contents: write # Used to upload the bundled library
    steps:
      - uses: actions/checkout@v3
      - name: Install Roc
        uses: hasnep/setup-roc@main
        with:
          roc-version: nightly
      - name: Build Site
        run: ./build.roc --linker=legacy prod ./
      - name: Upload site
        id: deployment
        uses: actions/upload-pages-artifact@v3
        with:
          path: jay-output

  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-24.04
    needs: publish
    permissions:
      pages: write
      id-token: write
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

[1]: https://github.com/features/actions
[2]: https://pages.github.com/
