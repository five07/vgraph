module graphql

// Node is any node the validation walker visits.
pub type Node = Argument
	| BooleanValue
	| Directive
	| DirectiveDefinition
	| Document
	| EnumValue
	| EnumValueDefinition
	| Field
	| FieldDefinition
	| FloatValue
	| FragmentDefinition
	| FragmentSpread
	| InlineFragment
	| InputValueDefinition
	| IntValue
	| ListType
	| ListValue
	| NamedType
	| NonNullType
	| NullValue
	| ObjectField
	| ObjectValue
	| OperationDefinition
	| OperationTypeDefinition
	| SchemaDefinition
	| SelectionSet
	| StringValue
	| TypeDefinition
	| Variable
	| VariableDefinition

// Rule is a validation rule. The walker calls `enter` before a node's children
// and `leave` after them; `enter` returning false skips the node's children,
// and its `leave`, for this rule only, as in graphql-js.
interface Rule {
mut:
	enter(mut c ValidationContext, w &Walker, node Node) bool
	leave(mut c ValidationContext, w &Walker, node Node)
}

// ValidateOptions configures `validate`.
@[params]
pub struct ValidateOptions {
pub:
	// rules are the names of the rules to run; empty runs `specified_rules`.
	rules []string
	// max_errors stops validation after this many errors.
	max_errors int = 100
	// max_depth rejects operations whose fields nest deeper than this, counting
	// through fragments; 0 is no limit.
	max_depth int
	// max_selections rejects operations that select more fields than this in all,
	// counting a fragment once per spread; 0 is no limit.
	max_selections int
	// no_introspection rejects queries of the introspection types.
	no_introspection bool
}

// specified_rules are the rules of the spec, in graphql-js's order, with its
// recommended `MaxIntrospectionDepthRule`.
pub const specified_rules = ['ExecutableDefinitionsRule', 'UniqueOperationNamesRule',
	'LoneAnonymousOperationRule', 'SingleFieldSubscriptionsRule', 'KnownTypeNamesRule',
	'FragmentsOnCompositeTypesRule', 'VariablesAreInputTypesRule', 'ScalarLeafsRule',
	'FieldsOnCorrectTypeRule', 'UniqueFragmentNamesRule', 'KnownFragmentNamesRule',
	'NoUnusedFragmentsRule', 'PossibleFragmentSpreadsRule', 'NoFragmentCyclesRule',
	'UniqueVariableNamesRule', 'NoUndefinedVariablesRule', 'NoUnusedVariablesRule',
	'KnownDirectivesRule', 'UniqueDirectivesPerLocationRule', 'KnownArgumentNamesRule',
	'UniqueArgumentNamesRule', 'ValuesOfCorrectTypeRule', 'ProvidedRequiredArgumentsRule',
	'VariablesInAllowedPositionRule', 'OverlappingFieldsCanBeMergedRule', 'UniqueInputFieldNamesRule',
	'MaxIntrospectionDepthRule']

// specified_sdl_rules are the rules graphql-js checks SDL with.
pub const specified_sdl_rules = ['LoneSchemaDefinitionRule', 'UniqueOperationTypesRule',
	'UniqueTypeNamesRule', 'UniqueEnumValueNamesRule', 'UniqueFieldDefinitionNamesRule',
	'UniqueArgumentDefinitionNamesRule', 'UniqueDirectiveNamesRule', 'KnownTypeNamesRule',
	'KnownDirectivesRule', 'UniqueDirectivesPerLocationRule', 'PossibleTypeExtensionsRule',
	'KnownArgumentNamesOnDirectivesRule', 'UniqueArgumentNamesRule', 'UniqueInputFieldNamesRule',
	'ProvidedRequiredArgumentsOnDirectivesRule']

// validate checks an executable document against the schema, and returns every
// error, as graphql-js's `validate` does.
pub fn validate(schema &Schema, doc &Document, opts ValidateOptions) []GraphQLError {
	mut c := ValidationContext{
		schema:     schema
		has_schema: true
		doc:        doc
		max_errors: opts.max_errors
	}
	names := if opts.rules.len > 0 { opts.rules } else { specified_rules }
	mut rules := []Rule{}
	for name in names {
		rules << new_rule(name, mut c) or { continue }
	}
	if opts.no_introspection {
		rules << Rule(NoSchemaIntrospectionRule{})
	}
	if opts.max_depth > 0 || opts.max_selections > 0 {
		rules << Rule(MaxComplexityRule{
			max_depth:      opts.max_depth
			max_selections: opts.max_selections
		})
	}
	c.run(mut rules)
	return c.errors
}

