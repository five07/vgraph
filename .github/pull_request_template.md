<!-- Thanks! Pull requests go to `develop`; `main` gets releases. -->

## What and why

<!-- What it changes, and the issue it fixes, if any: "Fixes #123". -->

## Checklist

- [ ] Tests: new behaviour has a test, and `v test .` passes; for a change to
      SQL or the drivers, the PostgreSQL tests pass too
      (`v -d vgraph_pg test pg_test.v examples/relations/pg_test.v examples/pagination/pg_test.v`).
- [ ] Generated code: after a change to the generator or a model, `vgraph gen`
      was run on each example and on `docs/snippets`, and the output is
      committed.
- [ ] Docs: the guides and README say what changed; their code is in
      `docs/snippets` (`UPDATE_SNIPPETS=1 v test docs/snippets/docs_test.v`).
- [ ] `v fmt -verify .` and `v vet` pass, and every new `pub` item has a doc
      comment.
- [ ] A workaround for a V bug has a program in `regressions/`.
