# Native task workspace UI audit

Left-align the document column with its panel label; compact `Stage · State`
line; meaningful document labels shared by the primary panel and the Documents
list; hide the empty `## Implementation` stub and title-repeating h1 in the
rendered view only; repository links for native `host/owner/name` values with
unknown Git facts omitted (diagnostics kept); diff page lists empty layers in
one line, uses secondary toggle buttons, lazy-loads the vendored diff2html
bundle (`preload: false`) and lets row colours show through highlight.js.
See commands/web.md "Document and diff presentation".