// validate_sdl checks an SDL document, optionally one that extends `schema`,
// with graphql-js's SDL rules.
pub fn validate_sdl(doc Document, schema ?Schema) []GraphQLError {
	existing := schema or { Schema{} }
	mut c := ValidationContext{
		schema:     &existing
		has_schema: schema != none
		doc:        &doc
		max_errors: max_int
	}
	return c.validate_sdl_rules(specified_sdl_rules)
}

fn (mut c ValidationContext) validate_sdl_rules(names []string) []GraphQLError {
	mut rules := []Rule{}
	for name in names {
		rules << new_sdl_rule(name, mut c) or { continue }
	}
	c.run(mut rules)
	return c.errors
}

// ValidationContext is what rules see: the schema, the document, the errors so
// far, and lookups they share.
pub struct ValidationContext {
pub:
	schema     &Schema
	has_schema bool // false while checking SDL that doesn't extend a schema
	doc        &Document
	max_errors int
mut:
	errors          []GraphQLError
	aborted         bool
	fragments       map[string]FragmentDefinition
	fragments_ready bool
	spreads         map[int][]FragmentSpread
	usages          map[int][]VariableUsage
}

// report adds an error located at the byte offsets `positions`.
pub fn (mut c ValidationContext) report(message string, positions []int) {
	if c.aborted {
		return
	}
	if c.errors.len >= c.max_errors {
		c.errors << GraphQLError{
			message: 'Too many validation errors, error limit reached. Validation aborted.'
		}
		c.aborted = true
		return
	}
	c.errors << GraphQLError{
		message:   message
		locations: positions.map(c.doc.location(it))
	}
}

fn (mut c ValidationContext) run(mut rules []Rule) {
	mut w := Walker{
		info:  TypeInfo{
			schema: c.schema
		}
		rules: rules
		skip:  []int{len: rules.len, init: -1}
	}
	w.walk(mut c, Node(*c.doc))
}

// fragment returns the fragment definition `name`.
pub fn (mut c ValidationContext) fragment(name string) ?FragmentDefinition {
	if !c.fragments_ready {
		for def in c.doc.definitions {
			if def is FragmentDefinition {
				c.fragments[def.name.value] = def
			}
		}
		c.fragments_ready = true
	}
	return c.fragments[name] or { return none }
}

// fragment_spreads returns the fragment spreads in a selection set, not
// following fragments, in graphql-js's order.
pub fn (mut c ValidationContext) fragment_spreads(set SelectionSet) []FragmentSpread {
	if cached := c.spreads[set.pos] {
		return cached
	}
	mut spreads := []FragmentSpread{}
	mut to_visit := [set]
	for to_visit.len > 0 {
		s := to_visit.pop()
		for sel in s.selections {
			match sel {
				FragmentSpread {
					spreads << sel
				}
				Field {
					if sub := sel.selection_set {
						to_visit << sub
					}
				}
				InlineFragment {
					to_visit << sel.selection_set
				}
			}
		}
	}
	c.spreads[set.pos] = spreads
	return spreads
}

// recursively_referenced_fragments returns the fragments an operation uses,
// directly or through other fragments.
pub fn (mut c ValidationContext) recursively_referenced_fragments(op OperationDefinition) []FragmentDefinition {
	mut fragments := []FragmentDefinition{}
	mut collected := map[string]bool{}
	mut to_visit := [op.selection_set]
	for to_visit.len > 0 {
		set := to_visit.pop()
		for spread in c.fragment_spreads(set) {
			name := spread.name.value
			if name !in collected {
				collected[name] = true
				if fragment := c.fragment(name) {
					fragments << fragment
					to_visit << fragment.selection_set
				}
			}
		}
	}
	return fragments
}

// VariableUsage is a variable used in a document, with the input type expected
// where it is used, the default value there, and the parent input type.
pub struct VariableUsage {
pub:
	node          Variable
	typ           ?TypeNode
	default_value ?Value
	parent_type   ?TypeNode
}

