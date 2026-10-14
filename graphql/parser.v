module graphql

// ParseOptions limits what `parse` accepts.
@[params]
pub struct ParseOptions {
pub:
	// max_tokens rejects a document with more tokens than this; 0 is no limit.
	// It stops very large documents early, before they are validated.
	max_tokens int
}

// parse parses a GraphQL document: operations and fragments, type system
// definitions, or both. A syntax error is a `GraphQLError` with its location.
pub fn parse(source string, opts ParseOptions) !Document {
	mut p := Parser.new(source, opts)
	return p.parse_document()!
}

// parse_value parses a single value literal, such as `{a: [1, 2]}`.
pub fn parse_value(source string) !ValueNode {
	mut p := Parser.new(source)
	p.expect_token(.sof)!
	value := p.parse_value_literal(false)!
	p.expect_token(.eof)!
	return value
}

// parse_type parses a type reference, such as `[String!]!`.
pub fn parse_type(source string) !TypeNode {
	mut p := Parser.new(source)
	p.expect_token(.sof)!
	typ := p.parse_type_reference()!
	p.expect_token(.eof)!
	return typ
}

const directive_locations = ['QUERY', 'MUTATION', 'SUBSCRIPTION', 'FIELD', 'FRAGMENT_DEFINITION',
	'FRAGMENT_SPREAD', 'INLINE_FRAGMENT', 'VARIABLE_DEFINITION', 'SCHEMA', 'SCALAR', 'OBJECT',
	'FIELD_DEFINITION', 'ARGUMENT_DEFINITION', 'INTERFACE', 'UNION', 'ENUM', 'ENUM_VALUE',
	'INPUT_OBJECT', 'INPUT_FIELD_DEFINITION', 'DIRECTIVE_DEFINITION']

struct Parser {
	opts ParseOptions
mut:
	lexer  Lexer
	tokens int
}

fn Parser.new(source string, opts ParseOptions) Parser {
	return Parser{
		opts:  opts
		lexer: Lexer.new(source)
	}
}

fn (p &Parser) token() Token {
	return p.lexer.token
}

fn (p &Parser) peek(kind TokenKind) bool {
	return p.lexer.token.kind == kind
}

fn (mut p Parser) advance() ! {
	token := p.lexer.advance()!
	if token.kind != .eof {
		p.tokens++
		if p.opts.max_tokens > 0 && p.tokens > p.opts.max_tokens {
			return syntax_error(p.lexer.body, token.start, 'Document contains more that ${p.opts.max_tokens} tokens. Parsing aborted.')
		}
	}
}

fn (mut p Parser) expect_token(kind TokenKind) !Token {
	token := p.token()
	if token.kind == kind {
		p.advance()!
		return token
	}
	desc := if kind.is_punctuator() { '"${kind.desc()}"' } else { kind.desc() }
	return syntax_error(p.lexer.body, token.start, 'Expected ${desc}, found ${token.desc()}.')
}

fn (mut p Parser) expect_optional_token(kind TokenKind) !bool {
	if p.token().kind == kind {
		p.advance()!
		return true
	}
	return false
}

fn (mut p Parser) expect_keyword(value string) ! {
	token := p.token()
	if token.kind == .name && token.value == value {
		p.advance()!
		return
	}
	return syntax_error(p.lexer.body, token.start, 'Expected "${value}", found ${token.desc()}.')
}

fn (mut p Parser) expect_optional_keyword(value string) !bool {
	token := p.token()
	if token.kind == .name && token.value == value {
		p.advance()!
		return true
	}
	return false
}

fn (p &Parser) unexpected_at(token Token) IError {
	return syntax_error(p.lexer.body, token.start, 'Unexpected ${token.desc()}.')
}

fn (p &Parser) unexpected() IError {
	return p.unexpected_at(p.token())
}

fn (mut p Parser) parse_name() !Name {
	token := p.expect_token(.name)!
	return Name{
		pos:   token.start
		value: token.value
	}
}

fn (mut p Parser) parse_document() !Document {
	p.expect_token(.sof)!
	mut definitions := []Definition{}
	for {
		definitions << p.parse_definition()!
		if p.expect_optional_token(.eof)! {
			break
		}
	}
	return Document{
		source:      p.lexer.body
		definitions: definitions
	}
}

