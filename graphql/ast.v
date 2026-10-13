module graphql

// Every node records `pos`, the byte offset in the source where it starts; a
// `Document` keeps the source, so a position becomes a line and column with
// `Document.location`.

// Document is a parsed GraphQL document: operations and fragments, type system
// definitions and extensions, or a mix.
@[heap]
pub struct Document {
pub:
	source      string
	definitions []Definition
}

// location returns the line and column of the byte offset `pos` in the document.
pub fn (d &Document) location(pos int) Location {
	return location_of(d.source, pos)
}

pub type Definition = DirectiveDefinition
	| FragmentDefinition
	| OperationDefinition
	| SchemaDefinition
	| TypeDefinition

// Name is a name: of a field, type, argument, variable, and so on.
pub struct Name {
pub:
	pos   int
	value string
}

pub enum OperationType {
	query
	mutation
	subscription
}

// str returns `query`, `mutation` or `subscription`.
pub fn (o OperationType) str() string {
	return match o {
		.query { 'query' }
		.mutation { 'mutation' }
		.subscription { 'subscription' }
	}
}

// OperationDefinition is a query, mutation or subscription. A shorthand query
// (`{ field }`) has `shorthand` set, and no name.
pub struct OperationDefinition {
pub:
	pos                  int
	description          ?StringValue
	operation            OperationType
	shorthand            bool
	name                 ?Name
	variable_definitions []VariableDefinition
	directives           []Directive
	selection_set        SelectionSet
}

// VariableDefinition is `$name: Type = default`, in an operation's header.
pub struct VariableDefinition {
pub:
	pos           int
	description   ?StringValue
	variable      Variable
	typ           TypeNode
	default_value ?ValueNode
	directives    []Directive
}

// SelectionSet is `{ ... }`: the fields and fragments selected on an object.
pub struct SelectionSet {
pub:
	pos        int
	selections []Selection
}

pub type Selection = Field | FragmentSpread | InlineFragment

// Field is a field selection: `alias: name(arguments) @directives { ... }`.
pub struct Field {
pub:
	pos           int
	alias         ?Name
	name          Name
	arguments     []Argument
	directives    []Directive
	selection_set ?SelectionSet
}

// response_key returns the field's key in the response: its alias, or its name.
pub fn (f &Field) response_key() string {
	if alias := f.alias {
		return alias.value
	}
	return f.name.value
}

// Argument is `name: value`, in a field or directive.
pub struct Argument {
pub:
	pos   int
	name  Name
	value ValueNode
}

// FragmentSpread is `...Name @directives`.
pub struct FragmentSpread {
pub:
	pos        int
	name       Name
	directives []Directive
}

// InlineFragment is `... on Type @directives { ... }`; the type is optional.
pub struct InlineFragment {
pub:
	pos            int
	type_condition ?NamedType
	directives     []Directive
	selection_set  SelectionSet
}

// FragmentDefinition is `fragment Name on Type @directives { ... }`.
pub struct FragmentDefinition {
pub:
	pos            int
	description    ?StringValue
	name           Name
	type_condition NamedType
	directives     []Directive
	selection_set  SelectionSet
}

// Directive is `@name(arguments)`.
pub struct Directive {
pub:
	pos       int
	name      Name
	arguments []Argument
}

pub type ValueNode = BooleanValue
	| EnumValue
	| FloatValue
	| IntValue
	| ListValue
	| NullValue
	| ObjectValue
	| StringValue
	| Variable

// Variable is `$name`.
pub struct Variable {
pub:
	pos  int
	name Name
}

// IntValue is an integer literal, as written.
pub struct IntValue {
pub:
	pos   int
	value string
}

// FloatValue is a float literal, as written.
pub struct FloatValue {
pub:
	pos   int
	value string
}

// StringValue is a string literal; `block` marks a `"""block string"""`.
pub struct StringValue {
pub:
	pos   int
	value string
	block bool
}

// BooleanValue is `true` or `false`.
pub struct BooleanValue {
pub:
	pos   int
	value bool
}

// NullValue is `null`.
pub struct NullValue {
pub:
	pos int
}

// EnumValue is an enum value: a name other than `true`, `false` and `null`.
pub struct EnumValue {
pub:
	pos   int
	value string
}

