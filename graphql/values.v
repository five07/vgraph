module graphql

import math
import strconv

// Scalar is how a custom scalar coerces values; each function may be left unset.
// `serialize` turns a resolver's result into the response value, `parse_value`
// checks a variable's value, and `parse_literal` reads a literal in a document.
// Unset, a scalar passes values through unchanged, and reads any literal. An
// error's message explains the rejection; an empty one rejects without a reason.
pub struct Scalar {
pub:
	serialize     ?fn (Value) !Value
	parse_value   ?fn (Value) !Value
	parse_literal ?fn (ValueNode, map[string]Value) !Value
}

const max_int = 2147483647
const min_int = -2147483648

// js_number formats a float as JavaScript's `String(n)` does, so values print
// as they do in graphql-js: `1` rather than `1.0`, and `1e+21` past 10^21.
pub fn js_number(f f64) string {
	if math.is_nan(f) {
		return 'NaN'
	}
	if math.is_inf(f, 1) {
		return 'Infinity'
	}
	if math.is_inf(f, -1) {
		return '-Infinity'
	}
	if f == 0 {
		return '0'
	}
	sign := if f < 0 { '-' } else { '' }
	digits, exp := shortest_digits(math.abs(f))
	k := digits.len
	n := exp + 1 // where the decimal point goes, counted in digits
	if k <= n && n <= 21 {
		return sign + digits + '0'.repeat(n - k)
	}
	if 0 < n && n <= 21 {
		return sign + digits[..n] + '.' + digits[n..]
	}
	if -6 < n && n <= 0 {
		return sign + '0.' + '0'.repeat(-n) + digits
	}
	e := n - 1
	esign := if e < 0 { '-' } else { '+' }
	mantissa := if k == 1 { digits } else { digits[..1] + '.' + digits[1..] }
	return sign + mantissa + 'e' + esign + math.abs(e).str()
}

// shortest_digits returns the fewest decimal digits that read back as `f`
// (positive), and the exponent of the first of them.
fn shortest_digits(f f64) (string, int) {
	for precision in 0 .. 17 {
		s := strconv.f64_to_str(f, precision) // d.ddde+xx
		if strconv.atof64(s) or { -1.0 } == f {
			return split_scientific(s)
		}
	}
	return split_scientific(strconv.f64_to_str(f, 17))
}

fn split_scientific(s string) (string, int) {
	mantissa := s.all_before('e')
	exp := s.all_after('e').int()
	mut digits := mantissa.replace('.', '').trim_right('0')
	if digits == '' {
		digits = '0'
	}
	return digits, exp
}

// is_integer_string reports whether `s` is an integer as JavaScript prints one.
fn is_integer_string(s string) bool {
	mut i := 0
	if s.len > 0 && s[0] == `-` {
		i = 1
	}
	if i >= s.len {
		return false
	}
	if s[i] == `0` {
		return i + 1 == s.len
	}
	for j in i .. s.len {
		if !s[j].is_digit() {
			return false
		}
	}
	return true
}

// inspect returns a value as graphql-js's `inspect` shows it in messages.
pub fn inspect(v Value) string {
	return match v {
		Null {
			'null'
		}
		bool {
			v.str()
		}
		int {
			v.str()
		}
		f64 {
			js_number(v)
		}
		string {
			json_quote(v)
		}
		[]Value {
			if v.len == 0 { '[]' } else { '[' + v.map(inspect(it)).join(', ') + ']' }
		}
		map[string]Value {
			if v.len == 0 {
				'{}'
			} else {
				mut parts := []string{}
				for k, item in v {
					parts << '${k}: ${inspect(item)}'
				}
				'{ ' + parts.join(', ') + ' }'
			}
		}
	}
}

fn json_quote(s string) string {
	return Value(s).json()
}

// is_non_null reports whether `t` is `T!`.
pub fn is_non_null(t TypeNode) bool {
	return t is NonNullType
}

// nullable returns `t` without its outer `!`.
pub fn nullable(t TypeNode) TypeNode {
	return if t is NonNullType { t.typ } else { t }
}

