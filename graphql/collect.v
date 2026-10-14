module graphql

// FieldGroup is the fields of a selection set that share a response key, as
// graphql-js's `collectFields` groups them.
pub struct FieldGroup {
pub:
	key    string
	fields []Field
}

// collect_fields returns the fields a selection set selects on an object of type
// `runtime_type`, grouped by response key in the order they first appear,
// following fragments whose type condition matches and honoring `@skip` and
// `@include`.
pub fn (s &Schema) collect_fields(fragments map[string]FragmentDefinition, variables map[string]Value, runtime_type string, set SelectionSet) []FieldGroup {
	mut groups := []FieldGroup{}
	mut index := map[string]int{}
	mut visited := map[string]bool{}
	s.collect_fields_into(fragments, variables, runtime_type, set, mut groups, mut index, mut
		visited)
	return groups
}

fn (s &Schema) collect_fields_into(fragments map[string]FragmentDefinition, variables map[string]Value, runtime_type string, set SelectionSet, mut groups []FieldGroup, mut index map[string]int, mut visited map[string]bool) {
	for sel in set.selections {
		match sel {
			Field {
				if !s.should_include(variables, sel.directives) {
					continue
				}
				key := sel.response_key()
				if i := index[key] {
					mut fields := groups[i].fields.clone()
					fields << sel
					groups[i] = FieldGroup{
						key:    key
						fields: fields
					}
				} else {
					index[key] = groups.len
					groups << FieldGroup{
						key:    key
						fields: [sel]
					}
				}
			}
			InlineFragment {
				if !s.should_include(variables, sel.directives)
					|| !s.fragment_condition_matches(sel.type_condition, runtime_type) {
					continue
				}
				s.collect_fields_into(fragments, variables, runtime_type, sel.selection_set, mut
					groups, mut index, mut visited)
			}
			FragmentSpread {
				name := sel.name.value
				if name in visited || !s.should_include(variables, sel.directives) {
					continue
				}
				visited[name] = true
				fragment := fragments[name] or { continue }
				if !s.fragment_condition_matches(fragment.type_condition, runtime_type) {
					continue
				}
				s.collect_fields_into(fragments, variables, runtime_type, fragment.selection_set, mut
					groups, mut index, mut visited)
			}
		}
	}
}

// should_include applies `@skip(if:)` and `@include(if:)`.
fn (s &Schema) should_include(variables map[string]Value, directives []Directive) bool {
	for d in directives {
		if d.name.value !in ['skip', 'include'] {
			continue
		}
		mut condition := false
		for a in d.arguments {
			if a.name.value == 'if' {
				value := s.value_from_ast(a.value, NonNullType{
					typ: NamedType{
						name: Name{
							value: 'Boolean'
						}
					}
				}, variables) or { Value(false) }
				condition = value is bool && value as bool
			}
		}
		if d.name.value == 'skip' && condition {
			return false
		}
		if d.name.value == 'include' && !condition {
			return false
		}
	}
	return true
}

fn (s &Schema) fragment_condition_matches(condition ?NamedType, runtime_type string) bool {
	cond := condition or { return true }
	name := cond.name.value
	if name == runtime_type {
		return true
	}
	t := s.get_type(name) or { return false }
	if t.is_abstract() {
		return s.is_sub_type(name, runtime_type)
	}
	return false
}