fn (mut p Parser) parse_definition() !Definition {
	if p.peek(.brace_l) {
		return p.parse_operation_definition()!
	}
	has_description := p.peek_description()
	keyword := if has_description { p.lexer.lookahead()! } else { p.token() }
	if has_description && keyword.kind == .brace_l {
		return syntax_error(p.lexer.body, p.token().start, 'Unexpected description, descriptions are not supported on shorthand queries.')
	}
	if keyword.kind == .name {
		match keyword.value {
			'schema' {
				return p.parse_schema_definition()!
			}
			'scalar' {
				return p.parse_type_definition(.scalar)!
			}
			'type' {
				return p.parse_type_definition(.object)!
			}
			'interface' {
				return p.parse_type_definition(.@interface)!
			}
			'union' {
				return p.parse_type_definition(.@union)!
			}
			'enum' {
				return p.parse_type_definition(.@enum)!
			}
			'input' {
				return p.parse_type_definition(.input_object)!
			}
			'directive' {
				return p.parse_directive_definition()!
			}
			'query', 'mutation', 'subscription' {
				return p.parse_operation_definition()!
			}
			'fragment' {
				return p.parse_fragment_definition()!
			}
			else {}
		}
		if has_description {
			return syntax_error(p.lexer.body, p.token().start, 'Unexpected description, only GraphQL definitions support descriptions.')
		}
		if keyword.value == 'extend' {
			return p.parse_type_system_extension()!
		}
	}
	return p.unexpected_at(keyword)
}

fn (mut p Parser) parse_operation_definition() !OperationDefinition {
	start := p.token()
	if p.peek(.brace_l) {
		return OperationDefinition{
			pos:           start.start
			operation:     .query
			shorthand:     true
			selection_set: p.parse_selection_set()!
		}
	}
	description := p.parse_description()!.value
	operation := p.parse_operation_type()!
	mut name := ?Name(none)
	if p.peek(.name) {
		name = p.parse_name()!
	}
	return OperationDefinition{
		pos:                  start.start
		description:          description
		operation:            operation
		name:                 name
		variable_definitions: p.parse_variable_definitions()!
		directives:           p.parse_directives(false)!
		selection_set:        p.parse_selection_set()!
	}
}

fn (mut p Parser) parse_operation_type() !OperationType {
	token := p.expect_token(.name)!
	return match token.value {
		'query' { .query }
		'mutation' { .mutation }
		'subscription' { .subscription }
		else { p.unexpected_at(token) }
	}
}

fn (mut p Parser) parse_variable_definitions() ![]VariableDefinition {
	mut defs := []VariableDefinition{}
	if p.expect_optional_token(.paren_l)! {
		for {
			defs << p.parse_variable_definition()!
			if p.expect_optional_token(.paren_r)! {
				break
			}
		}
	}
	return defs
}

fn (mut p Parser) parse_variable_definition() !VariableDefinition {
	start := p.token()
	description := p.parse_description()!.value
	variable := p.parse_variable()!
	p.expect_token(.colon)!
	typ := p.parse_type_reference()!
	mut default_value := ?ValueNode(none)
	if p.expect_optional_token(.equals)! {
		default_value = p.parse_value_literal(true)!
	}
	return VariableDefinition{
		pos:           start.start
		description:   description
		variable:      variable
		typ:           typ
		default_value: default_value
		directives:    p.parse_directives(true)!
	}
}

fn (mut p Parser) parse_variable() !Variable {
	start := p.token()
	p.expect_token(.dollar)!
	return Variable{
		pos:  start.start
		name: p.parse_name()!
	}
}

fn (mut p Parser) parse_selection_set() !SelectionSet {
	start := p.token()
	p.expect_token(.brace_l)!
	mut selections := []Selection{}
	for {
		selections << p.parse_selection()!
		if p.expect_optional_token(.brace_r)! {
			break
		}
	}
	return SelectionSet{
		pos:        start.start
		selections: selections
	}
}

fn (mut p Parser) parse_selection() !Selection {
	if p.peek(.spread) {
		return p.parse_fragment()!
	}
	return p.parse_field()!
}

fn (mut p Parser) parse_field() !Field {
	start := p.token()
	name_or_alias := p.parse_name()!
	mut alias := ?Name(none)
	mut name := name_or_alias
	if p.expect_optional_token(.colon)! {
		alias = name_or_alias
		name = p.parse_name()!
	}
	args := p.parse_arguments(false)!
	directives := p.parse_directives(false)!
	mut selection_set := ?SelectionSet(none)
	if p.peek(.brace_l) {
		selection_set = p.parse_selection_set()!
	}
	return Field{
		pos:           start.start
		alias:         alias
		name:          name
		arguments:     args
		directives:    directives
		selection_set: selection_set
	}
}

