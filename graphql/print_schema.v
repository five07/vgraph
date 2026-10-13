module graphql

// print_schema returns the schema as SDL, formatted as graphql-js's
// `printSchema` formats it: the schema definition when its root types aren't
// named Query, Mutation and Subscription, then the directives that aren't
// built in, then every type that isn't a specified scalar or an introspection
// type, in schema order.
pub fn print_schema(s &Schema) string {
	mut parts := []string{}
	if def := print_schema_root(s) {
		parts << def
	}
	for d in s.directives {
		if d.name !in specified_directives {
			parts << s.print_directive_def(d)
		}
	}
	for name in s.type_names {
		if name in specified_scalars || name in introspection_types {
			continue
		}
		parts << s.print_named_type(s.types[name] or { continue })
	}
	return parts.filter(it != '').join('\n\n')
}

fn print_schema_root(s &Schema) ?string {
	common := (s.query or { 'Query' }) == 'Query'
		&& (s.mutation or { 'Mutation' }) == 'Mutation'
		&& (s.subscription or { 'Subscription' }) == 'Subscription'
	if s.description == none && common {
		return none
	}
	mut ops := []string{}
	if q := s.query {
		ops << '  query: ${q}'
	}
	if m := s.mutation {
		ops << '  mutation: ${m}'
	}
	if sub := s.subscription {
		ops << '  subscription: ${sub}'
	}
	return print_type_description(s.description, '', true) + 'schema {\n${ops.join('\n')}\n}'
}

// print_named_type returns one type as SDL.
pub fn (s &Schema) print_named_type(t Type) string {
	desc := print_type_description(t.description, '', true)
	return match t.kind {
		.scalar {
			mut specified := ''
			if url := t.specified_by_url {
				specified = ' @specifiedBy(url: ${print_string(url)})'
			}
			desc + 'scalar ${t.name}' + specified
		}
		.object, .@interface {
			keyword := if t.kind == .object { 'type' } else { 'interface' }
			implements := if t.interfaces.len > 0 {
				' implements ' + t.interfaces.join(' & ')
			} else {
				''
			}
			desc + '${keyword} ${t.name}' + implements + s.print_fields(t.fields)
		}
		.@union {
			members := if t.possible_types.len > 0 {
				' = ' + t.possible_types.join(' | ')
			} else {
				''
			}
			desc + 'union ' + t.name + members
		}
		.@enum {
			mut values := []string{}
			for i, v in t.values {
				values << print_type_description(v.description, '  ', i == 0) + '  ' + v.name +
					print_deprecated(v.deprecation_reason)
			}
			desc + 'enum ${t.name}' + print_block(values)
		}
		.input_object {
			mut fields := []string{}
			for i, f in t.input_fields {
				fields << print_type_description(f.description, '  ', i == 0) + '  ' +
					s.print_input_value(f)
			}
			desc + 'input ${t.name}' + (if t.is_one_of { ' @oneOf' } else { '' }) +
				print_block(fields)
		}
	}
}

fn (s &Schema) print_fields(fields []FieldDef) string {
	mut out := []string{}
	for i, f in fields {
		out << print_type_description(f.description, '  ', i == 0) + '  ' + f.name +
			s.print_args(f.args, '  ') + ': ' + print_type(f.typ) +
			print_deprecated(f.deprecation_reason)
	}
	return print_block(out)
}

fn print_block(items []string) string {
	return if items.len > 0 { ' {\n' + items.join('\n') + '\n}' } else { '' }
}

fn (s &Schema) print_args(args []InputValueDef, indentation string) string {
	if args.len == 0 {
		return ''
	}
	if args.all(it.description == none) {
		return '(' + args.map(s.print_input_value(it)).join(', ') + ')'
	}
	mut lines := []string{}
	for i, a in args {
		lines << print_type_description(a.description, '  ' + indentation, i == 0) + '  ' +
			indentation + s.print_input_value(a)
	}
	return '(\n' + lines.join('\n') + '\n' + indentation + ')'
}

fn (s &Schema) print_input_value(v InputValueDef) string {
	mut out := v.name + ': ' + print_type(v.typ)
	if node := s.ast_from_value(v.default_value, v.typ) {
		out += ' = ${print_value(node)}'
	}
	return out + print_deprecated(v.deprecation_reason)
}

fn (s &Schema) print_directive_def(d DirectiveDef) string {
	return print_type_description(d.description, '', true) + 'directive @' + d.name +
		s.print_args(d.args, '') + print_deprecated(d.deprecation_reason) +
		(if d.repeatable { ' repeatable' } else { '' }) + ' on ' + d.locations.join(' | ')
}

fn print_deprecated(reason ?string) string {
	r := reason or { return '' }
	if r != default_deprecation_reason {
		return ' @deprecated(reason: ${print_string(r)})'
	}
	return ' @deprecated'
}

// print_type_description prints a description above a definition: as a block
// string where it can be one, indented, with a blank line before it unless it
// starts a block.
fn print_type_description(description ?string, indentation string, first_in_block bool) string {
	d := description or { return '' }
	printed := if is_printable_as_block_string(d) {
		print_block_string(d, false)
	} else {
		print_string(d)
	}
	prefix := if indentation != '' && !first_in_block { '\n' + indentation } else { indentation }
	return prefix + printed.replace('\n', '\n' + indentation) + '\n'
}

// is_printable_as_block_string reports whether `value` reads back the same when
// printed as a block string, as graphql-js decides it.
fn is_printable_as_block_string(value string) bool {
	if value == '' {
		return true
	}
	mut is_empty_line := true
	mut has_indent := false
	mut has_common_indent := true
	mut seen_non_empty_line := false
	for c in value {
		match c {
			0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0b, 0x0c, 0x0e, 0x0f {
				return false
			}
			`\r` {
				return false
			}
			`\n` {
				if is_empty_line && !seen_non_empty_line {
					return false
				}
				seen_non_empty_line = true
				is_empty_line = true
				has_indent = false
			}
			`\t`, ` ` {
				has_indent = has_indent || is_empty_line
			}
			else {
				has_common_indent = has_common_indent && has_indent
				is_empty_line = false
			}
		}
	}
	if is_empty_line {
		return false
	}
	if has_common_indent && seen_non_empty_line {
		return false
	}
	return true
}
