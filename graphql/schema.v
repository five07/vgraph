module graphql

// Type is a named type of a schema. Which fields apply depends on `kind`:
// `interfaces` and `fields` for objects and interfaces, `possible_types` for
// unions (their members), `values` for enums, and `input_fields` for input
// objects.
pub struct Type {
pub mut:
	kind             TypeDefinitionKind
	name             string
	description      ?string
	specified_by_url ?string
	is_one_of        bool
	interfaces       []string
	fields           []FieldDef
	possible_types   []string
	values           []EnumValueDef
	input_fields     []InputValueDef
	directives       []Directive // applied in the definition and its extensions
	pos              int         // where the definition starts in the schema's source
}

// FieldDef is a field of an object or interface type.
pub struct FieldDef {
pub mut:
	name               string
	description        ?string
	args               []InputValueDef
	typ                TypeNode
	deprecation_reason ?string
	directives         []Directive
	pos                int
}

// InputValueDef is an argument, or a field of an input object. `default_value`
// is the coerced default, `none` when there is none; a default of `null` is
// `graphql.null`.
pub struct InputValueDef {
pub mut:
	name               string
	description        ?string
	typ                TypeNode
	default_value      ?Value
	default_literal    ?ValueNode
	deprecation_reason ?string
	directives         []Directive
	pos                int
}

// EnumValueDef is a value of an enum type.
pub struct EnumValueDef {
pub mut:
	name               string
	description        ?string
	deprecation_reason ?string
	directives         []Directive
	pos                int
}

// DirectiveDef is a directive a schema defines, or one of the built-in ones.
pub struct DirectiveDef {
pub mut:
	name               string
	description        ?string
	args               []InputValueDef
	repeatable         bool
	locations          []string
	deprecation_reason ?string
	pos                int
}

// field returns the field `name`.
pub fn (t &Type) field(name string) ?FieldDef {
	for f in t.fields {
		if f.name == name {
			return f
		}
	}
	return none
}

// input_field returns the input field `name`.
pub fn (t &Type) input_field(name string) ?InputValueDef {
	for f in t.input_fields {
		if f.name == name {
			return f
		}
	}
	return none
}

// enum_value returns the enum value `name`.
pub fn (t &Type) enum_value(name string) ?EnumValueDef {
	for v in t.values {
		if v.name == name {
			return v
		}
	}
	return none
}

// arg returns the argument `name` of the field.
pub fn (f &FieldDef) arg(name string) ?InputValueDef {
	for a in f.args {
		if a.name == name {
			return a
		}
	}
	return none
}

// is_leaf reports whether the type is a scalar or an enum.
pub fn (t &Type) is_leaf() bool {
	return t.kind in [.scalar, .@enum]
}

// is_composite reports whether the type is an object, interface or union: one
// that has a selection set.
pub fn (t &Type) is_composite() bool {
	return t.kind in [.object, .@interface, .@union]
}

// is_abstract reports whether the type is an interface or a union.
pub fn (t &Type) is_abstract() bool {
	return t.kind in [.@interface, .@union]
}

// is_input reports whether values of the type can be inputs.
pub fn (t &Type) is_input() bool {
	return t.kind in [.scalar, .@enum, .input_object]
}

// is_output reports whether values of the type can be field results.
pub fn (t &Type) is_output() bool {
	return t.kind != .input_object
}

// Schema is a GraphQL schema: its types, in the order graphql-js lists them,
// its directives, and its root operation types.
@[heap]
pub struct Schema {
pub mut:
	description  ?string
	query        ?string
	mutation     ?string
	subscription ?string
	types        map[string]Type
	type_names   []string // in order
	directives   []DirectiveDef
	source       string // the SDL it was built from
	// has_schema_definition is set when the SDL has a `schema { ... }`.
	has_schema_definition bool
	// implementations maps each interface to the object types and the
	// interfaces that implement it, in type order.
	implementations map[string]Implementations
	// scalars holds the coercion of custom scalars; see `Schema.scalar`.
	scalars map[string]Scalar
}