fn (mut p Parser) parse_arguments(is_const bool) ![]Argument {
	mut args := []Argument{}
	if p.expect_optional_token(.paren_l)! {
		for {
			start := p.token()
			name := p.parse_name()!
			p.expect_token(.colon)!
			args << Argument{
				pos:   start.start
				name:  name
				value: p.parse_value_literal(is_const)!
			}
			if p.expect_optional_token(.paren_r)! {
				break
			}
		}
	}
	return args
}

fn (mut p Parser) parse_fragment() !Selection {
	start := p.token()
	p.expect_token(.spread)!
	has_type_condition := p.expect_optional_keyword('on')!
	if !has_type_condition && p.peek(.name) {
		return FragmentSpread{
			pos:        start.start
			name:       p.parse_fragment_name()!
			directives: p.parse_directives(false)!
		}
	}
	mut type_condition := ?NamedType(none)
	if has_type_condition {
		type_condition = p.parse_named_type()!
	}
	return InlineFragment{
		pos:            start.start
		type_condition: type_condition
		directives:     p.parse_directives(false)!
		selection_set:  p.parse_selection_set()!
	}
}

fn (mut p Parser) parse_fragment_definition() !FragmentDefinition {
	start := p.token()
	description := p.parse_description()!.value
	p.expect_keyword('fragment')!
	name := p.parse_fragment_name()!
	p.expect_keyword('on')!
	return FragmentDefinition{
		pos:            start.start
		description:    description
		name:           name
		type_condition: p.parse_named_type()!
		directives:     p.parse_directives(false)!
		selection_set:  p.parse_selection_set()!
	}
}

fn (mut p Parser) parse_fragment_name() !Name {
	if p.token().value == 'on' {
		return p.unexpected()
	}
	return p.parse_name()!
}

fn (mut p Parser) parse_value_literal(is_const bool) !ValueNode {
	token := p.token()
	match token.kind {
		.bracket_l {
			p.advance()!
			mut values := []ValueNode{}
			for !p.expect_optional_token(.bracket_r)! {
				values << p.parse_value_literal(is_const)!
			}
			return ListValue{
				pos:    token.start
				values: values
			}
		}
		.brace_l {
			p.advance()!
			mut fields := []ObjectField{}
			for !p.expect_optional_token(.brace_r)! {
				start := p.token()
				name := p.parse_name()!
				p.expect_token(.colon)!
				fields << ObjectField{
					pos:   start.start
					name:  name
					value: p.parse_value_literal(is_const)!
				}
			}
			return ObjectValue{
				pos:    token.start
				fields: fields
			}
		}
		.int {
			p.advance()!
			return IntValue{
				pos:   token.start
				value: token.value
			}
		}
		.float {
			p.advance()!
			return FloatValue{
				pos:   token.start
				value: token.value
			}
		}
		.string, .block_string {
			return p.parse_string_literal()!
		}
		.name {
			p.advance()!
			return match token.value {
				'true' {
					BooleanValue{
						pos:   token.start
						value: true
					}
				}
				'false' {
					BooleanValue{
						pos:   token.start
						value: false
					}
				}
				'null' {
					NullValue{
						pos: token.start
					}
				}
				else {
					EnumValue{
						pos:   token.start
						value: token.value
					}
				}
			}
		}
		.dollar {
			if is_const {
				p.expect_token(.dollar)!
				if p.token().kind == .name {
					return syntax_error(p.lexer.body, token.start, 'Unexpected variable "$${p.token().value}" in constant value.')
				}
				return p.unexpected_at(token)
			}
			return p.parse_variable()!
		}
		else {
			return p.unexpected()
		}
	}
}

fn (mut p Parser) parse_string_literal() !StringValue {
	token := p.token()
	p.advance()!
	return StringValue{
		pos:   token.start
		value: token.value
		block: token.kind == .block_string
	}
}

fn (mut p Parser) parse_directives(is_const bool) ![]Directive {
	mut directives := []Directive{}
	for p.peek(.at) {
		start := p.token()
		p.advance()!
		directives << Directive{
			pos:       start.start
			name:      p.parse_name()!
			arguments: p.parse_arguments(is_const)!
		}
	}
	return directives
}

