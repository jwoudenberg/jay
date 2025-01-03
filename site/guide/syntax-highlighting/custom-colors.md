{
    title: "Custom Colors",
    order: 1,
}

Jay uses [tree-sitter][] for syntax highlighting. Many programming language
communities have produced tree-sitter grammars for their language, and Jay
bundles a number of these. The grammars define what types of highlight
groups exist for a language and what they are named.

If a tree-sitter grammar marks a particular word in a code snippet as
highlight group `foo`, then Jay adds a `span` element around it:

    <pre><code data-hl-lang="some-lang">
        ... <span class="hl-foo">word</span> ...
    </code></pre>

Language grammars are free to define their own highlight groups, but
tree-sitter recommends they use a couple of common names where it makes
sense. The previous page contained CSS-selectors matching the classes on
`span` elements for those common highlight names. By adding styles to these
classes you should get some nice syntax highlighting going for a wide range of
languages.

You can customize your colorscheme further by adding styles for language-specific highlight groups.
This might require looking at the tree syntax grammar for a specific language.
The highlight groups will be defined in the `queries/highlights.scm` file of such a grammar.

You can also use different color schemes for different languages.
To do so, use the `data-hl-lang` attribute that Jay puts on the `<code/>` element in your `CSS` selectors.

[tree-sitter]: https://tree-sitter.github.io/tree-sitter/