// Implementations are the types that implement an interface.
pub struct Implementations {
pub mut:
	objects    []string
	interfaces []string
}

pub const specified_scalars = ['String', 'Int', 'Float', 'Boolean', 'ID']

pub const specified_directives = ['include', 'skip', 'deprecated', 'specifiedBy', 'oneOf']

pub const introspection_types = ['__Schema', '__Type', '__TypeKind', '__Field', '__InputValue',
	'__EnumValue', '__Directive', '__DirectiveLocation']

pub const default_deprecation_reason = 'No longer supported'

// get_type returns the type `name`.
pub fn (s &Schema) get_type(name string) ?Type {
	return s.types[name] or { return none }
}

// get_directive returns the directive `name`.
pub fn (s &Schema) get_directive(name string) ?DirectiveDef {
	for d in s.directives {
		if d.name == name {
			return d
		}
	}
	return none
}

// root_type returns the name of the root type of `operation`.
pub fn (s &Schema) root_type(operation OperationType) ?string {
	return match operation {
		.query { s.query }
		.mutation { s.mutation }
		.subscription { s.subscription }
	}
}

// named_type returns the named type at the bottom of `t`.
pub fn (s &Schema) named_type(t TypeNode) ?Type {
	return s.get_type(t.named().name.value)
}

// possible_types returns the object types an abstract type can be at run time:
// a union's members, or the objects that implement an interface.
pub fn (s &Schema) possible_types(name string) []string {
	t := s.get_type(name) or { return [] }
	return match t.kind {
		.@union { t.possible_types }
		.@interface { s.implementations[name] or { Implementations{} }.objects }
		else { [] }
	}
}

// is_sub_type reports whether `maybe_sub` is one of the types the abstract type
// `abstract` can be: a member of a union, or an object or interface that
// implements an interface.
pub fn (s &Schema) is_sub_type(abstract string, maybe_sub string) bool {
	t := s.get_type(abstract) or { return false }
	if t.kind == .@union {
		return maybe_sub in t.possible_types
	}
	if t.kind == .@interface {
		impls := s.implementations[abstract] or { return false }
		return maybe_sub in impls.objects || maybe_sub in impls.interfaces
	}
	return false
}

// build_schema builds a schema from SDL. The SDL is validated first, as
// graphql-js's `buildSchema` validates it, and every problem is reported
// together, one per paragraph.
pub fn build_schema(sdl string) !Schema {
	doc := parse(sdl)!
	return build_ast_schema(doc)!
}

// build_ast_schema builds a schema from a parsed SDL document.
pub fn build_ast_schema(doc Document) !Schema {
	errors := validate_sdl(doc, none)
	if errors.len > 0 {
		return error(errors.map(it.message).join('\n\n'))
	}
	return build_unchecked(doc)!
}

// Builtins are the types and directives every schema starts from.
struct Builtins {
	types      map[string]Type // the specified scalars and the introspection types
	directives []DirectiveDef  // the specified directives, in order
}

const builtins = make_builtins()

fn make_builtins() Builtins {
	mut types := map[string]Type{}
	descriptions := {
		'String':  'The `String` scalar type represents textual data, represented as UTF-8 character sequences. The String type is most often used by GraphQL to represent free-form human-readable text.'
		'Int':     'The `Int` scalar type represents non-fractional signed whole numeric values. Int can represent values between -(2^31) and 2^31 - 1.'
		'Float':   'The `Float` scalar type represents signed double-precision fractional values as specified by [IEEE 754](https://en.wikipedia.org/wiki/IEEE_floating_point).'
		'Boolean': 'The `Boolean` scalar type represents `true` or `false`.'
		'ID':      'The `ID` scalar type represents a unique identifier, often used to refetch an object or as key for a cache. The ID type appears in a JSON response as a String; however, it is not intended to be human-readable. When expected as an input type, any string (such as `"4"`) or integer (such as `4`) input value will be accepted as an ID.'
	}
	for name in specified_scalars {
		types[name] = Type{
			kind:        .scalar
			name:        name
			description: descriptions[name]
		}
	}
	doc := parse(builtin_sdl) or { panic('graphql: the built-in SDL does not parse: ${err}') }
	mut b := Builder{
		std: types
	}
	built := b.build(doc, false) or { panic('graphql: the built-in SDL does not build: ${err}') }
	for name in introspection_types {
		types[name] = built.types[name] or { panic('graphql: no built-in type ${name}') }
	}
	return Builtins{
		types:      types
		directives: built.directives
	}
}