// value_from_ast coerces a literal to a value of type `t`, as graphql-js's
// `valueFromAST` does. It returns `none` when the literal is invalid for `t`,
// or refers to a variable that `variables` doesn't have; pass an empty map
// where there are no variables.
pub fn (s &Schema) value_from_ast(node ValueNode, t TypeNode, variables map[string]Value) ?Value {
	if node is Variable {
		value := variables[node.name.value] or { return none }
		if value is Null && t is NonNullType {
			return none
		}
		return value
	}
	if t is NonNullType {
		if node is NullValue {
			return none
		}
		return s.value_from_ast(node, t.typ, variables)
	}
	if node is NullValue {
		return null
	}
	if t is ListType {
		if node is ListValue {
			mut out := []Value{}
			for item in node.values {
				if is_missing_variable(item, variables) {
					if t.typ is NonNullType {
						return none
					}
					out << null
				} else {
					out << s.value_from_ast(item, t.typ, variables)?
				}
			}
			return Value(out)
		}
		return Value([s.value_from_ast(node, t.typ, variables)?])
	}
	named := t as NamedType
	typ := s.get_type(named.name.value) or { return none }
	match typ.kind {
		.input_object {
			if node !is ObjectValue {
				return none
			}
			object := node as ObjectValue
			mut field_nodes := map[string]ObjectField{}
			for f in object.fields {
				field_nodes[f.name.value] = f
			}
			mut out := map[string]Value{}
			for field in typ.input_fields {
				field_node := field_nodes[field.name] or {
					ObjectField{
						pos: -1
					}
				}
				if field_node.pos < 0 || is_missing_variable(field_node.value, variables) {
					if d := field.default_value {
						out[field.name] = d
					} else if field.typ is NonNullType {
						return none
					}
					continue
				}
				out[field.name] = s.value_from_ast(field_node.value, field.typ, variables)?
			}
			if typ.is_one_of {
				if out.len != 1 {
					return none
				}
				for _, v in out {
					if v is Null {
						return none
					}
				}
			}
			return Value(out)
		}
		.@enum {
			if node is EnumValue {
				if _ := typ.enum_value(node.value) {
					return Value(node.value)
				}
			}
			return none
		}
		.scalar {
			return s.parse_literal(typ.name, node, variables) or { return none }
		}
		else {
			return none
		}
	}
}

fn is_missing_variable(node ValueNode, variables map[string]Value) bool {
	if node is Variable {
		return node.name.value !in variables
	}
	return false
}

// value_from_ast_untyped returns a literal's value with no type to coerce it to,
// as graphql-js's `valueFromASTUntyped` does: integers are ints, other numbers
// floats, and enum values strings.
pub fn value_from_ast_untyped(node ValueNode, variables map[string]Value) ?Value {
	return match node {
		NullValue {
			null
		}
		IntValue {
			Value(node.value.int())
		}
		FloatValue {
			Value(node.value.f64())
		}
		StringValue {
			Value(node.value)
		}
		EnumValue {
			Value(node.value)
		}
		BooleanValue {
			Value(node.value)
		}
		ListValue {
			mut out := []Value{}
			for item in node.values {
				out << value_from_ast_untyped(item, variables)?
			}
			Value(out)
		}
		ObjectValue {
			mut out := map[string]Value{}
			for f in node.fields {
				out[f.name.value] = value_from_ast_untyped(f.value, variables)?
			}
			Value(out)
		}
		Variable {
			variables[node.name.value] or { return none }
		}
	}
}

// parse_literal reads a literal of the scalar `name`, or fails with the message
// graphql-js gives.
pub fn (s &Schema) parse_literal(name string, node ValueNode, variables map[string]Value) !Value {
	match name {
		'Int' {
			if node is IntValue {
				n := node.value.i64()
				if n > max_int || n < min_int || node.value.len > 11 {
					return error('Int cannot represent non 32-bit signed integer value: ${node.value}')
				}
				return Value(int(n))
			}
			return error('Int cannot represent non-integer value: ${print_value(node)}')
		}
		'Float' {
			if node is IntValue {
				return Value(node.value.f64())
			}
			if node is FloatValue {
				return Value(node.value.f64())
			}
			return error('Float cannot represent non numeric value: ${print_value(node)}')
		}
		'String' {
			if node is StringValue {
				return Value(node.value)
			}
			return error('String cannot represent a non string value: ${print_value(node)}')
		}
		'Boolean' {
			if node is BooleanValue {
				return Value(node.value)
			}
			return error('Boolean cannot represent a non boolean value: ${print_value(node)}')
		}
		'ID' {
			if node is StringValue {
				return Value(node.value)
			}
			if node is IntValue {
				return Value(node.value)
			}
			return error('ID cannot represent a non-string and non-integer value: ${print_value(node)}')
		}
		else {
			if scalar := s.scalars[name] {
				if f := scalar.parse_literal {
					return f(node, variables)!
				}
			}
			return value_from_ast_untyped(node, variables) or {
				return error('Expected value of type "${name}", found ${print_value(node)}.')
			}
		}
	}
}

