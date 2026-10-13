module graphql

import strings

// The printer writes a document back out, formatted as graphql-js's `print`
// formats it, so `print(parse(s))` is the same text in both.

const max_line_length = 80

// print_document returns `doc` as GraphQL text: graphql-js's `print`.
pub fn print_document(doc Document) string {
	return doc.definitions.map(print_definition(it)).join('\n\n')
}

// print_definition returns one definition as GraphQL text.
pub fn print_definition(d Definition) string {
	return match d {
		OperationDefinition { print_operation(d) }
		FragmentDefinition { print_fragment_definition(d) }
		SchemaDefinition { print_schema_definition(d) }
		TypeDefinition { print_type_definition(d) }
		DirectiveDefinition { print_directive_definition(d) }
	}
}

// join joins the non-empty items of `items` with `sep`.
fn join(items []string, sep string) string {
	return items.filter(it != '').join(sep)
}

// wrap returns `start + s + end`, or '' when `s` is empty.
fn wrap(start string, s string, end string) string {
	return if s == '' { '' } else { start + s + end }
}

fn indent(s string) string {
	return wrap('  ', s.replace('\n', '\n  '), '')
}

fn block(items []string) string {
	return wrap('{\n', indent(join(items, '\n')), '\n}')
}

fn has_multiline_items(items []string) bool {
	return items.any(it.contains('\n'))
}

fn print_description(d ?StringValue) string {
	if s := d {
		return print_string_value(s) + '\n'
	}
	return ''
}

fn print_name(n ?Name) string {
	if name := n {
		return name.value
	}
	return ''
}

fn print_operation(op OperationDefinition) string {
	if op.shorthand {
		return print_selection_set(op.selection_set)
	}
	defs := op.variable_definitions.map(print_variable_definition(it))
	var_defs := if has_multiline_items(defs) {
		wrap('(\n', join(defs, '\n'), '\n)')
	} else {
		wrap('(', join(defs, ', '), ')')
	}
	prefix := print_description(op.description) +
		join([op.operation.str(), join([print_name(op.name), var_defs], ''),
			print_directives(op.directives)], ' ')
	selection := print_selection_set(op.selection_set)
	return if prefix == 'query' { selection } else { prefix + ' ' + selection }
}

fn print_variable_definition(v VariableDefinition) string {
	mut default_value := ''
	if d := v.default_value {
		default_value = ' = ' + print_value(d)
	}
	return print_description(v.description) + '$' + v.variable.name.value + ': ' +
		print_type(v.typ) + default_value + wrap(' ', print_directives(v.directives), '')
}

fn print_directives(directives []Directive) string {
	return join(directives.map(print_directive(it)), ' ')
}

fn print_directive(d Directive) string {
	return '@' + d.name.value + wrap('(', join(d.arguments.map(print_argument(it)), ', '), ')')
}

fn print_argument(a Argument) string {
	return a.name.value + ': ' + print_value(a.value)
}

fn print_selection_set(s SelectionSet) string {
	return block(s.selections.map(print_selection(it)))
}

fn print_selection(s Selection) string {
	match s {
		Field {
			prefix := wrap('', print_name(s.alias), ': ') + s.name.value
			args := s.arguments.map(print_argument(it))
			mut args_line := prefix + wrap('(', join(args, ', '), ')')
			if utf16_len(args_line, 0, args_line.len) > max_line_length {
				args_line = prefix + wrap('(\n', indent(join(args, '\n')), '\n)')
			}
			mut selection := ''
			if set := s.selection_set {
				selection = print_selection_set(set)
			}
			return join([args_line, print_directives(s.directives), selection], ' ')
		}
		FragmentSpread {
			return '...' + s.name.value + wrap(' ', print_directives(s.directives), '')
		}
		InlineFragment {
			mut condition := ''
			if t := s.type_condition {
				condition = 'on ' + t.name.value
			}
			return join(['...', condition, print_directives(s.directives),
				print_selection_set(s.selection_set)], ' ')
		}
	}
}

fn print_fragment_definition(f FragmentDefinition) string {
	return print_description(f.description) +
		'fragment ${f.name.value} on ${f.type_condition.name.value} ' +
		wrap('', print_directives(f.directives), ' ') + print_selection_set(f.selection_set)
}

// print_value returns a value literal as GraphQL text.
pub fn print_value(v ValueNode) string {
	return match v {
		Variable { '$' + v.name.value }
		IntValue { v.value }
		FloatValue { v.value }
		StringValue { print_string_value(v) }
		BooleanValue {
			if v.value { 'true' } else { 'false' }
		}
		NullValue { 'null' }
		EnumValue { v.value }
		ListValue { '[' + join(v.values.map(print_value(it)), ', ') + ']' }
		ObjectValue {
			'{' + join(v.fields.map(it.name.value + ': ' + print_value(it.value)), ', ') + '}'
		}
	}
}

fn print_string_value(s StringValue) string {
	return if s.block { print_block_string(s.value, false) } else { print_string(s.value) }
}

// print_type returns a type reference as GraphQL text, such as `[String!]`.
pub fn print_type(t TypeNode) string {
	return match t {
		NamedType { t.name.value }
		ListType { '[' + print_type(t.typ) + ']' }
		NonNullType { print_type(t.typ) + '!' }
	}
}

