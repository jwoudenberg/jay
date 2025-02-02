{
    title: "Syntax Highlighting",
    order: 2,
}

Jay has support for syntax highlighting of the following languages:

- Elm
- Haskell
- JSON
- Nix
- Roc
- Ruby
- Rust
- Zig

If the language you want to highlight is not included, let us know by creating an issue on the Jay repo!

Jay highlights fenced code blocks in markdown source files.

````markdown
Here's some sample code:

```roc
expect 1 + 1 == 2
```
````

## Quickest Path to Color

The quickest way to get started is to copy the `CSS` below in a stylesheet included in your pages.
You can then adjust the 16 CSS variables to your taste, or set them to one of the themes in the [base16][]
specification.

[base16]: https://github.com/chriskempson/base16

```css
pre > code {
  /* Based on Dracula Theme: https://github.com/dracula/dracula-theme */
  --hl-base00: #282A36;
  --hl-base01: #44475A;
  --hl-base02: #44475A;
  --hl-base03: #6272A4;
  --hl-base04: #F8F8F2;
  --hl-base05: #F8F8F2;
  --hl-base06: #F8F8F2;
  --hl-base07: #F8F8F2;
  --hl-base08: #F8F8F2;
  --hl-base09: #BD93F9;
  --hl-base0A: #8BE9FD;
  --hl-base0B: #F1FA8C;
  --hl-base0C: #FF5555;
  --hl-base0D: #50FA7B;
  --hl-base0E: #FF79C6;
  --hl-base0F: #FF79C6;

  display: block;
  background: var(--hl-base00);
  color: var(--hl-base05);

  & .hl-attribute {
    font-style: italic;
  }
  & .hl-comment {
    color: var(--hl-base03);
    font-style: italic;
  }
  & .hl-constant {
    color: var(--hl-base09);
  }
  & .hl-constant.builtin {
    color: var(--hl-base09);
    font-weight: bold;
  }
  & .hl-constructor {
  }
  & .hl-embedded {
  }
  & .hl-function {
    color: var(--hl-base0D);
  }
  & .hl-function.builtin {
    color: var(--hl-base0D);
    font-weight: bold;
  }
  & .hl-keyword {
    color: var(--hl-base0E);
  }
  & .hl-module {
  }
  & .hl-number {
    color: var(--hl-base09);
    font-weight: bold;
  }
  & .hl-operator {
    color: var(--hl-base0E);
    font-weight: bold;
  }
  & .hl-property {
  }
  & .hl-property.hl-builtin {
    font-weight: bold;
  }
  & .hl-punctuation {
  }
  & .hl-punctuation.hl-bracket {
    color: var(--hl-base03);
  }
  & .hl-punctuation.hl-delimiter {
    color: var(--hl-base03);
  }
  & .hl-punctuation.hl-special {
  }
  & .hl-string {
    color: var(--hl-base0B);
  }
  & .hl-string.hl-special {
    color: var(--hl-base0C);
  }
  & .hl-tag {
  }
  & .hl-type {
    color: var(--hl-base0A);
  }
  & .hl-type.hl-builtin {
    color: var(--hl-base0A);
    font-weight: bold;
  }
  & .hl-variable {
    color: var(--hl-base08);
  }
  & .hl-variable.hl-builtin {
    color: var(--hl-base08);
    font-weight: bold;
  }
  & .hl-variable.hl-parameter {
    color: var(--hl-base08);
    text-decoration: underline;
  }
}
```