fn (mut p Parser) parse_type_reference() !TypeNode {
	start := p.token()
	mut typ := TypeNode(NamedType{})
	if p.expect_optional_token(.bracket_l)! {
		inner := p.parse_type_reference()!
		p.expect_token(.bracket_r)!
		typ = ListType{
			pos: start.start
			typ: inner
		}
	} else {
		typ = p.parse_named_type()!
	}
	if p.expect_optional_token(.bang)! {
		return NonNullType{
			pos: start.start
			typ: typ
		}
	}
	return typ
}

fn (mut p Parser) parse_named_type() !NamedType {
	start := p.token()
	return NamedType{
		pos:  start.start
		name: p.parse_name()!
	}
}

fn (p &Parser) peek_description() bool {
	return p.peek(.string) || p.peek(.block_string)
}

// Description is an optional description: V has no result of an option.
struct Description {
	value ?StringValue
}

fn (mut p Parser) parse_description() !Description {
	if p.peek_description() {
		return Description{p.parse_string_literal()!}
	}
	return Description{}
}

fn (mut p Parser) parse_schema_definition() !SchemaDefinition {
	start := p.token()
	description := p.parse_description()!.value
	p.expect_keyword('schema')!
	directives := p.parse_directives(true)!
	p.expect_token(.brace_l)!
	mut operation_types := []OperationTypeDefinition{}
	for {
		operation_types << p.parse_operation_type_definition()!
		if p.expect_optional_token(.brace_r)! {
			break
		}
	}
	return SchemaDefinition{
		pos:             start.start
		description:     description
		directives:      directives
		operation_types: operation_types
	}
}

fn (mut p Parser) parse_operation_type_definition() !OperationTypeDefinition {
	start := p.token()
	operation := p.parse_operation_type()!
	p.expect_token(.colon)!
	return OperationTypeDefinition{
		pos:       start.start
		operation: operation
		typ:       p.parse_named_type()!
	}
}

// parse_type_definition parses a type definition of `kind`, which starts with
// an optional description and the kind's keyword.
fn (mut p Parser) parse_type_definition(kind TypeDefinitionKind) !TypeDefinition {
	start := p.token()
	description := p.parse_description()!.value
	p.expect_keyword(kind.keyword())!
	name := p.parse_name()!
	return p.parse_type_body(start, kind, false, description, name)!
}

// parse_type_body parses what follows a type's name, for a definition or an
// extension.
fn (mut p Parser) parse_type_body(start Token, kind TypeDefinitionKind, is_extension bool, description ?StringValue, name Name) !TypeDefinition {
	mut interfaces := []NamedType{}
	if kind in [.object, .@interface] {
		interfaces = p.parse_implements_interfaces()!
	}
	directives := p.parse_directives(true)!
	mut fields := []FieldDefinition{}
	mut types := []NamedType{}
	mut values := []EnumValueDefinition{}
	mut input_fields := []InputValueDefinition{}
	match kind {
		.object, .@interface {
			if p.expect_optional_token(.brace_l)! {
				for {
					fields << p.parse_field_definition()!
					if p.expect_optional_token(.brace_r)! {
						break
					}
				}
			}
		}
		.@union {
			if p.expect_optional_token(.equals)! {
				p.expect_optional_token(.pipe)!
				for {
					types << p.parse_named_type()!
					if !p.expect_optional_token(.pipe)! {
						break
					}
				}
			}
		}
		.@enum {
			if p.expect_optional_token(.brace_l)! {
				for {
					values << p.parse_enum_value_definition()!
					if p.expect_optional_token(.brace_r)! {
						break
					}
				}
			}
		}
		.input_object {
			if p.expect_optional_token(.brace_l)! {
				for {
					input_fields << p.parse_input_value_definition()!
					if p.expect_optional_token(.brace_r)! {
						break
					}
				}
			}
		}
		.scalar {}
	}
	if is_extension && interfaces.len == 0 && directives.len == 0 && fields.len == 0
		&& types.len == 0 && values.len == 0 && input_fields.len == 0 {
		return p.unexpected()
	}
	return TypeDefinition{
		pos:          start.start
		kind:         kind
		is_extension: is_extension
		description:  description
		name:         name
		interfaces:   interfaces
		directives:   directives
		fields:       fields
		types:        types
		values:       values
		input_fields: input_fields
	}
}

fn (mut p Parser) parse_implements_interfaces() ![]NamedType {
	mut interfaces := []NamedType{}
	if p.expect_optional_keyword('implements')! {
		p.expect_optional_token(.amp)!
		for {
			interfaces << p.parse_named_type()!
			if !p.expect_optional_token(.amp)! {
				break
			}
		}
	}
	return interfaces
}

