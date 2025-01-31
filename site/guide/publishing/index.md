{
    title: "Publishing",
    order: 1,
}

Once we're ready to publish our site we can run a production build.

```sh
./build.roc --linker=legacy prod output/
```

This command will generate site files in the `output/jay-output` directory, then exit.

What happens next depends on where you want to deploy your site.
This section lists a couple of options.
If you deployed a site built with Jay somewhere else and would like to add a section to this guide describing how, your contribution is most welcome!