fn print_schema_definition(s SchemaDefinition) string {
	ops := s.operation_types.map(it.operation.str() + ': ' + it.typ.name.value)
	if s.is_extension {
		return join(['extend schema', print_directives(s.directives), block(ops)], ' ')
	}
	return print_description(s.description) +
		join(['schema', print_directives(s.directives), block(ops)], ' ')
}

fn print_type_definition(t TypeDefinition) string {
	keyword := if t.is_extension { 'extend ' + t.kind.keyword() } else { t.kind.keyword() }
	description := if t.is_extension { '' } else { print_description(t.description) }
	directives := print_directives(t.directives)
	return description + match t.kind {
		.scalar {
			join([keyword, t.name.value, directives], ' ')
		}
		.object, .@interface {
			join([keyword, t.name.value, wrap('implements ', join(t.interfaces.map(it.name.value),
				' & '), ''), directives, block(t.fields.map(print_field_definition(it)))],
				' ')
		}
		.@union {
			join([keyword, t.name.value, directives, wrap('= ', join(t.types.map(it.name.value),
				' | '), '')], ' ')
		}
		.@enum {
			join([keyword, t.name.value, directives, block(t.values.map(print_description(it.description) +
				join([it.name.value, print_directives(it.directives)], ' ')))], ' ')
		}
		.input_object {
			join([keyword, t.name.value, directives,
				block(t.input_fields.map(print_input_value_definition(it)))],
				' ')
		}
	}
}

fn print_argument_defs(args []InputValueDefinition) string {
	printed := args.map(print_input_value_definition(it))
	return if has_multiline_items(printed) {
		wrap('(\n', indent(join(printed, '\n')), '\n)')
	} else {
		wrap('(', join(printed, ', '), ')')
	}
}

fn print_field_definition(f FieldDefinition) string {
	return print_description(f.description) + f.name.value + print_argument_defs(f.arguments) +
		': ' + print_type(f.typ) + wrap(' ', print_directives(f.directives), '')
}

fn print_input_value_definition(v InputValueDefinition) string {
	mut default_value := ''
	if d := v.default_value {
		default_value = '= ' + print_value(d)
	}
	return print_description(v.description) +
		join([v.name.value + ': ' + print_type(v.typ), default_value, print_directives(v.directives)], ' ')
}

fn print_directive_definition(d DirectiveDefinition) string {
	return print_description(d.description) + 'directive @' + d.name.value +
		print_argument_defs(d.arguments) + (if d.repeatable { ' repeatable' } else { '' }) +
		' on ' + join(d.locations.map(it.value), ' | ')
}

// print_string returns `s` as a quoted GraphQL string, escaped as graphql-js
// escapes it.
pub fn print_string(s string) string {
	mut b := strings.new_builder(s.len + 2)
	b.write_u8(`"`)
	mut i := 0
	for i < s.len {
		c := s[i]
		if c < 0x80 {
			match c {
				`"` { b.write_string('\\"') }
				`\\` { b.write_string('\\\\') }
				`\b` { b.write_string('\\b') }
				`\t` { b.write_string('\\t') }
				`\n` { b.write_string('\\n') }
				`\f` { b.write_string('\\f') }
				`\r` { b.write_string('\\r') }
				else {
					if c < 0x20 || c == 0x7f {
						b.write_string('\\u' + '${c:04X}')
					} else {
						b.write_u8(c)
					}
				}
			}
			i++
			continue
		}
		code, size := decode_rune(s, i)
		if code >= 0x80 && code <= 0x9f {
			b.write_string('\\u' + '${code:04X}')
		} else {
			b.write_string(s[i..i + size])
		}
		i += size
	}
	b.write_u8(`"`)
	return b.str()
}

fn is_white_space(c u8) bool {
	return c == ` ` || c == `\t`
}

// print_block_string returns `value` as a `"""block string"""`, as graphql-js
// prints it. `minimize` keeps it on one line where it can.
pub fn print_block_string(value string, minimize bool) string {
	escaped := value.replace('"""', '\\"""')
	lines := split_lines(escaped)
	is_single_line := lines.len == 1
	force_leading_new_line := lines.len > 1
		&& lines[1..].all(it.len == 0 || is_white_space(it[0]))
	has_trailing_triple_quotes := escaped.ends_with('\\"""')
	has_trailing_quote := value.ends_with('"') && !has_trailing_triple_quotes
	has_trailing_slash := value.ends_with('\\')
	force_trailing_new_line := has_trailing_quote || has_trailing_slash
	print_as_multiple_lines := !minimize && (!is_single_line
		|| utf16_len(value, 0, value.len) > 70 || force_trailing_new_line
		|| force_leading_new_line || has_trailing_triple_quotes)
	mut result := ''
	skip_leading_new_line := is_single_line && value.len > 0 && is_white_space(value[0])
	if (print_as_multiple_lines && !skip_leading_new_line) || force_leading_new_line {
		result += '\n'
	}
	result += escaped
	if print_as_multiple_lines || force_trailing_new_line {
		result += '\n'
	}
	return '"""' + result + '"""'
}

// split_lines splits `s` at `\r\n`, `\n` and `\r`.
fn split_lines(s string) []string {
	mut lines := []string{}
	mut start := 0
	mut i := 0
	for i < s.len {
		if s[i] == `\n` || s[i] == `\r` {
			lines << s[start..i]
			i += if s[i] == `\r` && i + 1 < s.len && s[i + 1] == `\n` { 2 } else { 1 }
			start = i
			continue
		}
		i++
	}
	lines << s[start..]
	return lines
}