fn (mut p Parser) parse_field_definition() !FieldDefinition {
	start := p.token()
	description := p.parse_description()!.value
	name := p.parse_name()!
	args := p.parse_argument_defs()!
	p.expect_token(.colon)!
	typ := p.parse_type_reference()!
	return FieldDefinition{
		pos:         start.start
		description: description
		name:        name
		arguments:   args
		typ:         typ
		directives:  p.parse_directives(true)!
	}
}

fn (mut p Parser) parse_argument_defs() ![]InputValueDefinition {
	mut args := []InputValueDefinition{}
	if p.expect_optional_token(.paren_l)! {
		for {
			args << p.parse_input_value_definition()!
			if p.expect_optional_token(.paren_r)! {
				break
			}
		}
	}
	return args
}

fn (mut p Parser) parse_input_value_definition() !InputValueDefinition {
	start := p.token()
	description := p.parse_description()!.value
	name := p.parse_name()!
	p.expect_token(.colon)!
	typ := p.parse_type_reference()!
	mut default_value := ?ValueNode(none)
	if p.expect_optional_token(.equals)! {
		default_value = p.parse_value_literal(true)!
	}
	return InputValueDefinition{
		pos:           start.start
		description:   description
		name:          name
		typ:           typ
		default_value: default_value
		directives:    p.parse_directives(true)!
	}
}

fn (mut p Parser) parse_enum_value_definition() !EnumValueDefinition {
	start := p.token()
	description := p.parse_description()!.value
	token := p.token()
	if token.value in ['true', 'false', 'null'] {
		return syntax_error(p.lexer.body, token.start, '${token.desc()} is reserved and cannot be used for an enum value.')
	}
	name := p.parse_name()!
	return EnumValueDefinition{
		pos:         start.start
		description: description
		name:        name
		directives:  p.parse_directives(true)!
	}
}

fn (mut p Parser) parse_type_system_extension() !Definition {
	keyword := p.lexer.lookahead()!
	if keyword.kind == .name {
		kind := match keyword.value {
			'schema' {
				return p.parse_schema_extension()!
			}
			'scalar' {
				TypeDefinitionKind.scalar
			}
			'type' {
				TypeDefinitionKind.object
			}
			'interface' {
				TypeDefinitionKind.@interface
			}
			'union' {
				TypeDefinitionKind.@union
			}
			'enum' {
				TypeDefinitionKind.@enum
			}
			'input' {
				TypeDefinitionKind.input_object
			}
			else {
				return p.unexpected_at(keyword)
			}
		}
		start := p.token()
		p.expect_keyword('extend')!
		p.expect_keyword(kind.keyword())!
		name := p.parse_name()!
		return p.parse_type_body(start, kind, true, none, name)!
	}
	return p.unexpected_at(keyword)
}

fn (mut p Parser) parse_schema_extension() !SchemaDefinition {
	start := p.token()
	p.expect_keyword('extend')!
	p.expect_keyword('schema')!
	directives := p.parse_directives(true)!
	mut operation_types := []OperationTypeDefinition{}
	if p.expect_optional_token(.brace_l)! {
		for {
			operation_types << p.parse_operation_type_definition()!
			if p.expect_optional_token(.brace_r)! {
				break
			}
		}
	}
	if directives.len == 0 && operation_types.len == 0 {
		return p.unexpected()
	}
	return SchemaDefinition{
		pos:             start.start
		is_extension:    true
		directives:      directives
		operation_types: operation_types
	}
}

fn (mut p Parser) parse_directive_definition() !DirectiveDefinition {
	start := p.token()
	description := p.parse_description()!.value
	p.expect_keyword('directive')!
	p.expect_token(.at)!
	name := p.parse_name()!
	args := p.parse_argument_defs()!
	repeatable := p.expect_optional_keyword('repeatable')!
	p.expect_keyword('on')!
	p.expect_optional_token(.pipe)!
	mut locations := []Name{}
	for {
		token := p.token()
		location := p.parse_name()!
		if location.value !in directive_locations {
			return p.unexpected_at(token)
		}
		locations << location
		if !p.expect_optional_token(.pipe)! {
			break
		}
	}
	return DirectiveDefinition{
		pos:         start.start
		description: description
		name:        name
		arguments:   args
		repeatable:  repeatable
		locations:   locations
	}
}
