# graphql-js fixtures

`graphql-js.json` holds what [graphql-js](https://github.com/graphql/graphql-js),
the reference implementation that Apollo also builds on, does with the inputs of its
own test suite. The `graphql` module's tests check that it does the same:

| Key | Each case | What the tests compare |
|-----|-----------|------------------------|
| `lex` | a source, the tokens read from it, and the error that stopped the lexer | token kinds, values and positions; error messages and locations |
| `parse` | a document, and its printed form or the syntax error | `print(parse(source))`, or the error |
| `schema` | SDL, and the schema printed back or the error | `print_schema(build_schema(sdl))`, or the error |
| `validate` | one validation rule, a schema, a document, and the errors | the errors that rule reports |
| `sdl` | one SDL validation rule, an optional schema to extend, SDL, and the errors | the errors that rule reports |

`introspection.json` holds graphql-js's answer to the full introspection query
(`graphql.introspection_query`) for two schemas: graphql-js's validation test
schema, and one with every kind of type, deprecations, defaults, `@oneOf` and
`@specifiedBy`. `execute_test.v` checks the executor answers the same.

Recorded from graphql-js 16.x (`16.x.x` branch, commit `c767858`, 2026-06-16), the
version that implements the October 2021 spec.

## Other scripts

- `introspection.js` writes `introspection.json`; run it like `record.js`, inside
  the graphql-js checkout: `node <vgraph>/graphql/testdata/introspection.js > introspection.json`.
- `introspect_schema.js <schema.graphql> <out.json>` writes graphql-js's answer to
  the same query for one schema. `examples/service/testdata/introspection.json`
  comes from it; the service's test checks the running app answers the same.
- `check_schema.js` checks that graphql-js builds, validates and prints a schema
  exactly as vgraph wrote it. CI runs it on the generated `schema.graphql` files,
  with graphql-js from npm.

## Regenerating

`record.js` wraps graphql-js's `Lexer`, `parse`, `buildSchema`, `validate` and
`validateSDL` while its tests run, without changing their results:

```sh
git clone --depth 1 --branch 16.x.x https://github.com/graphql/graphql-js.git
cd graphql-js
npm install --ignore-scripts
RECORD_OUT=$PWD/graphql-js.json npx mocha --require <vgraph>/graphql/testdata/record.js \
  'src/language/__tests__/*-test.ts' 'src/validation/__tests__/*-test.ts' \
  'src/utilities/__tests__/buildASTSchema-test.ts' \
  'src/utilities/__tests__/printSchema-test.ts' \
  'src/utilities/__tests__/extendSchema-test.ts'
```

All of graphql-js's tests in those files must still pass.