// build_unchecked builds a schema from an SDL document without validating it.
fn build_unchecked(doc Document) !Schema {
	mut b := Builder{
		std: builtins.types
	}
	return b.build(doc, true)!
}

// Builder builds the types of an SDL document, as graphql-js's
// `extendSchemaImpl` does.
struct Builder {
	std map[string]Type
mut:
	defs       map[string]TypeDefinition
	def_order  []string
	extensions map[string][]TypeDefinition
	built      map[string]Type
}

fn (mut b Builder) build(doc Document, add_specified_directives bool) !Schema {
	mut schema_def := ?SchemaDefinition(none)
	mut schema_extensions := []SchemaDefinition{}
	mut directive_defs := []DirectiveDefinition{}
	for def in doc.definitions {
		match def {
			SchemaDefinition {
				if def.is_extension {
					schema_extensions << def
				} else {
					schema_def = def
				}
			}
			TypeDefinition {
				name := def.name.value
				if def.is_extension {
					b.extensions[name] << def
				} else {
					if name !in b.defs {
						b.def_order << name
					}
					b.defs[name] = def
				}
			}
			DirectiveDefinition {
				directive_defs << def
			}
			else {}
		}
	}
	// the types, in the order they are defined; the specified scalars and the
	// introspection types are always the standard ones
	mut config_types := []string{}
	for name in b.def_order {
		if name in b.std {
			b.built[name] = b.std[name]
		} else {
			b.built[name] = b.build_type(b.defs[name])!
		}
		config_types << name
	}
	// references are checked, and defaults coerced, once every type exists
	for name in config_types {
		b.check_refs(b.built[name])!
	}
	for name in config_types {
		if name in b.std {
			continue
		}
		mut t := b.built[name]
		for mut f in t.fields {
			for mut a in f.args {
				b.coerce_default(mut a)
			}
		}
		for mut f in t.input_fields {
			b.coerce_default(mut f)
		}
		b.built[name] = t
	}
	mut directives := []DirectiveDef{}
	for d in directive_defs {
		directives << b.build_directive(d)!
	}
	if add_specified_directives {
		for std in builtins.directives {
			if !directives.any(it.name == std.name) {
				directives << std
			}
		}
	}
	mut schema := Schema{
		directives: directives
		source:     doc.source
	}
	if sd := schema_def {
		schema.has_schema_definition = true
		if d := sd.description {
			schema.description = d.value
		}
	}
	for sd in [schema_def or { SchemaDefinition{} }] {
		for op in sd.operation_types {
			schema.set_root(op.operation, op.typ.name.value)
		}
	}
	for ext in schema_extensions {
		for op in ext.operation_types {
			schema.set_root(op.operation, op.typ.name.value)
		}
	}
	if schema_def == none {
		for name in config_types {
			match name {
				'Query' { schema.query = name }
				'Mutation' { schema.mutation = name }
				'Subscription' { schema.subscription = name }
				else {}
			}
		}
	}
	b.collect_types(mut schema, config_types)!
	schema.implementations = implementations_of(schema)
	return schema
}

fn (mut s Schema) set_root(operation OperationType, name string) {
	match operation {
		.query { s.query = name }
		.mutation { s.mutation = name }
		.subscription { s.subscription = name }
	}
}

// lookup returns a type by name: a standard one, or one the document builds.
fn (b &Builder) lookup(name string) !Type {
	if t := b.std[name] {
		return t
	}
	if t := b.built[name] {
		return t
	}
	return error('Unknown type: "${name}".')
}

