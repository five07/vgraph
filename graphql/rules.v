module graphql

// The validation rules for executable documents, ported from graphql-js with
// its messages. Each is a struct holding the rule's state; see `Rule`.

fn new_rule(name string, mut c ValidationContext) ?Rule {
	return match name {
		'ExecutableDefinitionsRule' { Rule(ExecutableDefinitionsRule{}) }
		'UniqueOperationNamesRule' { Rule(UniqueOperationNamesRule{}) }
		'LoneAnonymousOperationRule' { Rule(LoneAnonymousOperationRule{}) }
		'SingleFieldSubscriptionsRule' { Rule(SingleFieldSubscriptionsRule{}) }
		'KnownTypeNamesRule' { Rule(new_known_type_names(c)) }
		'FragmentsOnCompositeTypesRule' { Rule(FragmentsOnCompositeTypesRule{}) }
		'VariablesAreInputTypesRule' { Rule(VariablesAreInputTypesRule{}) }
		'ScalarLeafsRule' { Rule(ScalarLeafsRule{}) }
		'FieldsOnCorrectTypeRule' { Rule(FieldsOnCorrectTypeRule{}) }
		'UniqueFragmentNamesRule' { Rule(UniqueFragmentNamesRule{}) }
		'KnownFragmentNamesRule' { Rule(KnownFragmentNamesRule{}) }
		'NoUnusedFragmentsRule' { Rule(NoUnusedFragmentsRule{}) }
		'PossibleFragmentSpreadsRule' { Rule(PossibleFragmentSpreadsRule{}) }
		'NoFragmentCyclesRule' { Rule(NoFragmentCyclesRule{}) }
		'UniqueVariableNamesRule' { Rule(UniqueVariableNamesRule{}) }
		'NoUndefinedVariablesRule' { Rule(NoUndefinedVariablesRule{}) }
		'NoUnusedVariablesRule' { Rule(NoUnusedVariablesRule{}) }
		'KnownDirectivesRule' { Rule(new_known_directives(c)) }
		'UniqueDirectivesPerLocationRule' { Rule(new_unique_directives_per_location(c)) }
		'KnownArgumentNamesRule' { Rule(new_known_argument_names(c, true)) }
		'UniqueArgumentNamesRule' { Rule(UniqueArgumentNamesRule{}) }
		'ValuesOfCorrectTypeRule' { Rule(ValuesOfCorrectTypeRule{}) }
		'ProvidedRequiredArgumentsRule' { Rule(new_provided_required_arguments(c, true)) }
		'VariablesInAllowedPositionRule' { Rule(VariablesInAllowedPositionRule{}) }
		'OverlappingFieldsCanBeMergedRule' { Rule(OverlappingFieldsCanBeMergedRule{}) }
		'UniqueInputFieldNamesRule' { Rule(UniqueInputFieldNamesRule{}) }
		'MaxIntrospectionDepthRule' { Rule(MaxIntrospectionDepthRule{}) }
		'NoDeprecatedCustomRule' { Rule(NoDeprecatedCustomRule{}) }
		'NoSchemaIntrospectionCustomRule' { Rule(NoSchemaIntrospectionRule{}) }
		else { none }
	}
}

// --- ExecutableDefinitionsRule

struct ExecutableDefinitionsRule {}

fn (mut r ExecutableDefinitionsRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is Document {
		for def in node.definitions {
			name := match def {
				OperationDefinition, FragmentDefinition { continue }
				SchemaDefinition { 'schema' }
				TypeDefinition { '"${def.name.value}"' }
				DirectiveDefinition { '"${def.name.value}"' }
			}
			c.report('The ${name} definition is not executable.', [def.pos()])
		}
		return false
	}
	return true
}