// variable_usages returns the variables used in an operation or a fragment,
// not following fragment spreads.
pub fn (mut c ValidationContext) variable_usages(node Node, key int) []VariableUsage {
	if cached := c.usages[key] {
		return cached
	}
	mut collector := VariableUsageCollector{}
	mut rules := [Rule(collector)]
	mut w := Walker{
		info:  TypeInfo{
			schema: c.schema
		}
		rules: rules
		skip:  [-1]
	}
	w.walk(mut c, node)
	found := (w.rules[0] as VariableUsageCollector).usages
	c.usages[key] = found
	return found
}

// recursive_variable_usages returns the variables used in an operation and the
// fragments it uses.
pub fn (mut c ValidationContext) recursive_variable_usages(op OperationDefinition) []VariableUsage {
	mut usages := c.variable_usages(Node(op), op.pos).clone()
	for frag in c.recursively_referenced_fragments(op) {
		usages << c.variable_usages(Node(frag), frag.pos)
	}
	return usages
}

struct VariableUsageCollector {
mut:
	usages []VariableUsage
}

fn (mut r VariableUsageCollector) enter(mut _ ValidationContext, w &Walker, node Node) bool {
	if node is VariableDefinition {
		return false
	}
	if node is Variable {
		r.usages << VariableUsage{
			node:          node
			typ:           w.info.input_type()
			default_value: w.info.default_value()
			parent_type:   w.info.parent_input_type()
		}
	}
	return true
}

fn (mut r VariableUsageCollector) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// Walker visits a document in graphql-js's order, keeping type information, and
// calls every rule at each node.
pub struct Walker {
pub mut:
	info      TypeInfo
	ancestors []Node // the nodes above the current one, outermost first
mut:
	rules []Rule
	skip  []int // per rule: the depth of the node whose children it skips, or -1
	depth int
}

fn (mut w Walker) walk(mut c ValidationContext, node Node) {
	if c.aborted {
		return
	}
	w.info.enter(node)
	w.depth++
	for i, mut rule in w.rules {
		if w.skip[i] < 0 {
			if !rule.enter(mut c, w, node) {
				w.skip[i] = w.depth
			}
		}
	}
	w.ancestors << node
	w.children(mut c, node)
	w.ancestors.pop()
	for i, mut rule in w.rules {
		if w.skip[i] < 0 {
			rule.leave(mut c, w, node)
		} else if w.skip[i] == w.depth {
			w.skip[i] = -1
		}
	}
	w.depth--
	w.info.leave(node)
}

fn (mut w Walker) walk_type(mut c ValidationContext, t TypeNode) {
	match t {
		NamedType { w.walk(mut c, Node(t)) }
		ListType { w.walk(mut c, Node(t)) }
		NonNullType { w.walk(mut c, Node(t)) }
	}
}

fn (mut w Walker) walk_value(mut c ValidationContext, v ValueNode) {
	match v {
		Variable { w.walk(mut c, Node(v)) }
		IntValue { w.walk(mut c, Node(v)) }
		FloatValue { w.walk(mut c, Node(v)) }
		StringValue { w.walk(mut c, Node(v)) }
		BooleanValue { w.walk(mut c, Node(v)) }
		NullValue { w.walk(mut c, Node(v)) }
		EnumValue { w.walk(mut c, Node(v)) }
		ListValue { w.walk(mut c, Node(v)) }
		ObjectValue { w.walk(mut c, Node(v)) }
	}
}

fn (mut w Walker) walk_directives(mut c ValidationContext, directives []Directive) {
	for d in directives {
		w.walk(mut c, Node(d))
	}
}

fn (mut w Walker) walk_selection_set(mut c ValidationContext, set SelectionSet) {
	w.walk(mut c, Node(set))
}