// parse_scalar_value checks a variable's value for the scalar `name`, or fails
// with the message graphql-js gives.
pub fn (s &Schema) parse_scalar_value(name string, v Value) !Value {
	match name {
		'Int' {
			if v is int {
				return v
			}
			if v is f64 {
				if v == math.floor(v) && !math.is_inf(v, 0) {
					if v > max_int || v < min_int {
						return error('Int cannot represent non 32-bit signed integer value: ${js_number(v)}')
					}
					return Value(int(v))
				}
			}
			return error('Int cannot represent non-integer value: ${inspect(v)}')
		}
		'Float' {
			if v is int {
				return Value(f64(v))
			}
			if v is f64 {
				return v
			}
			return error('Float cannot represent non numeric value: ${inspect(v)}')
		}
		'String' {
			if v is string {
				return v
			}
			return error('String cannot represent a non string value: ${inspect(v)}')
		}
		'Boolean' {
			if v is bool {
				return v
			}
			return error('Boolean cannot represent a non boolean value: ${inspect(v)}')
		}
		'ID' {
			if v is string {
				return v
			}
			if v is int {
				return Value(v.str())
			}
			if v is f64 {
				if v == math.floor(v) && math.abs(v) < 1e21 {
					return Value(js_number(v))
				}
			}
			return error('ID cannot represent value: ${inspect(v)}')
		}
		else {
			if scalar := s.scalars[name] {
				if f := scalar.parse_value {
					return f(v)!
				}
			}
			return v
		}
	}
}

// serialize_scalar turns a resolver's result into the response value of the
// scalar `name`, or fails with the message graphql-js gives.
pub fn (s &Schema) serialize_scalar(name string, v Value) !Value {
	match name {
		'Int' {
			match v {
				int {
					return v
				}
				bool {
					return Value(if v { 1 } else { 0 })
				}
				f64 {
					if v == math.floor(v) && !math.is_inf(v, 0) {
						if v > max_int || v < min_int {
							return error('Int cannot represent non 32-bit signed integer value: ${js_number(v)}')
						}
						return Value(int(v))
					}
				}
				string {
					if v != '' {
						f := strconv.atof64(v) or { f64(math.nan()) }
						if !math.is_nan(f) && f == math.floor(f) {
							if f > max_int || f < min_int {
								return error('Int cannot represent non 32-bit signed integer value: ${inspect(v)}')
							}
							return Value(int(f))
						}
					}
				}
				else {}
			}
			return error('Int cannot represent non-integer value: ${inspect(v)}')
		}
		'Float' {
			match v {
				f64 {
					if !math.is_nan(v) && !math.is_inf(v, 0) {
						return v
					}
				}
				int {
					return Value(f64(v))
				}
				bool {
					return Value(if v { f64(1) } else { f64(0) })
				}
				string {
					if v != '' {
						if f := strconv.atof64(v) {
							return Value(f)
						}
					}
				}
				else {}
			}
			return error('Float cannot represent non numeric value: ${inspect(v)}')
		}
		'String' {
			return match v {
				string { v }
				bool { Value(if v { 'true' } else { 'false' }) }
				int { Value(v.str()) }
				f64 { Value(js_number(v)) }
				else { error('String cannot represent value: ${inspect(v)}') }
			}
		}
		'Boolean' {
			return match v {
				bool { v }
				int { Value(v != 0) }
				f64 { Value(v != 0) }
				else { error('Boolean cannot represent a non boolean value: ${inspect(v)}') }
			}
		}
		'ID' {
			match v {
				string {
					return v
				}
				int {
					return Value(v.str())
				}
				f64 {
					if v == math.floor(v) {
						return Value(js_number(v))
					}
				}
				else {}
			}
			return error('ID cannot represent value: ${inspect(v)}')
		}
		else {
			if scalar := s.scalars[name] {
				if f := scalar.serialize {
					return f(v)!
				}
			}
			return v
		}
	}
}