fn (mut r ExecutableDefinitionsRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- UniqueOperationNamesRule

struct UniqueOperationNamesRule {
mut:
	known map[string]int
}

fn (mut r UniqueOperationNamesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	match node {
		OperationDefinition {
			if name := node.name {
				if first := r.known[name.value] {
					c.report('There can be only one operation named "${name.value}".', [
						first,
						name.pos,
					])
				} else {
					r.known[name.value] = name.pos
				}
			}
			return false
		}
		FragmentDefinition {
			return false
		}
		else {
			return true
		}
	}
}

fn (mut r UniqueOperationNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- LoneAnonymousOperationRule

struct LoneAnonymousOperationRule {
mut:
	count int
}

fn (mut r LoneAnonymousOperationRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is Document {
		r.count = node.definitions.filter(it is OperationDefinition).len
	} else if node is OperationDefinition {
		if node.name == none && r.count > 1 {
			c.report('This anonymous operation must be the only defined operation.', [
				node.pos,
			])
		}
	}
	return true
}

fn (mut r LoneAnonymousOperationRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- SingleFieldSubscriptionsRule

struct SingleFieldSubscriptionsRule {}

fn (mut r SingleFieldSubscriptionsRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is OperationDefinition {
		if node.operation != .subscription {
			return true
		}
		subscription := c.schema.subscription or { return true }
		mut fragments := map[string]FragmentDefinition{}
		for def in c.doc.definitions {
			if def is FragmentDefinition {
				fragments[def.name.value] = def
			}
		}
		groups := c.schema.collect_fields(fragments, map[string]Value{}, subscription,
			node.selection_set)
		name := node.name or { Name{} }.value
		if groups.len > 1 {
			mut extra := []int{}
			for g in groups[1..] {
				extra << g.fields.map(it.pos)
			}
			c.report(if name != '' {
				'Subscription "${name}" must select only one top level field.'
			} else {
				'Anonymous Subscription must select only one top level field.'
			}, extra)
		}
		for g in groups {
			if g.fields[0].name.value.starts_with('__') {
				c.report(if name != '' {
					'Subscription "${name}" must not select an introspection top level field.'
				} else {
					'Anonymous Subscription must not select an introspection top level field.'
				}, g.fields.map(it.pos))
			}
		}
	}
	return true
}

fn (mut r SingleFieldSubscriptionsRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- KnownTypeNamesRule

const standard_type_names = ['String', 'Int', 'Float', 'Boolean', 'ID', '__Schema', '__Directive',
	'__DirectiveLocation', '__Type', '__Field', '__InputValue', '__EnumValue', '__TypeKind']

struct KnownTypeNamesRule {
	existing map[string]bool
	defined  map[string]bool
	names    []string
}

fn new_known_type_names(c &ValidationContext) KnownTypeNamesRule {
	mut existing := map[string]bool{}
	mut names := []string{}
	if c.has_schema {
		for name in c.schema.type_names {
			existing[name] = true
			names << name
		}
	}
	mut defined := map[string]bool{}
	for def in c.doc.definitions {
		if def is TypeDefinition && !def.is_extension {
			defined[def.name.value] = true
		}
	}
	for def in c.doc.definitions {
		if def is TypeDefinition && !def.is_extension {
			names << def.name.value
		}
	}
	return KnownTypeNamesRule{
		existing: existing
		defined:  defined
		names:    names
	}
}

fn is_sdl_node(n Node) bool {
	return n is SchemaDefinition || n is TypeDefinition || n is DirectiveDefinition
}

fn (mut r KnownTypeNamesRule) enter(mut c ValidationContext, w &Walker, node Node) bool {
	if node is NamedType {
		name := node.name.value
		if name in r.existing || name in r.defined {
			return true
		}
		mut is_sdl := false
		if w.ancestors.len > 1 {
			is_sdl = is_sdl_node(w.ancestors[1])
		} else if p := w.parent() {
			is_sdl = is_sdl_node(p)
		}
		if is_sdl && name in standard_type_names {
			return true
		}
		mut options := []string{}
		if is_sdl {
			options << standard_type_names
		}
		options << r.names
		c.report('Unknown type "${name}".' + did_you_mean('', suggestion_list(name, options)),
			[node.pos])
	}
	return true
}

fn (mut r KnownTypeNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- FragmentsOnCompositeTypesRule

struct FragmentsOnCompositeTypesRule {}

fn (mut r FragmentsOnCompositeTypesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is InlineFragment {
		if cond := node.type_condition {
			if t := c.schema.get_type(cond.name.value) {
				if !t.is_composite() {
					c.report('Fragment cannot condition on non composite type "${cond.name.value}".',
						[cond.pos])
				}
			}
		}
	} else if node is FragmentDefinition {
		cond := node.type_condition
		if t := c.schema.get_type(cond.name.value) {
			if !t.is_composite() {
				c.report('Fragment "${node.name.value}" cannot condition on non composite type "${cond.name.value}".',
					[cond.pos])
			}
		}
	}
	return true
}

fn (mut r FragmentsOnCompositeTypesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- VariablesAreInputTypesRule

struct VariablesAreInputTypesRule {}

fn (mut r VariablesAreInputTypesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is VariableDefinition {
		if t := c.schema.named_type(node.typ) {
			if !t.is_input() {
				c.report('Variable "$${node.variable.name.value}" cannot be non-input type "${print_type(node.typ)}".',
					[node.typ.pos()])
			}
		}
	}
	return true
}

fn (mut r VariablesAreInputTypesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- ScalarLeafsRule

struct ScalarLeafsRule {}

fn (mut r ScalarLeafsRule) enter(mut c ValidationContext, w &Walker, node Node) bool {
	if node is Field {
		t := w.info.typ() or { return true }
		named := c.schema.named_type(t) or { return true }
		name := node.name.value
		type_str := print_type(t)
		if named.is_leaf() {
			if set := node.selection_set {
				c.report('Field "${name}" must not have a selection since type "${type_str}" has no subfields.',
					[set.pos])
			}
		} else if set := node.selection_set {
			if set.selections.len == 0 {
				c.report('Field "${name}" of type "${type_str}" must have at least one field selected.',
					[node.pos])
			}
		} else {
			c.report('Field "${name}" of type "${type_str}" must have a selection of subfields. Did you mean "${name} { ... }"?',
				[node.pos])
		}
	}
	return true
}

fn (mut r ScalarLeafsRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- FieldsOnCorrectTypeRule

struct FieldsOnCorrectTypeRule {}

fn (mut r FieldsOnCorrectTypeRule) enter(mut c ValidationContext, w &Walker, node Node) bool {
	if node is Field {
		parent := w.info.parent_type() or { return true }
		if _ := w.info.field_def() {
			return true
		}
		name := node.name.value
		mut suggestion := did_you_mean('to use an inline fragment on', suggested_type_names(c.schema,
			parent, name))
		if suggestion == '' {
			suggestion = did_you_mean('', suggested_field_names(parent, name))
		}
		c.report('Cannot query field "${name}" on type "${parent.name}".' + suggestion, [
			node.pos,
		])
	}
	return true
}

fn (mut r FieldsOnCorrectTypeRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

fn suggested_type_names(s &Schema, t Type, field_name string) []string {
	if !t.is_abstract() {
		return []
	}
	mut suggested := []string{}
	mut usage := map[string]int{}
	for possible_name in s.possible_types(t.name) {
		possible := s.get_type(possible_name) or { continue }
		if _ := possible.field(field_name) {
		} else {
			continue
		}
		if possible_name !in usage {
			suggested << possible_name
		}
		usage[possible_name] = 1
		for iface_name in possible.interfaces {
			iface := s.get_type(iface_name) or { continue }
			if _ := iface.field(field_name) {
			} else {
				continue
			}
			if iface_name !in usage {
				suggested << iface_name
			}
			usage[iface_name] = (usage[iface_name] or { 0 }) + 1
		}
	}
	suggested.sort_with_compare(fn [usage, s] (a &string, b &string) int {
		diff := usage[*b] - usage[*a]
		if diff != 0 {
			return diff
		}
		ta := s.get_type(*a) or { Type{} }
		tb := s.get_type(*b) or { Type{} }
		if ta.kind == .@interface && s.is_sub_type(*a, *b) {
			return -1
		}
		if tb.kind == .@interface && s.is_sub_type(*b, *a) {
			return 1
		}
		return natural_compare(*a, *b)
	})
	return suggested
}

fn suggested_field_names(t Type, field_name string) []string {
	if t.kind in [.object, .@interface] {
		return suggestion_list(field_name, t.fields.map(it.name))
	}
	return []
}

// --- UniqueFragmentNamesRule

struct UniqueFragmentNamesRule {
mut:
	known map[string]int
}

fn (mut r UniqueFragmentNamesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	match node {
		OperationDefinition {
			return false
		}
		FragmentDefinition {
			name := node.name.value
			if first := r.known[name] {
				c.report('There can be only one fragment named "${name}".', [first, node.name.pos])
			} else {
				r.known[name] = node.name.pos
			}
			return false
		}
		else {
			return true
		}
	}
}

fn (mut r UniqueFragmentNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- KnownFragmentNamesRule

struct KnownFragmentNamesRule {}

fn (mut r KnownFragmentNamesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is FragmentSpread {
		if _ := c.fragment(node.name.value) {
		} else {
			c.report('Unknown fragment "${node.name.value}".', [node.name.pos])
		}
	}
	return true
}

fn (mut r KnownFragmentNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- NoUnusedFragmentsRule

struct NoUnusedFragmentsRule {
mut:
	operations []OperationDefinition
	fragments  []FragmentDefinition
}

fn (mut r NoUnusedFragmentsRule) enter(mut _ ValidationContext, _ &Walker, node Node) bool {
	match node {
		OperationDefinition {
			r.operations << node
			return false
		}
		FragmentDefinition {
			r.fragments << node
			return false
		}
		else {
			return true
		}
	}
}

fn (mut r NoUnusedFragmentsRule) leave(mut c ValidationContext, _ &Walker, node Node) {
	if node is Document {
		mut used := map[string]bool{}
		for op in r.operations {
			for f in c.recursively_referenced_fragments(op) {
				used[f.name.value] = true
			}
		}
		for f in r.fragments {
			if f.name.value !in used {
				c.report('Fragment "${f.name.value}" is never used.', [f.pos])
			}
		}
	}
}

// --- PossibleFragmentSpreadsRule

struct PossibleFragmentSpreadsRule {}

fn (mut r PossibleFragmentSpreadsRule) enter(mut c ValidationContext, w &Walker, node Node) bool {
	if node is InlineFragment {
		frag_type := w.info.typ() or { return true }
		frag := c.schema.named_type(frag_type) or { return true }
		parent := w.info.parent_type() or { return true }
		if frag_type is NamedType && frag.is_composite() && parent.is_composite()
			&& !c.schema.do_types_overlap(frag.name, parent.name) {
			c.report('Fragment cannot be spread here as objects of type "${parent.name}" can never be of type "${frag.name}".',
				[node.pos])
		}
	} else if node is FragmentSpread {
		name := node.name.value
		fragment := c.fragment(name) or { return true }
		frag := c.schema.get_type(fragment.type_condition.name.value) or { return true }
		if !frag.is_composite() {
			return true
		}
		parent := w.info.parent_type() or { return true }
		if !c.schema.do_types_overlap(frag.name, parent.name) {
			c.report('Fragment "${name}" cannot be spread here as objects of type "${parent.name}" can never be of type "${frag.name}".',
				[node.pos])
		}
	}
	return true
}

fn (mut r PossibleFragmentSpreadsRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// do_types_overlap reports whether an object can be of both composite types.
pub fn (s &Schema) do_types_overlap(a string, b string) bool {
	if a == b {
		return true
	}
	ta := s.get_type(a) or { return false }
	tb := s.get_type(b) or { return false }
	if ta.is_abstract() {
		if tb.is_abstract() {
			return s.possible_types(a).any(s.is_sub_type(b, it))
		}
		return s.is_sub_type(a, b)
	}
	if tb.is_abstract() {
		return s.is_sub_type(b, a)
	}
	return false
}

// --- NoFragmentCyclesRule

struct NoFragmentCyclesRule {
mut:
	visited       map[string]bool
	spread_path   []FragmentSpread
	index_by_name map[string]int
}

fn (mut r NoFragmentCyclesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	match node {
		OperationDefinition {
			return false
		}
		FragmentDefinition {
			r.detect(mut c, node)
			return false
		}
		else {
			return true
		}
	}
}

fn (mut r NoFragmentCyclesRule) detect(mut c ValidationContext, fragment FragmentDefinition) {
	name := fragment.name.value
	if name in r.visited {
		return
	}
	r.visited[name] = true
	spreads := c.fragment_spreads(fragment.selection_set)
	if spreads.len == 0 {
		return
	}
	r.index_by_name[name] = r.spread_path.len
	for spread in spreads {
		spread_name := spread.name.value
		r.spread_path << spread
		if cycle_index := r.index_by_name[spread_name] {
			cycle := r.spread_path[cycle_index..].clone()
			via := cycle[..cycle.len - 1].map('"${it.name.value}"').join(', ')
			c.report('Cannot spread fragment "${spread_name}" within itself' +
				(if via != '' { ' via ${via}.' } else { '.' }), cycle.map(it.pos))
		} else {
			if f := c.fragment(spread_name) {
				r.detect(mut c, f)
			}
		}
		r.spread_path.pop()
	}
	r.index_by_name.delete(name)
}

fn (mut r NoFragmentCyclesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- UniqueVariableNamesRule

struct UniqueVariableNamesRule {}

fn (mut r UniqueVariableNamesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is OperationDefinition {
		mut order := []string{}
		mut seen := map[string][]int{}
		for v in node.variable_definitions {
			name := v.variable.name.value
			if name !in seen {
				order << name
			}
			seen[name] << v.variable.name.pos
		}
		for name in order {
			if seen[name].len > 1 {
				c.report('There can be only one variable named "$${name}".', seen[name])
			}
		}
	}
	return true
}

fn (mut r UniqueVariableNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- NoUndefinedVariablesRule

struct NoUndefinedVariablesRule {
mut:
	defined map[string]bool
}

fn (mut r NoUndefinedVariablesRule) enter(mut _ ValidationContext, _ &Walker, node Node) bool {
	if node is OperationDefinition {
		r.defined = map[string]bool{}
	} else if node is VariableDefinition {
		r.defined[node.variable.name.value] = true
	}
	return true
}

fn (mut r NoUndefinedVariablesRule) leave(mut c ValidationContext, _ &Walker, node Node) {
	if node is OperationDefinition {
		for use in c.recursive_variable_usages(node) {
			name := use.node.name.value
			if name !in r.defined {
				message := if op_name := node.name {
					'Variable "$${name}" is not defined by operation "${op_name.value}".'
				} else {
					'Variable "$${name}" is not defined.'
				}
				c.report(message, [use.node.pos, node.pos])
			}
		}
	}
}

// --- NoUnusedVariablesRule

struct NoUnusedVariablesRule {
mut:
	defs []VariableDefinition
}

fn (mut r NoUnusedVariablesRule) enter(mut _ ValidationContext, _ &Walker, node Node) bool {
	if node is OperationDefinition {
		r.defs = []
	} else if node is VariableDefinition {
		r.defs << node
	}
	return true
}

fn (mut r NoUnusedVariablesRule) leave(mut c ValidationContext, _ &Walker, node Node) {
	if node is OperationDefinition {
		mut used := map[string]bool{}
		for use in c.recursive_variable_usages(node) {
			used[use.node.name.value] = true
		}
		for def in r.defs {
			name := def.variable.name.value
			if name !in used {
				message := if op_name := node.name {
					'Variable "$${name}" is never used in operation "${op_name.value}".'
				} else {
					'Variable "$${name}" is never used.'
				}
				c.report(message, [def.pos])
			}
		}
	}
}

// --- KnownDirectivesRule

struct KnownDirectivesRule {
	locations map[string][]string
}

fn defined_directives(c &ValidationContext) []DirectiveDef {
	return if c.has_schema { c.schema.directives } else { builtins.directives }
}

fn new_known_directives(c &ValidationContext) KnownDirectivesRule {
	mut locations := map[string][]string{}
	for d in defined_directives(c) {
		locations[d.name] = d.locations
	}
	for def in c.doc.definitions {
		if def is DirectiveDefinition {
			locations[def.name.value] = def.locations.map(it.value)
		}
	}
	return KnownDirectivesRule{
		locations: locations
	}
}

fn (mut r KnownDirectivesRule) enter(mut c ValidationContext, w &Walker, node Node) bool {
	if node is Directive {
		name := node.name.value
		locations := r.locations[name] or {
			c.report('Unknown directive "@${name}".', [node.pos])
			return true
		}
		candidate := directive_location(w.ancestors)
		if candidate != '' && candidate !in locations {
			c.report('Directive "@${name}" may not be used on ${candidate}.', [node.pos])
		}
	}
	return true
}

fn (mut r KnownDirectivesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// directive_location returns the location of a directive applied to the last
// of `ancestors`.
fn directive_location(ancestors []Node) string {
	if ancestors.len == 0 {
		return ''
	}
	applied_to := ancestors.last()
	return match applied_to {
		OperationDefinition {
			applied_to.operation.str().to_upper()
		}
		Field {
			'FIELD'
		}
		FragmentSpread {
			'FRAGMENT_SPREAD'
		}
		InlineFragment {
			'INLINE_FRAGMENT'
		}
		FragmentDefinition {
			'FRAGMENT_DEFINITION'
		}
		VariableDefinition {
			'VARIABLE_DEFINITION'
		}
		SchemaDefinition {
			'SCHEMA'
		}
		TypeDefinition {
			match applied_to.kind {
				.scalar { 'SCALAR' }
				.object { 'OBJECT' }
				.@interface { 'INTERFACE' }
				.@union { 'UNION' }
				.@enum { 'ENUM' }
				.input_object { 'INPUT_OBJECT' }
			}
		}
		FieldDefinition {
			'FIELD_DEFINITION'
		}
		EnumValueDefinition {
			'ENUM_VALUE'
		}
		InputValueDefinition {
			mut location := 'ARGUMENT_DEFINITION'
			if ancestors.len > 1 {
				owner := ancestors[ancestors.len - 2]
				if owner is TypeDefinition {
					if owner.kind == .input_object && !owner.is_extension {
						location = 'INPUT_FIELD_DEFINITION'
					}
				}
			}
			location
		}
		DirectiveDefinition {
			'DIRECTIVE_DEFINITION'
		}
		else {
			''
		}
	}
}

// --- UniqueDirectivesPerLocationRule

struct UniqueDirectivesPerLocationRule {
	unique map[string]bool
mut:
	schema_directives map[string]int
	type_directives   map[string]map[string]int
}

fn new_unique_directives_per_location(c &ValidationContext) UniqueDirectivesPerLocationRule {
	mut unique := map[string]bool{}
	for d in defined_directives(c) {
		unique[d.name] = !d.repeatable
	}
	for def in c.doc.definitions {
		if def is DirectiveDefinition {
			unique[def.name.value] = !def.repeatable
		}
	}
	return UniqueDirectivesPerLocationRule{
		unique: unique
	}
}

fn node_directives(node Node) ?[]Directive {
	return match node {
		OperationDefinition, VariableDefinition, Field, FragmentSpread, InlineFragment,
		FragmentDefinition, SchemaDefinition, TypeDefinition, FieldDefinition, InputValueDefinition,
		EnumValueDefinition {
			node.directives
		}
		else {
			none
		}
	}
}

fn (mut r UniqueDirectivesPerLocationRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	directives := node_directives(node) or { return true }
	mut seen := map[string]int{}
	if node is SchemaDefinition {
		seen = r.schema_directives.clone()
	} else if node is TypeDefinition {
		seen = (r.type_directives[node.name.value] or { map[string]int{} }).clone()
	}
	for d in directives {
		name := d.name.value
		if r.unique[name] or { false } {
			if first := seen[name] {
				c.report('The directive "@${name}" can only be used once at this location.', [
					first,
					d.pos,
				])
			} else {
				seen[name] = d.pos
			}
		}
	}
	if node is SchemaDefinition {
		r.schema_directives = seen.clone()
	} else if node is TypeDefinition {
		r.type_directives[node.name.value] = seen.clone()
	}
	return true
}

fn (mut r UniqueDirectivesPerLocationRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- KnownArgumentNamesRule, and KnownArgumentNamesOnDirectivesRule alone

struct KnownArgumentNamesRule {
	directive_args map[string][]string
	on_fields      bool
}

fn new_known_argument_names(c &ValidationContext, on_fields bool) KnownArgumentNamesRule {
	mut args := map[string][]string{}
	for d in defined_directives(c) {
		args[d.name] = d.args.map(it.name)
	}
	for def in c.doc.definitions {
		if def is DirectiveDefinition {
			args[def.name.value] = def.arguments.map(it.name.value)
		}
	}
	return KnownArgumentNamesRule{
		directive_args: args
		on_fields:      on_fields
	}
}

fn (mut r KnownArgumentNamesRule) enter(mut c ValidationContext, w &Walker, node Node) bool {
	if node is Directive {
		name := node.name.value
		if known := r.directive_args[name] {
			for a in node.arguments {
				if a.name.value !in known {
					c.report('Unknown argument "${a.name.value}" on directive "@${name}".' +
						did_you_mean('', suggestion_list(a.name.value, known)), [a.pos])
				}
			}
		}
		return false
	}
	if r.on_fields && node is Argument {
		if _ := w.info.get_argument() {
			return true
		}
		field := w.info.field_def() or { return true }
		parent := w.info.parent_type() or { return true }
		name := node.name.value
		c.report('Unknown argument "${name}" on field "${parent.name}.${field.name}".' +
			did_you_mean('', suggestion_list(name, field.args.map(it.name))), [node.pos])
	}
	return true
}

fn (mut r KnownArgumentNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- UniqueArgumentNamesRule

struct UniqueArgumentNamesRule {}

fn (mut r UniqueArgumentNamesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	mut args := []Argument{}
	if node is Field {
		args = node.arguments
	} else if node is Directive {
		args = node.arguments
	} else {
		return true
	}
	mut order := []string{}
	mut seen := map[string][]int{}
	for a in args {
		if a.name.value !in seen {
			order << a.name.value
		}
		seen[a.name.value] << a.name.pos
	}
	for name in order {
		if seen[name].len > 1 {
			c.report('There can be only one argument named "${name}".', seen[name])
		}
	}
	return true
}

fn (mut r UniqueArgumentNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- ValuesOfCorrectTypeRule

struct ValuesOfCorrectTypeRule {}

fn (mut r ValuesOfCorrectTypeRule) enter(mut c ValidationContext, w &Walker, node Node) bool {
	match node {
		ListValue {
			if t := w.info.parent_input_type() {
				if nullable(t) is ListType {
					return true
				}
			}
			r.check_value(mut c, w, ValueNode(node))
			return false
		}
		ObjectValue {
			named := c.schema.named_type(w.info.input_type() or {
				r.check_value(mut c, w, ValueNode(node))
				return false
			}) or {
				r.check_value(mut c, w, ValueNode(node))
				return false
			}
			if named.kind != .input_object {
				r.check_value(mut c, w, ValueNode(node))
				return false
			}
			mut field_nodes := map[string]ObjectField{}
			for f in node.fields {
				field_nodes[f.name.value] = f
			}
			for def in named.input_fields {
				if def.name !in field_nodes && def.typ is NonNullType && def.default_value == none {
					c.report('Field "${named.name}.${def.name}" of required type "${print_type(def.typ)}" was not provided.',
						[node.pos])
				}
			}
			if named.is_one_of {
				if field_nodes.len != 1 {
					c.report('OneOf Input Object "${named.name}" must specify exactly one key.',
						[node.pos])
				} else {
					for key, f in field_nodes {
						if f.value is NullValue {
							c.report('Field "${named.name}.${key}" must be non-null.', [node.pos])
						}
					}
				}
			}
		}
		ObjectField {
			if _ := w.info.input_type() {
				return true
			}
			parent := c.schema.named_type(w.info.parent_input_type() or { return true }) or {
				return true
			}
			if parent.kind == .input_object {
				c.report('Field "${node.name.value}" is not defined by type "${parent.name}".' +
					did_you_mean('', suggestion_list(node.name.value, parent.input_fields.map(it.name))),
					[node.pos])
			}
		}
		NullValue {
			if t := w.info.input_type() {
				if t is NonNullType {
					c.report('Expected value of type "${print_type(t)}", found null.', [
						node.pos,
					])
				}
			}
		}
		EnumValue {
			r.check_value(mut c, w, ValueNode(node))
		}
		IntValue {
			r.check_value(mut c, w, ValueNode(node))
		}
		FloatValue {
			r.check_value(mut c, w, ValueNode(node))
		}
		StringValue {
			r.check_value(mut c, w, ValueNode(node))
		}
		BooleanValue {
			r.check_value(mut c, w, ValueNode(node))
		}
		else {}
	}
	return true
}

// check_value is graphql-js's `isValidValueNode`: a literal must parse as the
// leaf type expected where it is.
fn (r &ValuesOfCorrectTypeRule) check_value(mut c ValidationContext, w &Walker, node ValueNode) {
	location_type := w.info.input_type() or { return }
	named := c.schema.named_type(location_type) or { return }
	type_str := print_type(location_type)
	if !named.is_leaf() {
		c.report('Expected value of type "${type_str}", found ${print_value(node)}.', [
			node.pos(),
		])
		return
	}
	if named.kind == .@enum {
		c.schema.parse_enum_literal(named, node) or { c.report(err.msg(), [node.pos()]) }
		return
	}
	c.schema.parse_literal(named.name, node, map[string]Value{}) or {
		if named.name in specified_scalars {
			c.report(err.msg(), [node.pos()])
		} else if err.msg() == '' {
			// a custom scalar that rejects the literal without saying why
			c.report('Expected value of type "${type_str}", found ${print_value(node)}.',
				[node.pos()])
		} else {
			c.report('Expected value of type "${type_str}", found ${print_value(node)}; ${err.msg()}',
				[node.pos()])
		}
	}
}

// parse_enum_literal reads an enum literal, or fails with graphql-js's message.
fn (s &Schema) parse_enum_literal(t Type, node ValueNode) !Value {
	if node !is EnumValue {
		value_str := print_value(node)
		return error('Enum "${t.name}" cannot represent non-enum value: ${value_str}.' +
			did_you_mean('the enum value', suggestion_list(value_str, t.values.map(it.name))))
	}
	value := (node as EnumValue).value
	if _ := t.enum_value(value) {
		return Value(value)
	}
	return error('Value "${value}" does not exist in "${t.name}" enum.' +
		did_you_mean('the enum value', suggestion_list(value, t.values.map(it.name))))
}

fn (mut r ValuesOfCorrectTypeRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- ProvidedRequiredArgumentsRule, and ProvidedRequiredArgumentsOnDirectivesRule alone

struct RequiredArg {
	name string
	typ  string
}

struct ProvidedRequiredArgumentsRule {
	required  map[string][]RequiredArg
	on_fields bool
}

fn new_provided_required_arguments(c &ValidationContext, on_fields bool) ProvidedRequiredArgumentsRule {
	mut required := map[string][]RequiredArg{}
	for d in defined_directives(c) {
		required[d.name] = d.args.filter(it.typ is NonNullType && it.default_value == none).map(RequiredArg{
			name: it.name
			typ:  print_type(it.typ)
		})
	}
	for def in c.doc.definitions {
		if def is DirectiveDefinition {
			required[def.name.value] = def.arguments.filter(it.typ is NonNullType
				&& it.default_value == none).map(RequiredArg{
				name: it.name.value
				typ:  print_type(it.typ)
			})
		}
	}
	return ProvidedRequiredArgumentsRule{
		required:  required
		on_fields: on_fields
	}
}

fn (mut r ProvidedRequiredArgumentsRule) enter(mut _ ValidationContext, _ &Walker, _ Node) bool {
	return true
}

fn (mut r ProvidedRequiredArgumentsRule) leave(mut c ValidationContext, w &Walker, node Node) {
	if node is Directive {
		name := node.name.value
		if required := r.required[name] {
			provided := names_of(node.arguments)
			for arg in required {
				if arg.name !in provided {
					c.report('Directive "@${name}" argument "${arg.name}" of type "${arg.typ}" is required, but it was not provided.',
						[node.pos])
				}
			}
		}
	} else if r.on_fields && node is Field {
		field := w.info.field_def() or { return }
		provided := names_of(node.arguments)
		for arg in field.args {
			if arg.name !in provided && arg.typ is NonNullType && arg.default_value == none {
				c.report('Field "${field.name}" argument "${arg.name}" of type "${print_type(arg.typ)}" is required, but it was not provided.',
					[node.pos])
			}
		}
	}
}

// names_of returns the names of `args`. A loop: `args.map(it.name.value)`
// generates invalid C (regressions/map_nested_field_name.vv).
fn names_of(args []Argument) []string {
	mut names := []string{cap: args.len}
	for a in args {
		names << a.name.value
	}
	return names
}

// --- VariablesInAllowedPositionRule

struct VariablesInAllowedPositionRule {
mut:
	var_defs map[string]VariableDefinition
}

fn (mut r VariablesInAllowedPositionRule) enter(mut _ ValidationContext, _ &Walker, node Node) bool {
	if node is OperationDefinition {
		r.var_defs = map[string]VariableDefinition{}
	} else if node is VariableDefinition {
		r.var_defs[node.variable.name.value] = node
	}
	return true
}

fn (mut r VariablesInAllowedPositionRule) leave(mut c ValidationContext, _ &Walker, node Node) {
	if node is OperationDefinition {
		for use in c.recursive_variable_usages(node) {
			name := use.node.name.value
			def := r.var_defs[name] or { continue }
			location_type := use.typ or { continue }
			var_type := c.schema.type_from_ast(def.typ) or { continue }
			if !c.schema.allowed_variable_usage(var_type, def.default_value, location_type,
				use.default_value) {
				c.report('Variable "$${name}" of type "${print_type(var_type)}" used in position expecting type "${print_type(location_type)}".',
					[def.pos, use.node.pos])
			}
			if parent := use.parent_type {
				if parent is NamedType {
					if pt := c.schema.get_type(parent.name.value) {
						if pt.kind == .input_object && pt.is_one_of && var_type !is NonNullType {
							c.report('Variable "$${name}" is of type "${print_type(var_type)}" but must be non-nullable to be used for OneOf Input Object "${pt.name}".',
								[def.pos, use.node.pos])
						}
					}
				}
			}
		}
	}
}

fn (s &Schema) allowed_variable_usage(var_type TypeNode, var_default ?ValueNode, location_type TypeNode, location_default ?Value) bool {
	if location_type is NonNullType && var_type !is NonNullType {
		mut has_non_null_var_default := false
		if d := var_default {
			has_non_null_var_default = d !is NullValue
		}
		has_location_default := location_default != none
		if !has_non_null_var_default && !has_location_default {
			return false
		}
		return s.is_type_sub_type_of(var_type, location_type.typ)
	}
	return s.is_type_sub_type_of(var_type, location_type)
}

// is_type_sub_type_of reports whether a value of type `sub` can be used where
// `super` is expected.
pub fn (s &Schema) is_type_sub_type_of(sub TypeNode, super TypeNode) bool {
	if print_type(sub) == print_type(super) {
		return true
	}
	if super is NonNullType {
		if sub is NonNullType {
			return s.is_type_sub_type_of(sub.typ, super.typ)
		}
		return false
	}
	if sub is NonNullType {
		return s.is_type_sub_type_of(sub.typ, super)
	}
	if super is ListType {
		if sub is ListType {
			return s.is_type_sub_type_of(sub.typ, super.typ)
		}
		return false
	}
	if sub is ListType {
		return false
	}
	sup := s.get_type(super.named().name.value) or { return false }
	sb := s.get_type(sub.named().name.value) or { return false }
	return sup.is_abstract() && sb.kind in [.@interface, .object]
		&& s.is_sub_type(sup.name, sb.name)
}

// --- UniqueInputFieldNamesRule

struct UniqueInputFieldNamesRule {
mut:
	stack []map[string]int
	known map[string]int
}

fn (mut r UniqueInputFieldNamesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is ObjectValue {
		r.stack << r.known.clone()
		r.known = map[string]int{}
	} else if node is ObjectField {
		name := node.name.value
		if first := r.known[name] {
			c.report('There can be only one input field named "${name}".', [first, node.name.pos])
		} else {
			r.known[name] = node.name.pos
		}
	}
	return true
}

fn (mut r UniqueInputFieldNamesRule) leave(mut _ ValidationContext, _ &Walker, node Node) {
	if node is ObjectValue {
		r.known = r.stack.pop()
	}
}

// --- MaxIntrospectionDepthRule

struct MaxIntrospectionDepthRule {}

const max_lists_depth = 3

fn (mut r MaxIntrospectionDepthRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is Field {
		if node.name.value in ['__schema', '__type'] {
			mut visited := map[string]bool{}
			if check_introspection_depth(mut c, Selection(node), mut visited, 0) {
				c.report('Maximum introspection depth exceeded', [node.pos])
				return false
			}
		}
	}
	return true
}

fn check_introspection_depth(mut c ValidationContext, sel Selection, mut visited map[string]bool, depth_in int) bool {
	mut depth := depth_in
	match sel {
		FragmentSpread {
			name := sel.name.value
			if name in visited {
				return false
			}
			fragment := c.fragment(name) or { return false }
			visited[name] = true
			defer {
				visited.delete(name)
			}
			for child in fragment.selection_set.selections {
				if check_introspection_depth(mut c, child, mut visited, depth) {
					return true
				}
			}
			return false
		}
		Field {
			if sel.name.value in ['fields', 'interfaces', 'possibleTypes', 'inputFields'] {
				depth++
				if depth >= max_lists_depth {
					return true
				}
			}
			if set := sel.selection_set {
				for child in set.selections {
					if check_introspection_depth(mut c, child, mut visited, depth) {
						return true
					}
				}
			}
			return false
		}
		InlineFragment {
			for child in sel.selection_set.selections {
				if check_introspection_depth(mut c, child, mut visited, depth) {
					return true
				}
			}
			return false
		}
	}
}

fn (mut r MaxIntrospectionDepthRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- NoDeprecatedCustomRule

struct NoDeprecatedCustomRule {}

fn (mut r NoDeprecatedCustomRule) enter(mut c ValidationContext, w &Walker, node Node) bool {
	match node {
		Field {
			field := w.info.field_def() or { return true }
			reason := field.deprecation_reason or { return true }
			parent := w.info.parent_type() or { return true }
			c.report('The field ${parent.name}.${field.name} is deprecated. ${reason}', [
				node.pos,
			])
		}
		Argument {
			arg := w.info.get_argument() or { return true }
			reason := arg.deprecation_reason or { return true }
			if d := w.info.get_directive() {
				c.report('Directive "@${d.name}" argument "${arg.name}" is deprecated. ${reason}',
					[node.pos])
			} else {
				parent := w.info.parent_type() or { return true }
				field := w.info.field_def() or { return true }
				c.report('Field "${parent.name}.${field.name}" argument "${arg.name}" is deprecated. ${reason}',
					[node.pos])
			}
		}
		ObjectField {
			parent := c.schema.named_type(w.info.parent_input_type() or { return true }) or {
				return true
			}
			if parent.kind == .input_object {
				if f := parent.input_field(node.name.value) {
					if reason := f.deprecation_reason {
						c.report('The input field ${parent.name}.${f.name} is deprecated. ${reason}',
							[node.pos])
					}
				}
			}
		}
		EnumValue {
			value := w.info.get_enum_value() or { return true }
			reason := value.deprecation_reason or { return true }
			enum_type := c.schema.named_type(w.info.input_type() or { return true }) or {
				return true
			}
			c.report('The enum value "${enum_type.name}.${value.name}" is deprecated. ${reason}',
				[node.pos])
		}
		else {}
	}
	return true
}

fn (mut r NoDeprecatedCustomRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- NoSchemaIntrospectionCustomRule

struct NoSchemaIntrospectionRule {}

fn (mut r NoSchemaIntrospectionRule) enter(mut c ValidationContext, w &Walker, node Node) bool {
	if node is Field {
		if t := w.info.typ() {
			if t.named().name.value in introspection_types {
				c.report('GraphQL introspection has been disabled, but the requested query contained the field "${node.name.value}".',
					[node.pos])
			}
		}
	}
	return true
}

fn (mut r NoSchemaIntrospectionRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- MaxComplexityRule: vgraph's limits on depth and size (Q31)

struct MaxComplexityRule {
	max_depth      int
	max_selections int
}

fn (mut r MaxComplexityRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is OperationDefinition {
		mut visited := map[string]bool{}
		depth, count := measure_selections(mut c, node.selection_set, mut visited)
		name := if n := node.name { ' "${n.value}"' } else { '' }
		if r.max_depth > 0 && depth > r.max_depth {
			c.report('Operation${name} is nested ${depth} levels deep, more than the limit of ${r.max_depth}.',
				[node.pos])
		}
		if r.max_selections > 0 && count > r.max_selections {
			c.report('Operation${name} selects ${count} fields, more than the limit of ${r.max_selections}.',
				[node.pos])
		}
		return false
	}
	return true
}

fn (mut r MaxComplexityRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// measure_selections returns how deep a selection set's fields nest, and how
// many fields it selects, following fragments (a cycle counts once).
fn measure_selections(mut c ValidationContext, set SelectionSet, mut visited map[string]bool) (int, int) {
	mut depth := 0
	mut count := 0
	for sel in set.selections {
		match sel {
			Field {
				count++
				mut d := 1
				if sub := sel.selection_set {
					sd, sc := measure_selections(mut c, sub, mut visited)
					d += sd
					count += sc
				}
				if d > depth {
					depth = d
				}
			}
			InlineFragment {
				sd, sc := measure_selections(mut c, sel.selection_set, mut visited)
				count += sc
				if sd > depth {
					depth = sd
				}
			}
			FragmentSpread {
				name := sel.name.value
				if name in visited {
					continue
				}
				fragment := c.fragment(name) or { continue }
				visited[name] = true
				sd, sc := measure_selections(mut c, fragment.selection_set, mut visited)
				visited.delete(name)
				count += sc
				if sd > depth {
					depth = sd
				}
			}
		}
	}
	return depth, count
}