// children visits a node's children, in the order of graphql-js's
// `QueryDocumentKeys`, leaving out descriptions and names.
fn (mut w Walker) children(mut c ValidationContext, node Node) {
	match node {
		Document {
			for def in node.definitions {
				match def {
					OperationDefinition { w.walk(mut c, Node(def)) }
					FragmentDefinition { w.walk(mut c, Node(def)) }
					SchemaDefinition { w.walk(mut c, Node(def)) }
					TypeDefinition { w.walk(mut c, Node(def)) }
					DirectiveDefinition { w.walk(mut c, Node(def)) }
				}
			}
		}
		OperationDefinition {
			for v in node.variable_definitions {
				w.walk(mut c, Node(v))
			}
			w.walk_directives(mut c, node.directives)
			w.walk_selection_set(mut c, node.selection_set)
		}
		VariableDefinition {
			w.walk(mut c, Node(node.variable))
			w.walk_type(mut c, node.typ)
			if d := node.default_value {
				w.walk_value(mut c, d)
			}
			w.walk_directives(mut c, node.directives)
		}
		SelectionSet {
			for sel in node.selections {
				match sel {
					Field { w.walk(mut c, Node(sel)) }
					FragmentSpread { w.walk(mut c, Node(sel)) }
					InlineFragment { w.walk(mut c, Node(sel)) }
				}
			}
		}
		Field {
			for a in node.arguments {
				w.walk(mut c, Node(a))
			}
			w.walk_directives(mut c, node.directives)
			if set := node.selection_set {
				w.walk_selection_set(mut c, set)
			}
		}
		Argument {
			w.walk_value(mut c, node.value)
		}
		FragmentSpread {
			w.walk_directives(mut c, node.directives)
		}
		InlineFragment {
			if t := node.type_condition {
				w.walk(mut c, Node(t))
			}
			w.walk_directives(mut c, node.directives)
			w.walk_selection_set(mut c, node.selection_set)
		}
		FragmentDefinition {
			w.walk(mut c, Node(node.type_condition))
			w.walk_directives(mut c, node.directives)
			w.walk_selection_set(mut c, node.selection_set)
		}
		ListValue {
			for v in node.values {
				w.walk_value(mut c, v)
			}
		}
		ObjectValue {
			for f in node.fields {
				w.walk(mut c, Node(f))
			}
		}
		ObjectField {
			w.walk_value(mut c, node.value)
		}
		Directive {
			for a in node.arguments {
				w.walk(mut c, Node(a))
			}
		}
		ListType {
			w.walk_type(mut c, node.typ)
		}
		NonNullType {
			w.walk_type(mut c, node.typ)
		}
		SchemaDefinition {
			w.walk_directives(mut c, node.directives)
			for op in node.operation_types {
				w.walk(mut c, Node(op))
			}
		}
		OperationTypeDefinition {
			w.walk(mut c, Node(node.typ))
		}
		TypeDefinition {
			for i in node.interfaces {
				w.walk(mut c, Node(i))
			}
			w.walk_directives(mut c, node.directives)
			for f in node.fields {
				w.walk(mut c, Node(f))
			}
			for t in node.types {
				w.walk(mut c, Node(t))
			}
			for v in node.values {
				w.walk(mut c, Node(v))
			}
			for f in node.input_fields {
				w.walk(mut c, Node(f))
			}
		}
		FieldDefinition {
			for a in node.arguments {
				w.walk(mut c, Node(a))
			}
			w.walk_type(mut c, node.typ)
			w.walk_directives(mut c, node.directives)
		}
		InputValueDefinition {
			w.walk_type(mut c, node.typ)
			if d := node.default_value {
				w.walk_value(mut c, d)
			}
			w.walk_directives(mut c, node.directives)
		}
		EnumValueDefinition {
			w.walk_directives(mut c, node.directives)
		}
		DirectiveDefinition {
			for a in node.arguments {
				w.walk(mut c, Node(a))
			}
		}
		else {}
	}
}

// parent returns the node above the current one.
pub fn (w &Walker) parent() ?Node {
	if w.ancestors.len == 0 {
		return none
	}
	return w.ancestors.last()
}

// TypeInfo tracks the types at the current position of a walk, as graphql-js's
// `TypeInfo` does: `none` wherever the document doesn't match the schema.
pub struct TypeInfo {
	schema &Schema
mut:
	type_stack          []MaybeType
	parent_type_stack   []string // '' where there is no composite parent type
	input_type_stack    []MaybeType
	field_def_stack     []MaybeField
	default_value_stack []MaybeValue
	directive           ?DirectiveDef
	argument            ?InputValueDef
	enum_value          ?EnumValueDef
}

struct MaybeType {
	t  TypeNode
	ok bool
}

struct MaybeField {
	f  FieldDef
	ok bool
}

struct MaybeValue {
	v  Value
	ok bool
}

fn some_type(t TypeNode) MaybeType {
	return MaybeType{
		t:  t
		ok: true
	}
}

