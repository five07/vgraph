'use strict';

// Checks that graphql-js, which Apollo's tools build on, reads each schema
// given: it must build, pass graphql-js's own schema validation, and print back
// exactly as written (after its leading comment), so vgraph prints schemas as
// graphql-js does. CI runs it on the schemas `vgraph gen` writes.
//
//   NODE_PATH=<dir with graphql installed> node check_schema.js a.graphql ...

const fs = require('fs');
const { buildSchema, validateSchema, printSchema } = require('graphql');

let failed = false;
for (const file of process.argv.slice(2)) {
  try {
    const text = fs.readFileSync(file, 'utf8');
    const schema = buildSchema(text);
    const errors = validateSchema(schema);
    if (errors.length > 0) {
      throw new Error(errors.map((e) => e.message).join('\n'));
    }
    const body = text.replace(/^(#.*\n)+\n/, '');
    if (printSchema(schema) + '\n' !== body) {
      throw new Error('graphql-js prints this schema differently');
    }
    console.log(`${file}: ok`);
  } catch (error) {
    failed = true;
    console.error(`${file}: ${error.message}`);
  }
}
process.exit(failed ? 1 : 0);