// collect_types fills the schema's types in graphql-js's order: each defined
// type and what it references, then the root types, the directives' argument
// types, and the introspection types.
fn (b &Builder) collect_types(mut schema Schema, config_types []string) ! {
	mut set := OrderedSet{}
	for name in config_types {
		set.add(name)
	}
	for name in config_types {
		set.delete(name)
		b.collect(mut set, name)!
	}
	for root in [schema.query, schema.mutation, schema.subscription] {
		if name := root {
			b.collect(mut set, name)!
		}
	}
	for d in schema.directives {
		for a in d.args {
			b.collect(mut set, a.typ.named().name.value)!
		}
	}
	b.collect(mut set, '__Schema')!
	for name in set.items() {
		schema.types[name] = b.lookup(name)!
		schema.type_names << name
	}
}

fn (b &Builder) collect(mut set OrderedSet, name string) ! {
	if set.has(name) {
		return
	}
	set.add(name)
	t := b.lookup(name)!
	match t.kind {
		.@union {
			for member in t.possible_types {
				b.collect(mut set, member)!
			}
		}
		.object, .@interface {
			for i in t.interfaces {
				b.collect(mut set, i)!
			}
			for f in t.fields {
				b.collect(mut set, f.typ.named().name.value)!
				for a in f.args {
					b.collect(mut set, a.typ.named().name.value)!
				}
			}
		}
		.input_object {
			for f in t.input_fields {
				b.collect(mut set, f.typ.named().name.value)!
			}
		}
		else {}
	}
}

// OrderedSet is a set of names that keeps the order they were added in, like a
// JavaScript `Set`: a name deleted and added again moves to the end.
struct OrderedSet {
mut:
	order []string
	index map[string]int
}

fn (s &OrderedSet) has(name string) bool {
	return name in s.index
}

fn (mut s OrderedSet) add(name string) {
	if name !in s.index {
		s.index[name] = s.order.len
		s.order << name
	}
}

fn (mut s OrderedSet) delete(name string) {
	if i := s.index[name] {
		s.order[i] = ''
		s.index.delete(name)
	}
}

fn (s &OrderedSet) items() []string {
	return s.order.filter(it != '')
}

fn implementations_of(schema Schema) map[string]Implementations {
	mut out := map[string]Implementations{}
	for name in schema.type_names {
		t := schema.types[name] or { continue }
		if t.kind == .@interface {
			for i in t.interfaces {
				mut impl := out[i] or { Implementations{} }
				impl.interfaces << name
				out[i] = impl
			}
		} else if t.kind == .object {
			for i in t.interfaces {
				mut impl := out[i] or { Implementations{} }
				impl.objects << name
				out[i] = impl
			}
		}
	}
	return out
}

fn description_of(d ?StringValue) ?string {
	if s := d {
		return s.value
	}
	return none
}

// check_refs checks that every type `t` refers to exists.
fn (b &Builder) check_refs(t Type) ! {
	for name in t.interfaces {
		b.lookup(name)!
	}
	for name in t.possible_types {
		b.lookup(name)!
	}
	for f in t.fields {
		b.lookup(f.typ.named().name.value)!
		for a in f.args {
			b.lookup(a.typ.named().name.value)!
		}
	}
	for f in t.input_fields {
		b.lookup(f.typ.named().name.value)!
	}
}