// ast_from_value returns the literal for `v` as a value of type `t`, as
// graphql-js's `astFromValue` does, or `none` when there is none.
pub fn (s &Schema) ast_from_value(v ?Value, t TypeNode) ?ValueNode {
	if t is NonNullType {
		node := s.ast_from_value(v, t.typ)?
		if node is NullValue {
			return none
		}
		return node
	}
	value := v?
	if value is Null {
		return NullValue{}
	}
	if t is ListType {
		if value is []Value {
			mut items := []ValueNode{}
			for item in value {
				if node := s.ast_from_value(item, t.typ) {
					items << node
				}
			}
			return ListValue{
				values: items
			}
		}
		return s.ast_from_value(value, t.typ)
	}
	named := t as NamedType
	typ := s.get_type(named.name.value)?
	match typ.kind {
		.input_object {
			if value !is map[string]Value {
				return none
			}
			object := value as map[string]Value
			mut fields := []ObjectField{}
			for field in typ.input_fields {
				if fv := object[field.name] {
					if node := s.ast_from_value(fv, field.typ) {
						fields << ObjectField{
							name:  Name{
								value: field.name
							}
							value: node
						}
					}
				}
			}
			return ObjectValue{
				fields: fields
			}
		}
		.@enum {
			if value is string {
				if _ := typ.enum_value(value) {
					return EnumValue{
						value: value
					}
				}
			}
			return none
		}
		.scalar {
			serialized := s.serialize_scalar(typ.name, value) or { return none }
			return match serialized {
				Null {
					none
				}
				bool {
					BooleanValue{
						value: serialized
					}
				}
				int {
					IntValue{
						value: serialized.str()
					}
				}
				f64 {
					num := js_number(serialized)
					if is_integer_string(num) {
						ValueNode(IntValue{
							value: num
						})
					} else {
						ValueNode(FloatValue{
							value: num
						})
					}
				}
				string {
					if typ.name == 'ID' && is_integer_string(serialized) {
						ValueNode(IntValue{
							value: serialized
						})
					} else {
						ValueNode(StringValue{
							value: serialized
						})
					}
				}
				else {
					// a custom scalar's list or object: written out untyped
					untyped_ast(serialized)
				}
			}
		}
		else {
			return none
		}
	}
}

fn untyped_ast(v Value) ValueNode {
	return match v {
		Null {
			NullValue{}
		}
		bool {
			BooleanValue{
				value: v
			}
		}
		int {
			IntValue{
				value: v.str()
			}
		}
		f64 {
			FloatValue{
				value: js_number(v)
			}
		}
		string {
			StringValue{
				value: v
			}
		}
		[]Value {
			ListValue{
				values: v.map(untyped_ast(it))
			}
		}
		map[string]Value {
			mut fields := []ObjectField{}
			for k, item in v {
				fields << ObjectField{
					name:  Name{
						value: k
					}
					value: untyped_ast(item)
				}
			}
			ObjectValue{
				fields: fields
			}
		}
	}
}

// argument_values coerces the arguments of a field or directive, as
// graphql-js's `getArgumentValues` does: defaults fill in missing arguments,
// and a missing required one, or an invalid value, is an error located at the
// node at `pos`.
pub fn (s &Schema) argument_values(defs []InputValueDef, args []Argument, variables map[string]Value, doc &Document, pos int) !map[string]Value {
	mut out := map[string]Value{}
	for def in defs {
		mut arg := ?Argument(none)
		for a in args {
			if a.name.value == def.name {
				arg = a
				break
			}
		}
		node := arg or {
			if d := def.default_value {
				out[def.name] = d
			} else if def.typ is NonNullType {
				return located(doc, pos, 'Argument "${def.name}" of required type "${print_type(def.typ)}" was not provided.')
			}
			continue
		}
		value_node := node.value
		mut is_null := value_node is NullValue
		if value_node is Variable {
			name := value_node.name.value
			if name !in variables {
				if d := def.default_value {
					out[def.name] = d
				} else if def.typ is NonNullType {
					return located(doc, value_node.pos, 'Argument "${def.name}" of required type "${print_type(def.typ)}" was provided the variable "$${name}" which was not provided a runtime value.')
				}
				continue
			}
			is_null = variables[name] or { null } is Null
		}
		if is_null && def.typ is NonNullType {
			return located(doc, value_node.pos(), 'Argument "${def.name}" of non-null type "${print_type(def.typ)}" must not be null.')
		}
		out[def.name] = s.value_from_ast(value_node, def.typ, variables) or {
			return located(doc, value_node.pos(), 'Argument "${def.name}" has invalid value ${print_value(value_node)}.')
		}
	}
	return out
}

// located returns an error at the byte offset `pos` of `doc`.
fn located(doc &Document, pos int, message string) GraphQLError {
	return GraphQLError{
		message:   message
		locations: [doc.location(pos)]
	}
}
