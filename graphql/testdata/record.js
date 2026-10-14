'use strict';

// Records what graphql-js does while its own test suite runs, as fixtures for
// vgraph's `graphql` module: every document parsed (printed back, or the syntax
// error), every schema built from SDL (printed back, or the error), and every
// validation (the rules, schema, document and errors). See README.md.
//
// Loaded by mocha after graphql-js's TypeScript hook:
//   RECORD_OUT=out.json npx mocha --require <this file> 'src/**/__tests__/*-test.ts'

const fs = require('fs');
const path = require('path');

require(path.join(process.cwd(), 'resources/ts-register.js'));
const src = path.join(process.cwd(), 'src');
const parser = require(path.join(src, 'language/parser'));
const printer = require(path.join(src, 'language/printer'));
const validation = require(path.join(src, 'validation/validate'));
const buildAST = require(path.join(src, 'utilities/buildASTSchema'));
const printSchemaModule = require(path.join(src, 'utilities/printSchema'));

const lexerModule = require(path.join(src, 'language/lexer'));

const cases = { lex: [], parse: [], schema: [], validate: [], sdl: [] };
const seen = new Set();

// wellFormed reports whether every string in `value` is valid Unicode. Strings
// with lone UTF-16 surrogates exist only in JavaScript, and can't be UTF-8, so
// those cases are left out.
function wellFormed(value) {
  if (typeof value === 'string') {
    return value.isWellFormed();
  }
  if (value && typeof value === 'object') {
    return Object.values(value).every(wellFormed);
  }
  return true;
}

function once(kind, value) {
  if (!wellFormed(value)) {
    return;
  }
  const key = kind + JSON.stringify(value);
  if (!seen.has(key)) {
    seen.add(key);
    cases[kind].push(value);
  }
}

function errorJSON(error) {
  return {
    message: error.message,
    locations: (error.locations || []).map((l) => [l.line, l.column]),
  };
}

function sourceOf(source) {
  return typeof source === 'string' ? source : source && source.body;
}

// Lexers made by graphql-js's lexer tests record each token they read, or the
// error that stopped them. The parser's own lexers are left alone.
const Lexer = lexerModule.Lexer;
lexerModule.Lexer = class extends Lexer {
  constructor(source) {
    super(source);
    if (new Error().stack.includes('lexer-test')) {
      this.record = { source: sourceOf(source), tokens: [] };
      cases.lex.push(this.record);
    }
  }

  advance() {
    if (!this.record || this.record.error) {
      return super.advance();
    }
    try {
      const token = super.advance();
      this.record.tokens.push([token.kind, token.value === undefined ? null : token.value, token.line, token.column]);
      return token;
    } catch (error) {
      this.record.error = errorJSON(error);
      throw error;
    }
  }
};

const { parse, print } = { parse: parser.parse, print: printer.print };
const { printSchema } = printSchemaModule;

parser.parse = function (source, options) {
  const text = sourceOf(source);
  const plain = options === undefined;
  try {
    const doc = parse(source, options);
    if (plain && typeof text === 'string') {
      once('parse', { source: text, printed: print(doc) });
    }
    return doc;
  } catch (error) {
    if (plain && typeof text === 'string' && error.locations) {
      once('parse', { source: text, error: errorJSON(error) });
    }
    throw error;
  }
};

const buildSchema = buildAST.buildSchema;
buildAST.buildSchema = function (source, options) {
  const text = sourceOf(source);
  try {
    const schema = buildSchema(source, options);
    if (options === undefined && typeof text === 'string') {
      once('schema', { source: text, printed: printSchema(schema) });
    }
    return schema;
  } catch (error) {
    if (options === undefined && typeof text === 'string') {
      once('schema', { source: text, error: error.message });
    }
    throw error;
  }
};

const validate = validation.validate;
validation.validate = function (schema, doc, rules, ...rest) {
  const errors = validate(schema, doc, rules, ...rest);
  if (rules && rules.length === 1 && rest.length === 0 && doc.loc) {
    let printed;
    try {
      printed = printSchema(schema);
    } catch (_) {
      return errors;
    }
    once('validate', {
      rule: rules[0].name,
      schema: printed,
      document: doc.loc.source.body,
      errors: errors.map(errorJSON),
    });
  }
  return errors;
};

const validateSDL = validation.validateSDL;
validation.validateSDL = function (doc, schema, rules) {
  const errors = validateSDL(doc, schema, rules);
  if (rules && rules.length === 1 && doc.loc) {
    once('sdl', {
      rule: rules[0].name,
      schema: schema ? printSchema(schema) : null,
      document: doc.loc.source.body,
      errors: errors.map(errorJSON),
    });
  }
  return errors;
};

process.on('exit', () => {
  cases.lex = cases.lex.filter(wellFormed);
  fs.writeFileSync(process.env.RECORD_OUT, JSON.stringify(cases, null, 1) + '\n');
});
