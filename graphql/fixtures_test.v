module graphql

import json2
import os

// The fixtures recorded from graphql-js's own tests: see testdata/README.md.

fn fixtures() !map[string]json2.Any {
	text := os.read_file(os.join_path(@DIR, 'testdata', 'graphql-js.json'))!
	return json2.decode[json2.Any](text)!.as_map()
}

fn fixture_error(e json2.Any) (string, []Location) {
	m := e.as_map()
	locations := m['locations'] or { json2.Any([]json2.Any{}) }.as_array().map(Location{
		line:   it.as_array()[0].int()
		column: it.as_array()[1].int()
	})
	return m['message'] or { json2.Any('') }.str(), locations
}

// usable reports whether a fixture's source survived JSON decoding: sources with
// lone UTF-16 surrogates, which only JavaScript strings can hold, don't.
// describe returns an error's message and locations, as the tests compare them.
fn describe(e IError) string {
	if e is GraphQLError {
		// a local: interpolating `e.locations` directly generates invalid C
		// (regressions/smartcast_array_interpolation.vv)
		locations := e.locations
		return '${e.message} ${locations}'
	}
	return e.msg()
}

fn usable(source string) bool {
	mut i := 0
	for i < source.len {
		code, size := decode_rune(source, i)
		if code < 0 || code == 0xfffd {
			return false
		}
		i += size
	}
	return true
}

fn test_lexer_matches_graphql_js() {
	cases := fixtures()!['lex'] or { panic('no lex cases') }.as_array()
	mut checked := 0
	mut failures := []string{}
	for c in cases {
		m := c.as_map()
		source := m['source'] or { continue }.str()
		if !usable(source) {
			continue
		}
		mut lexer := Lexer.new(source)
		mut got := []string{}
		mut got_error := ''
		for _ in 0 .. m['tokens'] or { json2.Any([]json2.Any{}) }.as_array().len + (if 'error' in m {
			1
		} else {
			0
		}) {
			token := lexer.advance() or {
				got_error = describe(err)
				break
			}
			value := if token.kind.has_value() { token.value } else { '<none>' }
			got << '${token.kind.desc()} ${value} ${token.line}:${token.column}'
		}
		mut want := []string{}
		for t in m['tokens'] or { json2.Any([]json2.Any{}) }.as_array() {
			a := t.as_array()
			value := if a[1] is json2.Null { '<none>' } else { a[1].str() }
			want << '${a[0].str()} ${value} ${a[2].int()}:${a[3].int()}'
		}
		mut want_error := ''
		if e := m['error'] {
			message, locations := fixture_error(e)
			want_error = '${message} ${locations}'
		}
		checked++
		if got != want || got_error != want_error {
			failures << 'source ${source.str()}:\n  want ${want} ${want_error}\n  got  ${got} ${got_error}'
		}
	}
	assert failures.len == 0, '${failures.len} of ${checked} lexer cases differ:\n' +
		failures#[..20].join('\n')
	assert checked > 150
}

fn test_parser_and_printer_match_graphql_js() {
	cases := fixtures()!['parse'] or { panic('no parse cases') }.as_array()
	mut checked := 0
	mut failures := []string{}
	for c in cases {
		m := c.as_map()
		source := m['source'] or { continue }.str()
		if !usable(source) {
			continue
		}
		checked++
		if e := m['error'] {
			message, locations := fixture_error(e)
			if doc := parse(source) {
				failures << 'source ${source.str()}:\n  want error ${message}\n  got  ${print_document(doc).str()}'
			} else {
				got := describe(err)
				if got != '${message} ${locations}' {
					failures << 'source ${source.str()}:\n  want ${message} ${locations}\n  got  ${got}'
				}
			}
			continue
		}
		printed := m['printed'] or { continue }.str()
		doc := parse(source) or {
			failures << 'source ${source.str()}:\n  want ${printed.str()}\n  got error ${err.msg()}'
			continue
		}
		got := print_document(doc)
		if got != printed {
			failures << 'source ${source.str()}:\n  want ${printed.str()}\n  got  ${got.str()}'
			continue
		}
		// printing is stable: the printed text parses back to itself
		again := print_document(parse(got) or {
			failures << 'printed ${got.str()} does not parse: ${err.msg()}'
			continue
		})
		if again != got {
			failures << 'printed ${got.str()} prints back as ${again.str()}'
		}
	}
	assert failures.len == 0, '${failures.len} of ${checked} parse cases differ:\n' +
		failures#[..20].join('\n')
	assert checked > 600
}

