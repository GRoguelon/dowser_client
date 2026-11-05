# The migration DSL, written without parentheses — in this project, and in
# applications with `import_deps: [:dowser_client]` in their .formatter.exs.
locals_without_parens = [
  create_index: 2,
  create_index: 3,
  drop_index: 1,
  drop_index: 2,
  alter_index: 2,
  alter_index: 3,
  add: 2,
  add: 3,
  modify: 2,
  modify: 3,
  rename: 2,
  remove: 1,
  remove: 2,
  set: 2,
  set: 3,
  unset: 1,
  unset: 2,
  script: 1,
  script: 2
]

# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