fn (mut b Builder) build_type(def TypeDefinition) !Type {
	name := def.name.value
	exts := b.extensions[name] or { []TypeDefinition{} }
	mut all := [def]
	all << exts
	mut t := Type{
		kind:        def.kind
		name:        name
		description: description_of(def.description)
		pos:         def.pos
	}
	for node in all {
		t.directives << node.directives
		for i in node.interfaces {
			t.interfaces << i.name.value
		}
		for m in node.types {
			t.possible_types << m.name.value
		}
		for f in node.fields {
			field := FieldDef{
				name:               f.name.value
				description:        description_of(f.description)
				args:               b.build_args(f.arguments)!
				typ:                f.typ
				deprecation_reason: deprecation_reason(f.directives)
				directives:         f.directives
				pos:                f.pos
			}
			replace_or_add_field(mut t.fields, field)
		}
		for v in node.values {
			value := EnumValueDef{
				name:               v.name.value
				description:        description_of(v.description)
				deprecation_reason: deprecation_reason(v.directives)
				directives:         v.directives
				pos:                v.pos
			}
			if i := index_of_value(t.values, value.name) {
				t.values[i] = value
			} else {
				t.values << value
			}
		}
		for f in node.input_fields {
			field := b.build_input_value(f)!
			if i := index_of_input(t.input_fields, field.name) {
				t.input_fields[i] = field
			} else {
				t.input_fields << field
			}
		}
	}
	if def.kind == .scalar {
		t.specified_by_url = specified_by_url(def.directives)
	}
	if def.kind == .input_object {
		t.is_one_of = def.directives.any(it.name.value == 'oneOf')
	}
	return t
}

fn replace_or_add_field(mut fields []FieldDef, field FieldDef) {
	for i, f in fields {
		if f.name == field.name {
			fields[i] = field
			return
		}
	}
	fields << field
}

fn index_of_value(values []EnumValueDef, name string) ?int {
	for i, v in values {
		if v.name == name {
			return i
		}
	}
	return none
}

fn index_of_input(values []InputValueDef, name string) ?int {
	for i, v in values {
		if v.name == name {
			return i
		}
	}
	return none
}

fn (mut b Builder) build_args(args []InputValueDefinition) ![]InputValueDef {
	mut out := []InputValueDef{}
	for a in args {
		arg := b.build_input_value(a)!
		if i := index_of_input(out, arg.name) {
			out[i] = arg
		} else {
			out << arg
		}
	}
	return out
}

fn (mut b Builder) build_input_value(v InputValueDefinition) !InputValueDef {
	return InputValueDef{
		name:               v.name.value
		description:        description_of(v.description)
		typ:                v.typ
		default_literal:    v.default_value
		deprecation_reason: deprecation_reason(v.directives)
		directives:         v.directives
		pos:                v.pos
	}
}

// coerce_default sets an input value's default from its literal, as
// `valueFromAST` coerces it: an invalid default is left unset.
fn (b &Builder) coerce_default(mut v InputValueDef) {
	if literal := v.default_literal {
		mut partial := Schema{
			types: b.all_types()
		}
		if value := partial.value_from_ast(literal, v.typ, map[string]Value{}) {
			v.default_value = value
		}
	}
}

fn (b &Builder) all_types() map[string]Type {
	mut out := b.std.clone()
	for name, t in b.built {
		out[name] = t
	}
	return out
}

fn (mut b Builder) build_directive(d DirectiveDefinition) !DirectiveDef {
	mut args := b.build_args(d.arguments)!
	for a in args {
		b.lookup(a.typ.named().name.value)!
	}
	mut partial := Schema{
		types: b.all_types()
	}
	for mut a in args {
		if literal := a.default_literal {
			if value := partial.value_from_ast(literal, a.typ, map[string]Value{}) {
				a.default_value = value
			}
		}
	}
	return DirectiveDef{
		name:        d.name.value
		description: description_of(d.description)
		args:        args
		repeatable:  d.repeatable
		locations:   d.locations.map(it.value)
		pos:         d.pos
	}
}

// deprecation_reason returns the reason of a `@deprecated` directive among
// `directives`: its `reason` argument, or the default reason. It is `none` when
// there is no `@deprecated`, or its reason is `null`.
fn deprecation_reason(directives []Directive) ?string {
	for d in directives {
		if d.name.value != 'deprecated' {
			continue
		}
		for a in d.arguments {
			if a.name.value == 'reason' {
				if a.value is StringValue {
					return a.value.value
				}
				return none
			}
		}
		return default_deprecation_reason
	}
	return none
}

fn specified_by_url(directives []Directive) ?string {
	for d in directives {
		if d.name.value != 'specifiedBy' {
			continue
		}
		for a in d.arguments {
			if a.name.value == 'url' && a.value is StringValue {
				return a.value.value
			}
		}
	}
	return none
}
