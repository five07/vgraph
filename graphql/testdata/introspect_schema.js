'use strict';

// Writes graphql-js's answer to the full introspection query (the query of
// introspection.json, which is `graphql.introspection_query`) for a schema, as
// a server's test fixture. Run it inside the graphql-js checkout that
// recorded the other fixtures (see README.md):
//   node <this file> <schema.graphql> <out.json>

const fs = require('fs');
const path = require('path');

require(path.join(process.cwd(), 'resources/ts-register.js'));
const src = path.join(process.cwd(), 'src');
const { buildSchema } = require(path.join(src, 'utilities/buildASTSchema'));
const { graphqlSync } = require(path.join(src, 'graphql'));

const [schemaFile, outFile] = process.argv.slice(2);
const query = JSON.parse(fs.readFileSync(path.join(__dirname, 'introspection.json'), 'utf8'))[0].query;
const result = graphqlSync({ schema: buildSchema(fs.readFileSync(schemaFile, 'utf8')), source: query });
if (result.errors) {
  throw new Error(result.errors.map((e) => e.message).join('\n'));
}
fs.writeFileSync(outFile, JSON.stringify(result) + '\n');