fn test_build_and_print_schema_match_graphql_js() {
	cases := fixtures()!['schema'] or { panic('no schema cases') }.as_array()
	mut checked := 0
	mut failures := []string{}
	for c in cases {
		m := c.as_map()
		source := m['source'] or { continue }.str()
		if !usable(source) {
			continue
		}
		checked++
		if e := m['error'] {
			if schema := build_schema(source) {
				failures << 'source ${source.str()}:\n  want error ${e.str()}\n  got  ${print_schema(schema).str()}'
			} else {
				if err.msg() != e.str() {
					failures << 'source ${source.str()}:\n  want error ${e.str()}\n  got  ${err.msg()}'
				}
			}
			continue
		}
		printed := m['printed'] or { continue }.str()
		schema := build_schema(source) or {
			failures << 'source ${source.str()}:\n  want ${printed.str()}\n  got error ${err.msg()}'
			continue
		}
		got := print_schema(schema)
		if got != printed {
			failures << 'source ${source.str()}:\n  want ${printed.str()}\n  got  ${got.str()}'
		}
	}
	assert failures.len == 0, '${failures.len} of ${checked} schema cases differ:\n' +
		failures#[..10].join('\n')
	assert checked > 150
}

fn fixture_errors(a json2.Any) []string {
	return a.as_array().map(fn (e json2.Any) string {
		message, locations := fixture_error(e)
		return '${message} ${locations}'
	})
}

fn got_errors(errors []GraphQLError) []string {
	return errors.map(fn (e GraphQLError) string {
		locations := e.locations
		return '${e.message} ${locations}'
	})
}

fn test_validation_matches_graphql_js() {
	cases := fixtures()!['validate'] or { panic('no validate cases') }.as_array()
	mut schemas := map[string]Schema{}
	mut checked := 0
	mut failures := []string{}
	mut probe := ValidationContext{
		schema: &Schema{}
		doc:    &Document{}
	}
	for c in cases {
		m := c.as_map()
		rule := m['rule'] or { continue }.str()
		if new_rule(rule, mut probe) == none {
			continue
		}
		sdl := m['schema'] or { continue }.str()
		source := m['document'] or { continue }.str()
		if !usable(source) {
			continue
		}
		if sdl !in schemas {
			mut built := build_schema(sdl) or {
				failures << 'schema does not build: ${err.msg()}\n${sdl}'
				continue
			}
			// graphql-js's tests define these scalars in JavaScript: `Invalid`
			// throws, and `CustomScalar` returns undefined
			built.scalars['Invalid'] = Scalar{
				parse_literal: fn (node ValueNode, _ map[string]Value) !Value {
					return error('Invalid scalar is always invalid: ${print_value(node)}')
				}
			}
			built.scalars['CustomScalar'] = Scalar{
				parse_literal: fn (_ ValueNode, _ map[string]Value) !Value {
					return error('')
				}
			}
			schemas[sdl] = built
		}
		schema := schemas[sdl] or { continue }
		doc := parse(source) or {
			failures << '${rule}: does not parse: ${err.msg()}\n${source}'
			continue
		}
		checked++
		want := fixture_errors(m['errors'] or { continue })
		got := got_errors(validate(schema, doc, rules: [rule]))
		if got != want {
			failures << '${rule}: ${source.str()}\n  want ${want}\n  got  ${got}'
		}
	}
	assert failures.len == 0, '${failures.len} of ${checked} validation cases differ:\n' +
		failures#[..15].join('\n')
	assert checked > 400
}

fn test_sdl_validation_matches_graphql_js() {
	cases := fixtures()!['sdl'] or { panic('no sdl cases') }.as_array()
	mut checked := 0
	mut failures := []string{}
	for c in cases {
		m := c.as_map()
		rule := m['rule'] or { continue }.str()
		source := m['document'] or { continue }.str()
		if !usable(source) {
			continue
		}
		// directives on directive definitions are an experimental graphql-js
		// parse option, which this parser doesn't have
		if source.contains('extend directive') || source.contains(' @testDirective @') {
			continue
		}
		mut schema := ?Schema(none)
		if sdl := m['schema'] {
			if sdl !is json2.Null {
				schema = build_schema(sdl.str()) or {
					failures << 'schema does not build: ${err.msg()}'
					continue
				}
			}
		}
		doc := parse(source) or {
			failures << '${rule}: does not parse: ${err.msg()}\n${source}'
			continue
		}
		checked++
		existing := schema or { Schema{} }
		mut ctx := ValidationContext{
			schema:     &existing
			has_schema: schema != none
			doc:        &doc
			max_errors: max_int
		}
		want := fixture_errors(m['errors'] or { continue })
		got := got_errors(ctx.validate_sdl_rules([rule]))
		if got != want {
			failures << '${rule}: ${source.str()}\n  want ${want}\n  got  ${got}'
		}
	}
	assert failures.len == 0, '${failures.len} of ${checked} SDL validation cases differ:\n' +
		failures#[..15].join('\n')
	assert checked > 100
}
