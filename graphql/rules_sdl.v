module graphql

// The rules for SDL, ported from graphql-js with its messages. The rules shared
// with executable documents are in rules.v.

fn new_sdl_rule(name string, mut c ValidationContext) ?Rule {
	return match name {
		'LoneSchemaDefinitionRule' { Rule(new_lone_schema_definition(c)) }
		'UniqueOperationTypesRule' { Rule(new_unique_operation_types(c)) }
		'UniqueTypeNamesRule' { Rule(UniqueTypeNamesRule{}) }
		'UniqueEnumValueNamesRule' { Rule(UniqueEnumValueNamesRule{}) }
		'UniqueFieldDefinitionNamesRule' { Rule(UniqueFieldDefinitionNamesRule{}) }
		'UniqueArgumentDefinitionNamesRule' { Rule(UniqueArgumentDefinitionNamesRule{}) }
		'UniqueDirectiveNamesRule' { Rule(UniqueDirectiveNamesRule{}) }
		'KnownTypeNamesRule' { Rule(new_known_type_names(c)) }
		'KnownDirectivesRule' { Rule(new_known_directives(c)) }
		'UniqueDirectivesPerLocationRule' { Rule(new_unique_directives_per_location(c)) }
		'PossibleTypeExtensionsRule' { Rule(new_possible_type_extensions(c)) }
		'KnownArgumentNamesOnDirectivesRule' { Rule(new_known_argument_names(c, false)) }
		'UniqueArgumentNamesRule' { Rule(UniqueArgumentNamesRule{}) }
		'UniqueInputFieldNamesRule' { Rule(UniqueInputFieldNamesRule{}) }
		'ProvidedRequiredArgumentsOnDirectivesRule' {
			Rule(new_provided_required_arguments(c, false))
		}
		else { none }
	}
}

// --- LoneSchemaDefinitionRule

struct LoneSchemaDefinitionRule {
	already_defined bool
mut:
	count int
}

fn new_lone_schema_definition(c &ValidationContext) LoneSchemaDefinitionRule {
	s := c.schema
	return LoneSchemaDefinitionRule{
		already_defined: c.has_schema && (s.has_schema_definition || s.query != none
			|| s.mutation != none || s.subscription != none)
	}
}

fn (mut r LoneSchemaDefinitionRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is SchemaDefinition && !node.is_extension {
		if r.already_defined {
			c.report('Cannot define a new schema within a schema extension.', [node.pos])
			return true
		}
		if r.count > 0 {
			c.report('Must provide only one schema definition.', [node.pos])
		}
		r.count++
	}
	return true
}

fn (mut r LoneSchemaDefinitionRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- UniqueOperationTypesRule

struct UniqueOperationTypesRule {
	existing map[string]bool
mut:
	defined map[string]int
}

fn new_unique_operation_types(c &ValidationContext) UniqueOperationTypesRule {
	mut existing := map[string]bool{}
	if c.has_schema {
		existing['query'] = c.schema.query != none
		existing['mutation'] = c.schema.mutation != none
		existing['subscription'] = c.schema.subscription != none
	}
	return UniqueOperationTypesRule{
		existing: existing
	}
}

fn (mut r UniqueOperationTypesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is SchemaDefinition {
		for op in node.operation_types {
			name := op.operation.str()
			if r.existing[name] or { false } {
				c.report('Type for ${name} already defined in the schema. It cannot be redefined.',
					[op.pos])
			} else if first := r.defined[name] {
				c.report('There can be only one ${name} type in schema.', [first, op.pos])
			} else {
				r.defined[name] = op.pos
			}
		}
		return false
	}
	return true
}

fn (mut r UniqueOperationTypesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- UniqueTypeNamesRule

struct UniqueTypeNamesRule {
mut:
	known map[string]int
}

fn (mut r UniqueTypeNamesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is TypeDefinition && !node.is_extension {
		name := node.name.value
		if c.has_schema && name in c.schema.types {
			c.report('Type "${name}" already exists in the schema. It cannot also be defined in this type definition.',
				[node.name.pos])
			return true
		}
		if first := r.known[name] {
			c.report('There can be only one type named "${name}".', [first, node.name.pos])
		} else {
			r.known[name] = node.name.pos
		}
		return false
	}
	return true
}

fn (mut r UniqueTypeNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- UniqueEnumValueNamesRule

struct UniqueEnumValueNamesRule {
mut:
	known map[string]map[string]int
}

fn (mut r UniqueEnumValueNamesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is TypeDefinition && node.kind == .@enum {
		type_name := node.name.value
		mut known := (r.known[type_name] or { map[string]int{} }).clone()
		existing := if c.has_schema { c.schema.get_type(type_name) } else { none }
		for v in node.values {
			name := v.name.value
			mut exists := false
			if t := existing {
				if t.kind == .@enum {
					if _ := t.enum_value(name) {
						exists = true
					}
				}
			}
			if exists {
				c.report('Enum value "${type_name}.${name}" already exists in the schema. It cannot also be defined in this type extension.',
					[v.name.pos])
			} else if first := known[name] {
				c.report('Enum value "${type_name}.${name}" can only be defined once.', [
					first,
					v.name.pos,
				])
			} else {
				known[name] = v.name.pos
			}
		}
		r.known[type_name] = known.clone()
		return false
	}
	return true
}

fn (mut r UniqueEnumValueNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- UniqueFieldDefinitionNamesRule

struct UniqueFieldDefinitionNamesRule {
mut:
	known map[string]map[string]int
}

fn (mut r UniqueFieldDefinitionNamesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is TypeDefinition && node.kind in [.object, .@interface, .input_object] {
		type_name := node.name.value
		mut known := (r.known[type_name] or { map[string]int{} }).clone()
		mut names := []Name{}
		if node.kind == .input_object {
			names = node.input_fields.map(it.name)
		} else {
			names = node.fields.map(it.name)
		}
		existing := if c.has_schema { c.schema.get_type(type_name) } else { none }
		for n in names {
			mut exists := false
			if t := existing {
				exists = match t.kind {
					.object, .@interface { t.field(n.value) != none }
					.input_object { t.input_field(n.value) != none }
					else { false }
				}
			}
			if exists {
				c.report('Field "${type_name}.${n.value}" already exists in the schema. It cannot also be defined in this type extension.',
					[n.pos])
			} else if first := known[n.value] {
				c.report('Field "${type_name}.${n.value}" can only be defined once.', [
					first,
					n.pos,
				])
			} else {
				known[n.value] = n.pos
			}
		}
		r.known[type_name] = known.clone()
		return false
	}
	return true
}

fn (mut r UniqueFieldDefinitionNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- UniqueArgumentDefinitionNamesRule

struct UniqueArgumentDefinitionNamesRule {}

fn (mut r UniqueArgumentDefinitionNamesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is DirectiveDefinition {
		check_arg_definitions(mut c, '@${node.name.value}', node.arguments)
		return false
	}
	if node is TypeDefinition && node.kind in [.object, .@interface] {
		for f in node.fields {
			check_arg_definitions(mut c, '${node.name.value}.${f.name.value}', f.arguments)
		}
		return false
	}
	return true
}

fn check_arg_definitions(mut c ValidationContext, parent string, args []InputValueDefinition) {
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
			c.report('Argument "${parent}(${name}:)" can only be defined once.', seen[name])
		}
	}
}

fn (mut r UniqueArgumentDefinitionNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- UniqueDirectiveNamesRule

struct UniqueDirectiveNamesRule {
mut:
	known map[string]int
}

fn (mut r UniqueDirectiveNamesRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is DirectiveDefinition {
		name := node.name.value
		if c.has_schema {
			if _ := c.schema.get_directive(name) {
				c.report('Directive "@${name}" already exists in the schema. It cannot be redefined.',
					[node.name.pos])
				return true
			}
		}
		if first := r.known[name] {
			c.report('There can be only one directive named "@${name}".', [first, node.name.pos])
		} else {
			r.known[name] = node.name.pos
		}
		return false
	}
	return true
}

fn (mut r UniqueDirectiveNamesRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

// --- PossibleTypeExtensionsRule

struct PossibleTypeExtensionsRule {
	defined map[string]TypeDefinition
	names   []string
}

fn new_possible_type_extensions(c &ValidationContext) PossibleTypeExtensionsRule {
	mut defined := map[string]TypeDefinition{}
	mut names := []string{}
	for def in c.doc.definitions {
		if def is TypeDefinition && !def.is_extension {
			if def.name.value !in defined {
				names << def.name.value
			}
			defined[def.name.value] = def
		}
	}
	if c.has_schema {
		for name in c.schema.type_names {
			if name !in defined {
				names << name
			}
		}
	}
	return PossibleTypeExtensionsRule{
		defined: defined
		names:   names
	}
}

fn (mut r PossibleTypeExtensionsRule) enter(mut c ValidationContext, _ &Walker, node Node) bool {
	if node is TypeDefinition && node.is_extension {
		name := node.name.value
		mut expected := ?TypeDefinitionKind(none)
		mut def_pos := -1
		if def := r.defined[name] {
			expected = def.kind
			def_pos = def.pos
		} else if c.has_schema {
			if t := c.schema.get_type(name) {
				expected = t.kind
			}
		}
		if kind := expected {
			if kind != node.kind {
				kind_str := match node.kind {
					.scalar { 'scalar' }
					.object { 'object' }
					.@interface { 'interface' }
					.@union { 'union' }
					.@enum { 'enum' }
					.input_object { 'input object' }
				}
				positions := if def_pos >= 0 { [def_pos, node.pos] } else { [node.pos] }
				c.report('Cannot extend non-${kind_str} type "${name}".', positions)
			}
		} else {
			c.report('Cannot extend type "${name}" because it is not defined.' +
				did_you_mean('', suggestion_list(name, r.names)), [node.name.pos])
		}
	}
	return true
}

fn (mut r PossibleTypeExtensionsRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}
