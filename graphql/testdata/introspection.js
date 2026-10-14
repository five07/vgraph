'use strict';

// Records graphql-js's answer to the full introspection query for a few
// schemas, as fixtures for vgraph's `graphql` module. See README.md.
//   node <this file> > introspection.json   (run inside a graphql-js checkout)

const path = require('path');

require(path.join(process.cwd(), 'resources/ts-register.js'));
const src = path.join(process.cwd(), 'src');
const { buildSchema } = require(path.join(src, 'utilities/buildASTSchema'));
const { getIntrospectionQuery } = require(path.join(src, 'utilities/getIntrospectionQuery'));
const { graphqlSync } = require(path.join(src, 'graphql'));
const { testSchema } = require(path.join(src, 'validation/__tests__/harness'));
const { printSchema } = require(path.join(src, 'utilities/printSchema'));

const schemas = [
  printSchema(testSchema),
  `
  """A schema with a description."""
  schema { query: Root mutation: Change }

  "The root."
  type Root implements Node & Named {
    id: ID!
    name(upper: Boolean = false, prefix: String = "a \\"b\\"" @deprecated): String
    old: Int @deprecated
    older: Int @deprecated(reason: "Use \`new\`.")
    search(where: Filter = { ids: [1, 2], kind: ONE, nested: { flag: true } }, first: Int = 10, ratio: Float = 1.0): [Result!]
  }

  type Change { touch(id: ID!): Root }

  interface Node { id: ID! }
  interface Named implements Node { id: ID! name(upper: Boolean = false, prefix: String = "a \\"b\\"" @deprecated): String }
  union Result = Root | Other
  type Other { value: Time }

  """
  A block description
    with indentation.
  """
  enum Kind { ONE TWO @deprecated(reason: "no") }

  input Filter {
    ids: [ID!]
    kind: Kind = ONE
    nested: Nested
    legacy: String @deprecated
  }

  input Nested { flag: Boolean! = false }
  input Choice @oneOf { a: Int b: String }

  scalar Time @specifiedBy(url: "https://tools.ietf.org/html/rfc3339")

  directive @cost(weight: Int = 1) repeatable on FIELD_DEFINITION | OBJECT
  "Marks a field."
  directive @mark(choice: Choice) on FIELD
  `,
];

const query = getIntrospectionQuery({
  descriptions: true,
  specifiedByUrl: true,
  directiveIsRepeatable: true,
  schemaDescription: true,
  inputValueDeprecation: true,
  oneOf: true,
});

const out = schemas.map((sdl) => {
  const result = graphqlSync({ schema: buildSchema(sdl), source: query });
  if (result.errors) {
    throw new Error(result.errors.map((e) => e.message).join('\n'));
  }
  return { sdl, query, result: JSON.parse(JSON.stringify(result)) };
});
process.stdout.write(JSON.stringify(out, null, 1) + '\n');
