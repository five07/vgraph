module graphql

// validate_schema checks a schema's type system, as graphql-js's
// `validateSchema` does: root types, directives, and every type's fields,
// interfaces, members and values. Errors are located at the definitions the
// schema kept the positions of.
pub fn validate_schema(s &Schema) []GraphQLError {
	mut v := SchemaValidator{
		s: s
	}
	v.root_types()
	v.directives()
	v.types()
	return v.errors
}

struct SchemaValidator {
	s &Schema
mut:
	errors []GraphQLError
	// input object cycle detection
	visited    map[string]bool
	field_path []InputValueDef
	path_index map[string]int
}

fn (mut v SchemaValidator) report(message string, positions []int) {
	v.errors << GraphQLError{
		message:   message
		locations: positions.filter(it >= 0).map(location_of(v.s.source, it))
	}
}

fn (v &SchemaValidator) type_pos(name string) []int {
	t := v.s.get_type(name) or { return [] }
	return if name in specified_scalars || name in introspection_types { [] } else { [t.pos] }
}

fn (mut v SchemaValidator) root_types() {
	s := v.s
	if q := s.query {
		t := s.get_type(q) or { Type{} }
		if t.kind != .object {
			v.report('Query root type must be Object type, it cannot be ${q}.', v.type_pos(q))
		}
	} else {
		v.report('Query root type must be provided.', [])
	}
	if m := s.mutation {
		t := s.get_type(m) or { Type{} }
		if t.kind != .object {
			v.report('Mutation root type must be Object type if provided, it cannot be ${m}.',
				v.type_pos(m))
		}
	}
	if sub := s.subscription {
		t := s.get_type(sub) or { Type{} }
		if t.kind != .object {
			v.report('Subscription root type must be Object type if provided, it cannot be ${sub}.',
				v.type_pos(sub))
		}
	}
}

fn (mut v SchemaValidator) name(name string, pos int) {
	if name.starts_with('__') {
		v.report('Name "${name}" must not begin with "__", which is reserved by GraphQL introspection.',
			[pos])
	}
}

fn (mut v SchemaValidator) directives() {
	for d in v.s.directives {
		if d.name in specified_directives {
			continue
		}
		v.name(d.name, d.pos)
		if d.locations.len == 0 {
			v.report('Directive @${d.name} must include 1 or more locations.', [d.pos])
		}
		for a in d.args {
			v.name(a.name, a.pos)
			if !v.s.is_input_type(a.typ) {
				v.report('The type of @${d.name}(${a.name}:) must be Input Type but got: ${print_type(a.typ)}.',
					[a.pos])
			}
			if a.typ is NonNullType && a.default_value == none && a.deprecation_reason != none {
				v.report('Required argument @${d.name}(${a.name}:) cannot be deprecated.', [
					a.pos,
				])
			}
		}
	}
}

fn (mut v SchemaValidator) types() {
	for name in v.s.type_names {
		t := v.s.types[name] or { continue }
		if name in introspection_types || name in specified_scalars {
			continue
		}
		v.name(t.name, t.pos)
		match t.kind {
			.object, .@interface {
				v.fields(t)
				v.interfaces(t)
			}
			.@union {
				v.union_members(t)
			}
			.@enum {
				if t.values.len == 0 {
					v.report('Enum type ${t.name} must define one or more values.', [t.pos])
				}
				for value in t.values {
					v.name(value.name, value.pos)
				}
			}
			.input_object {
				v.input_fields(t)
				v.input_cycles(t)
			}
			.scalar {}
		}
	}
}

fn (mut v SchemaValidator) fields(t Type) {
	if t.fields.len == 0 {
		v.report('Type ${t.name} must define one or more fields.', [t.pos])
	}
	for f in t.fields {
		v.name(f.name, f.pos)
		if !v.s.is_output(f.typ) {
			v.report('The type of ${t.name}.${f.name} must be Output Type but got: ${print_type(f.typ)}.',
				[f.typ.pos()])
		}
		for a in f.args {
			v.name(a.name, a.pos)
			if !v.s.is_input_type(a.typ) {
				v.report('The type of ${t.name}.${f.name}(${a.name}:) must be Input Type but got: ${print_type(a.typ)}.',
					[a.typ.pos()])
			}
			if a.typ is NonNullType && a.default_value == none && a.deprecation_reason != none {
				v.report('Required argument ${t.name}.${f.name}(${a.name}:) cannot be deprecated.',
					[a.pos])
			}
		}
	}
}