// typ returns the output type at the current position.
pub fn (i &TypeInfo) typ() ?TypeNode {
	if i.type_stack.len > 0 && i.type_stack.last().ok {
		return i.type_stack.last().t
	}
	return none
}

// parent_type returns the name of the composite type whose selection set holds
// the current position.
pub fn (i &TypeInfo) parent_type() ?Type {
	if i.parent_type_stack.len > 0 && i.parent_type_stack.last() != '' {
		return i.schema.get_type(i.parent_type_stack.last())
	}
	return none
}

// input_type returns the input type expected at the current position.
pub fn (i &TypeInfo) input_type() ?TypeNode {
	if i.input_type_stack.len > 0 && i.input_type_stack.last().ok {
		return i.input_type_stack.last().t
	}
	return none
}

// parent_input_type returns the input type around the current one.
pub fn (i &TypeInfo) parent_input_type() ?TypeNode {
	if i.input_type_stack.len > 1 && i.input_type_stack[i.input_type_stack.len - 2].ok {
		return i.input_type_stack[i.input_type_stack.len - 2].t
	}
	return none
}

// field_def returns the definition of the current field.
pub fn (i &TypeInfo) field_def() ?FieldDef {
	if i.field_def_stack.len > 0 && i.field_def_stack.last().ok {
		return i.field_def_stack.last().f
	}
	return none
}

// default_value returns the default value at the current input position.
pub fn (i &TypeInfo) default_value() ?Value {
	if i.default_value_stack.len > 0 && i.default_value_stack.last().ok {
		return i.default_value_stack.last().v
	}
	return none
}

// get_directive returns the definition of the current directive.
pub fn (i &TypeInfo) get_directive() ?DirectiveDef {
	return i.directive
}

// get_argument returns the definition of the current argument.
pub fn (i &TypeInfo) get_argument() ?InputValueDef {
	return i.argument
}

// get_enum_value returns the definition of the current enum value.
pub fn (i &TypeInfo) get_enum_value() ?EnumValueDef {
	return i.enum_value
}

// type_from_ast returns `t` when its named type exists in the schema.
fn (s &Schema) type_from_ast(t TypeNode) ?TypeNode {
	s.get_type(t.named().name.value)?
	return t
}

fn (s &Schema) is_output(t TypeNode) bool {
	named := s.named_type(t) or { return false }
	return named.is_output()
}

fn (s &Schema) is_input_type(t TypeNode) bool {
	named := s.named_type(t) or { return false }
	return named.is_input()
}

fn (s &Schema) is_composite_named(name string) bool {
	t := s.get_type(name) or { return false }
	return t.is_composite()
}

const schema_meta_field = FieldDef{
	name:        '__schema'
	description: 'Access the current type schema of this server.'
	typ:         NonNullType{
		typ: NamedType{
			name: Name{
				value: '__Schema'
			}
		}
	}
}

const type_meta_field = FieldDef{
	name:        '__type'
	description: 'Request the type information of a single type.'
	args:        [
		InputValueDef{
			name: 'name'
			typ:  NonNullType{
				typ: NamedType{
					name: Name{
						value: 'String'
					}
				}
			}
		},
	]
	typ:         NamedType{
		name: Name{
			value: '__Type'
		}
	}
}

const typename_meta_field = FieldDef{
	name:        '__typename'
	description: 'The name of the current Object type at runtime.'
	typ:         NonNullType{
		typ: NamedType{
			name: Name{
				value: 'String'
			}
		}
	}
}

// field_def returns the definition of the field `name` on the type `parent`,
// including the meta fields `__schema` and `__type` on the query type and
// `__typename` on any composite type.
pub fn (s &Schema) field_def(parent Type, name string) ?FieldDef {
	if name == '__schema' && s.query or { '' } == parent.name {
		return schema_meta_field
	}
	if name == '__type' && s.query or { '' } == parent.name {
		return type_meta_field
	}
	if name == '__typename' && parent.is_composite() {
		return typename_meta_field
	}
	if parent.kind in [.object, .@interface] {
		return parent.field(name)
	}
	return none
}