// ListValue is `[values]`.
pub struct ListValue {
pub:
	pos    int
	values []ValueNode
}

// ObjectValue is `{name: value, ...}`.
pub struct ObjectValue {
pub:
	pos    int
	fields []ObjectField
}

// ObjectField is one `name: value` of an object value.
pub struct ObjectField {
pub:
	pos   int
	name  Name
	value ValueNode
}

// pos returns where the value starts.
pub fn (v ValueNode) pos() int {
	return match v {
		BooleanValue, EnumValue, FloatValue, IntValue, ListValue, NullValue, ObjectValue,
		StringValue, Variable {
			v.pos
		}
	}
}

pub type TypeNode = ListType | NamedType | NonNullType

// NamedType is a type by name, such as `String`.
pub struct NamedType {
pub:
	pos  int
	name Name
}

// ListType is `[Type]`.
pub struct ListType {
pub:
	pos int
	typ TypeNode
}

// NonNullType is `Type!`.
pub struct NonNullType {
pub:
	pos int
	typ TypeNode
}

// pos returns where the type starts.
pub fn (t TypeNode) pos() int {
	return match t {
		ListType, NamedType, NonNullType { t.pos }
	}
}

// named returns the name at the bottom of a list or non-null type.
pub fn (t TypeNode) named() NamedType {
	return match t {
		NamedType { t }
		ListType { t.typ.named() }
		NonNullType { t.typ.named() }
	}
}

// SchemaDefinition is `schema { query: Query ... }`, or with `is_extension`,
// `extend schema ...`.
pub struct SchemaDefinition {
pub:
	pos             int
	is_extension    bool
	description     ?StringValue
	directives      []Directive
	operation_types []OperationTypeDefinition
}

// OperationTypeDefinition is `query: Query` in a schema definition.
pub struct OperationTypeDefinition {
pub:
	pos       int
	operation OperationType
	typ       NamedType
}

pub enum TypeDefinitionKind {
	scalar
	object
	@interface
	@union
	@enum
	input_object
}

// keyword returns the keyword that starts the definition, such as `type`.
pub fn (k TypeDefinitionKind) keyword() string {
	return match k {
		.scalar { 'scalar' }
		.object { 'type' }
		.@interface { 'interface' }
		.@union { 'union' }
		.@enum { 'enum' }
		.input_object { 'input' }
	}
}

// TypeDefinition is a type definition, or with `is_extension`, an extension
// (`extend type ...`). Which lists apply depends on `kind`: `interfaces` and
// `fields` for objects and interfaces, `types` for unions, `values` for enums,
// and `input_fields` for input objects.
pub struct TypeDefinition {
pub:
	pos          int
	kind         TypeDefinitionKind
	is_extension bool
	description  ?StringValue
	name         Name
	interfaces   []NamedType
	directives   []Directive
	fields       []FieldDefinition
	types        []NamedType
	values       []EnumValueDefinition
	input_fields []InputValueDefinition
}

// FieldDefinition is a field of an object or interface type.
pub struct FieldDefinition {
pub:
	pos         int
	description ?StringValue
	name        Name
	arguments   []InputValueDefinition
	typ         TypeNode
	directives  []Directive
}

// InputValueDefinition is an argument, or a field of an input object.
pub struct InputValueDefinition {
pub:
	pos           int
	description   ?StringValue
	name          Name
	typ           TypeNode
	default_value ?ValueNode
	directives    []Directive
}

// EnumValueDefinition is a value of an enum type.
pub struct EnumValueDefinition {
pub:
	pos         int
	description ?StringValue
	name        Name
	directives  []Directive
}

// DirectiveDefinition is `directive @name(arguments) repeatable on LOCATIONS`.
pub struct DirectiveDefinition {
pub:
	pos         int
	description ?StringValue
	name        Name
	arguments   []InputValueDefinition
	repeatable  bool
	locations   []Name
}

// pos returns where the definition starts.
pub fn (d Definition) pos() int {
	return match d {
		DirectiveDefinition, FragmentDefinition, OperationDefinition, SchemaDefinition,
		TypeDefinition {
			d.pos
		}
	}
}