fn (mut v SchemaValidator) interfaces(t Type) {
	mut seen := map[string]bool{}
	for iface_name in t.interfaces {
		iface := v.s.get_type(iface_name) or { continue }
		if iface.kind != .@interface {
			v.report('Type ${t.name} must only implement Interface types, it cannot implement ${iface_name}.',
				[t.pos])
			continue
		}
		if iface_name == t.name {
			v.report('Type ${t.name} cannot implement itself because it would create a circular reference.',
				[t.pos])
			continue
		}
		if iface_name in seen {
			v.report('Type ${t.name} can only implement ${iface_name} once.', [t.pos])
			continue
		}
		seen[iface_name] = true
		for transitive in iface.interfaces {
			if transitive !in t.interfaces {
				v.report(if transitive == t.name {
					'Type ${t.name} cannot implement ${iface_name} because it would create a circular reference.'
				} else {
					'Type ${t.name} must implement ${transitive} because it is implemented by ${iface_name}.'
				}, [iface.pos, t.pos])
			}
		}
		v.implements(t, iface)
	}
}

fn (mut v SchemaValidator) implements(t Type, iface Type) {
	for iface_field in iface.fields {
		name := iface_field.name
		type_field := t.field(name) or {
			v.report('Interface field ${iface.name}.${name} expected but ${t.name} does not provide it.',
				[iface_field.pos, t.pos])
			continue
		}
		if !v.s.is_type_sub_type_of(type_field.typ, iface_field.typ) {
			v.report('Interface field ${iface.name}.${name} expects type ${print_type(iface_field.typ)} but ${t.name}.${name} is type ${print_type(type_field.typ)}.',
				[iface_field.typ.pos(), type_field.typ.pos()])
		}
		for iface_arg in iface_field.args {
			type_arg := type_field.arg(iface_arg.name) or {
				v.report('Interface field argument ${iface.name}.${name}(${iface_arg.name}:) expected but ${t.name}.${name} does not provide it.',
					[iface_arg.pos, type_field.pos])
				continue
			}
			if print_type(iface_arg.typ) != print_type(type_arg.typ) {
				v.report('Interface field argument ${iface.name}.${name}(${iface_arg.name}:) expects type ${print_type(iface_arg.typ)} but ${t.name}.${name}(${iface_arg.name}:) is type ${print_type(type_arg.typ)}.',
					[iface_arg.typ.pos(), type_arg.typ.pos()])
			}
		}
		for type_arg in type_field.args {
			if _ := iface_field.arg(type_arg.name) {
				continue
			}
			if type_arg.typ is NonNullType && type_arg.default_value == none {
				v.report('Object field ${t.name}.${name} includes required argument ${type_arg.name} that is missing from the Interface field ${iface.name}.${name}.',
					[type_arg.pos, iface_field.pos])
			}
		}
	}
}

fn (mut v SchemaValidator) union_members(t Type) {
	if t.possible_types.len == 0 {
		v.report('Union type ${t.name} must define one or more member types.', [t.pos])
	}
	mut seen := map[string]bool{}
	for member in t.possible_types {
		if member in seen {
			v.report('Union type ${t.name} can only include type ${member} once.', [t.pos])
			continue
		}
		seen[member] = true
		m := v.s.get_type(member) or { continue }
		if m.kind != .object {
			v.report('Union type ${t.name} can only include Object types, it cannot include ${member}.',
				[t.pos])
		}
	}
}

fn (mut v SchemaValidator) input_fields(t Type) {
	if t.input_fields.len == 0 {
		v.report('Input Object type ${t.name} must define one or more fields.', [t.pos])
	}
	for f in t.input_fields {
		v.name(f.name, f.pos)
		if !v.s.is_input_type(f.typ) {
			v.report('The type of ${t.name}.${f.name} must be Input Type but got: ${print_type(f.typ)}.',
				[f.typ.pos()])
		}
		if f.typ is NonNullType && f.default_value == none && f.deprecation_reason != none {
			v.report('Required input field ${t.name}.${f.name} cannot be deprecated.', [f.pos])
		}
		if t.is_one_of {
			if f.typ is NonNullType {
				v.report('OneOf input field ${t.name}.${f.name} must be nullable.', [
					f.typ.pos(),
				])
			}
			if f.default_value != none {
				v.report('OneOf input field ${t.name}.${f.name} cannot have a default value.',
					[f.pos])
			}
		}
	}
}

// input_cycles reports an input object that contains itself through non-null
// fields, which no value could satisfy.
fn (mut v SchemaValidator) input_cycles(t Type) {
	if t.name in v.visited {
		return
	}
	v.visited[t.name] = true
	v.path_index[t.name] = v.field_path.len
	for f in t.input_fields {
		if f.typ is NonNullType {
			inner := f.typ.typ
			if inner is NamedType {
				target := v.s.get_type(inner.name.value) or { continue }
				if target.kind != .input_object {
					continue
				}
				v.field_path << f
				if cycle_index := v.path_index[target.name] {
					cycle := v.field_path[cycle_index..].clone()
					v.report('Cannot reference Input Object "${target.name}" within itself through a series of non-null fields: "${cycle.map(it.name).join('.')}".',
						cycle.map(it.pos))
				} else {
					v.input_cycles(target)
				}
				v.field_path.pop()
			}
		}
	}
	v.path_index.delete(t.name)
}