fn (mut i TypeInfo) enter(node Node) {
	s := i.schema
	match node {
		SelectionSet {
			mut name := ''
			if t := i.typ() {
				n := t.named().name.value
				if s.is_composite_named(n) {
					name = n
				}
			}
			i.parent_type_stack << name
		}
		Field {
			mut field := MaybeField{}
			mut typ := MaybeType{}
			if parent := i.parent_type() {
				if f := s.field_def(parent, node.name.value) {
					field = MaybeField{
						f:  f
						ok: true
					}
					if s.is_output(f.typ) {
						typ = some_type(f.typ)
					}
				}
			}
			i.field_def_stack << field
			i.type_stack << typ
		}
		Directive {
			i.directive = s.get_directive(node.name.value)
		}
		OperationDefinition {
			mut typ := MaybeType{}
			if root := s.root_type(node.operation) {
				if t := s.get_type(root) {
					if t.kind == .object {
						typ = some_type(NamedType{
							name: Name{
								value: root
							}
						})
					}
				}
			}
			i.type_stack << typ
		}
		InlineFragment {
			i.type_stack << i.fragment_type(node.type_condition)
		}
		FragmentDefinition {
			i.type_stack << i.fragment_type(node.type_condition)
		}
		VariableDefinition {
			i.input_type_stack << if s.is_input_type(node.typ) {
				some_type(node.typ)
			} else {
				MaybeType{}
			}
		}
		Argument {
			mut arg := ?InputValueDef(none)
			mut args := []InputValueDef{}
			mut has := false
			if d := i.directive {
				args = d.args
				has = true
			} else if f := i.field_def() {
				args = f.args
				has = true
			}
			if has {
				for a in args {
					if a.name == node.name.value {
						arg = a
						break
					}
				}
			}
			i.argument = arg
			mut default := MaybeValue{}
			mut typ := MaybeType{}
			if a := arg {
				if d := a.default_value {
					default = MaybeValue{
						v:  d
						ok: true
					}
				}
				if s.is_input_type(a.typ) {
					typ = some_type(a.typ)
				}
			}
			i.default_value_stack << default
			i.input_type_stack << typ
		}
		ListValue {
			mut typ := MaybeType{}
			if t := i.input_type() {
				outer := nullable(t)
				item := if outer is ListType { outer.typ } else { outer }
				if s.is_input_type(item) {
					typ = some_type(item)
				}
			}
			i.default_value_stack << MaybeValue{}
			i.input_type_stack << typ
		}
		ObjectField {
			mut typ := MaybeType{}
			mut default := MaybeValue{}
			if t := i.input_type() {
				if obj := s.named_type(t) {
					if obj.kind == .input_object {
						if f := obj.input_field(node.name.value) {
							if d := f.default_value {
								default = MaybeValue{
									v:  d
									ok: true
								}
							}
							if s.is_input_type(f.typ) {
								typ = some_type(f.typ)
							}
						}
					}
				}
			}
			i.default_value_stack << default
			i.input_type_stack << typ
		}
		EnumValue {
			mut value := ?EnumValueDef(none)
			if t := i.input_type() {
				if e := s.named_type(t) {
					if e.kind == .@enum {
						value = e.enum_value(node.value)
					}
				}
			}
			i.enum_value = value
		}
		else {}
	}
}

// fragment_type is the type inside a fragment: its type condition, or for an
// inline fragment without one, the type around it.
fn (i &TypeInfo) fragment_type(condition ?NamedType) MaybeType {
	s := i.schema
	if cond := condition {
		if s.is_output(cond) {
			return some_type(cond)
		}
		return MaybeType{}
	}
	if t := i.typ() {
		named := t.named()
		if s.is_output(named) {
			return some_type(named)
		}
	}
	return MaybeType{}
}

fn (mut i TypeInfo) leave(node Node) {
	match node {
		SelectionSet {
			i.parent_type_stack.pop()
		}
		Field {
			i.field_def_stack.pop()
			i.type_stack.pop()
		}
		Directive {
			i.directive = none
		}
		OperationDefinition, InlineFragment, FragmentDefinition {
			i.type_stack.pop()
		}
		VariableDefinition {
			i.input_type_stack.pop()
		}
		Argument {
			i.argument = none
			i.default_value_stack.pop()
			i.input_type_stack.pop()
		}
		ListValue, ObjectField {
			i.default_value_stack.pop()
			i.input_type_stack.pop()
		}
		EnumValue {
			i.enum_value = none
		}
		else {}
	}
}
