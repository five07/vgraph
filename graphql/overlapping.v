module graphql

// OverlappingFieldsCanBeMergedRule: fields with the same response key must be
// mergeable. Ported from graphql-js, which identifies selection sets and their
// field maps by object identity; here a selection set is identified by where it
// starts in the document, which is unique.

// NodeAndDef is a field selection, the type it was selected on, and its
// definition when the type has one.
struct NodeAndDef {
	parent_type string // '' when unknown
	node        Field
	def         ?FieldDef
}

// FieldMap is graphql-js's `NodeAndDefCollection`: selections by response key,
// keys in the order they first appear, identified by `id`.
struct FieldMap {
	id    int
	keys  []string
	nodes map[string][]NodeAndDef
}

struct FieldsAndFragmentNames {
	fields    FieldMap
	fragments []string
}

struct ConflictReason {
	name    string
	message string           // set for a leaf conflict
	subs    []ConflictReason // set for conflicting subfields
}

struct Conflict {
	reason  ConflictReason
	fields1 []Field
	fields2 []Field
}

struct OverlappingFieldsCanBeMergedRule {
mut:
	cache                map[int]FieldsAndFragmentNames
	compared_field_frags map[string]bool // "fieldmap:fragment" -> mutually exclusive
	compared_frag_pairs  map[string]bool // "a:b" with a < b -> mutually exclusive
}

fn (mut r OverlappingFieldsCanBeMergedRule) enter(mut c ValidationContext, w &Walker, node Node) bool {
	if node is SelectionSet {
		parent := w.info.parent_type() or { Type{} }
		conflicts := r.find_conflicts_within(mut c, parent.name, node)
		for conflict in conflicts {
			mut positions := conflict.fields1.map(it.pos)
			positions << conflict.fields2.map(it.pos)
			c.report('Fields "${conflict.reason.name}" conflict because ${reason_message(conflict.reason)}. Use different aliases on the fields to fetch both if this was intentional.',
				positions)
		}
	}
	return true
}

fn (mut r OverlappingFieldsCanBeMergedRule) leave(mut _ ValidationContext, _ &Walker, _ Node) {}

fn reason_message(reason ConflictReason) string {
	if reason.subs.len > 0 {
		return reason.subs.map('subfields "${it.name}" conflict because ' + reason_message(it)).join(' and ')
	}
	return reason.message
}

fn (mut r OverlappingFieldsCanBeMergedRule) find_conflicts_within(mut c ValidationContext, parent_type string, set SelectionSet) []Conflict {
	mut conflicts := []Conflict{}
	ff := r.fields_and_fragment_names(mut c, parent_type, set)
	r.collect_conflicts_within(mut c, mut conflicts, ff.fields)
	for i, name in ff.fragments {
		r.collect_between_fields_and_fragment(mut c, mut conflicts, false, ff.fields, name)
		for j in i + 1 .. ff.fragments.len {
			r.collect_between_fragments(mut c, mut conflicts, false, name, ff.fragments[j])
		}
	}
	return conflicts
}

fn (mut r OverlappingFieldsCanBeMergedRule) collect_between_fields_and_fragment(mut c ValidationContext, mut conflicts []Conflict, mutually_exclusive bool, field_map FieldMap, fragment_name string) {
	key := '${field_map.id}:${fragment_name}'
	if previous := r.compared_field_frags[key] {
		if mutually_exclusive || previous == mutually_exclusive {
			return
		}
	}
	r.compared_field_frags[key] = mutually_exclusive
	fragment := c.fragment(fragment_name) or { return }
	ff2 := r.referenced_fields_and_fragment_names(mut c, fragment)
	if field_map.id == ff2.fields.id {
		return
	}
	r.collect_conflicts_between(mut c, mut conflicts, mutually_exclusive, field_map, ff2.fields)
	for referenced in ff2.fragments {
		r.collect_between_fields_and_fragment(mut c, mut conflicts, mutually_exclusive,
			field_map, referenced)
	}
}

fn (mut r OverlappingFieldsCanBeMergedRule) collect_between_fragments(mut c ValidationContext, mut conflicts []Conflict, mutually_exclusive bool, name1 string, name2 string) {
	if name1 == name2 {
		return
	}
	key := if name1 < name2 { '${name1}:${name2}' } else { '${name2}:${name1}' }
	if previous := r.compared_frag_pairs[key] {
		if mutually_exclusive || previous == mutually_exclusive {
			return
		}
	}
	r.compared_frag_pairs[key] = mutually_exclusive
	fragment1 := c.fragment(name1) or { return }
	fragment2 := c.fragment(name2) or { return }
	ff1 := r.referenced_fields_and_fragment_names(mut c, fragment1)
	ff2 := r.referenced_fields_and_fragment_names(mut c, fragment2)
	r.collect_conflicts_between(mut c, mut conflicts, mutually_exclusive, ff1.fields, ff2.fields)
	for referenced2 in ff2.fragments {
		r.collect_between_fragments(mut c, mut conflicts, mutually_exclusive, name1, referenced2)
	}
	for referenced1 in ff1.fragments {
		r.collect_between_fragments(mut c, mut conflicts, mutually_exclusive, referenced1, name2)
	}
}

fn (mut r OverlappingFieldsCanBeMergedRule) find_conflicts_between_sub_selection_sets(mut c ValidationContext, mutually_exclusive bool, parent1 string, set1 SelectionSet, parent2 string, set2 SelectionSet) []Conflict {
	mut conflicts := []Conflict{}
	ff1 := r.fields_and_fragment_names(mut c, parent1, set1)
	ff2 := r.fields_and_fragment_names(mut c, parent2, set2)
	r.collect_conflicts_between(mut c, mut conflicts, mutually_exclusive, ff1.fields, ff2.fields)
	for name2 in ff2.fragments {
		r.collect_between_fields_and_fragment(mut c, mut conflicts, mutually_exclusive,
			ff1.fields, name2)
	}
	for name1 in ff1.fragments {
		r.collect_between_fields_and_fragment(mut c, mut conflicts, mutually_exclusive,
			ff2.fields, name1)
	}
	for name1 in ff1.fragments {
		for name2 in ff2.fragments {
			r.collect_between_fragments(mut c, mut conflicts, mutually_exclusive, name1,
				name2)
		}
	}
	return conflicts
}

fn (mut r OverlappingFieldsCanBeMergedRule) collect_conflicts_within(mut c ValidationContext, mut conflicts []Conflict, field_map FieldMap) {
	for key in field_map.keys {
		fields := field_map.nodes[key] or { continue }
		if fields.len > 1 {
			for i in 0 .. fields.len {
				for j in i + 1 .. fields.len {
					if conflict := r.find_conflict(mut c, false, key, fields[i], fields[j]) {
						conflicts << conflict
					}
				}
			}
		}
	}
}

fn (mut r OverlappingFieldsCanBeMergedRule) collect_conflicts_between(mut c ValidationContext, mut conflicts []Conflict, parents_mutually_exclusive bool, map1 FieldMap, map2 FieldMap) {
	for key in map1.keys {
		fields1 := map1.nodes[key] or { continue }
		fields2 := map2.nodes[key] or { continue }
		for f1 in fields1 {
			for f2 in fields2 {
				if conflict := r.find_conflict(mut c, parents_mutually_exclusive, key, f1,
					f2)
				{
					conflicts << conflict
				}
			}
		}
	}
}

fn (mut r OverlappingFieldsCanBeMergedRule) find_conflict(mut c ValidationContext, parents_mutually_exclusive bool, response_name string, field1 NodeAndDef, field2 NodeAndDef) ?Conflict {
	s := c.schema
	node1 := field1.node
	node2 := field2.node
	is_object := fn [s] (name string) bool {
		t := s.get_type(name) or { return false }
		return t.kind == .object
	}
	mutually_exclusive := parents_mutually_exclusive || (field1.parent_type != field2.parent_type
		&& is_object(field1.parent_type) && is_object(field2.parent_type))
	if !mutually_exclusive {
		name1 := node1.name.value
		name2 := node2.name.value
		if name1 != name2 {
			return Conflict{
				reason:  ConflictReason{
					name:    response_name
					message: '"${name1}" and "${name2}" are different fields'
				}
				fields1: [node1]
				fields2: [node2]
			}
		}
		if !same_arguments(node1.arguments, node2.arguments) {
			return Conflict{
				reason:  ConflictReason{
					name:    response_name
					message: 'they have differing arguments'
				}
				fields1: [node1]
				fields2: [node2]
			}
		}
	}
	mut type1 := ?TypeNode(none)
	mut type2 := ?TypeNode(none)
	if d := field1.def {
		type1 = d.typ
	}
	if d := field2.def {
		type2 = d.typ
	}
	if t1 := type1 {
		if t2 := type2 {
			if s.do_types_conflict(t1, t2) {
				return Conflict{
					reason:  ConflictReason{
						name:    response_name
						message: 'they return conflicting types "${print_type(t1)}" and "${print_type(t2)}"'
					}
					fields1: [node1]
					fields2: [node2]
				}
			}
		}
	}
	set1 := node1.selection_set?
	set2 := node2.selection_set?
	named1 := if t1 := type1 { t1.named().name.value } else { '' }
	named2 := if t2 := type2 { t2.named().name.value } else { '' }
	conflicts := r.find_conflicts_between_sub_selection_sets(mut c, mutually_exclusive,
		named1, set1, named2, set2)
	if conflicts.len > 0 {
		mut fields1 := [node1]
		mut fields2 := [node2]
		for cf in conflicts {
			fields1 << cf.fields1
			fields2 << cf.fields2
		}
		return Conflict{
			reason:  ConflictReason{
				name: response_name
				subs: conflicts.map(it.reason)
			}
			fields1: fields1
			fields2: fields2
		}
	}
	return none
}

fn same_arguments(args1 []Argument, args2 []Argument) bool {
	if args1.len == 0 {
		return args2.len == 0
	}
	if args2.len == 0 || args1.len != args2.len {
		return false
	}
	mut values2 := map[string]ValueNode{}
	for a in args2 {
		values2[a.name.value] = a.value
	}
	for a in args1 {
		v2 := values2[a.name.value] or { return false }
		if print_value(sort_value_node(a.value)) != print_value(sort_value_node(v2)) {
			return false
		}
	}
	return true
}

// sort_value_node sorts the fields of object values, at every depth, so equal
// values print the same.
fn sort_value_node(v ValueNode) ValueNode {
	match v {
		ObjectValue {
			mut fields := v.fields.map(ObjectField{
				...it
				value: sort_value_node(it.value)
			})
			fields.sort_with_compare(fn (a &ObjectField, b &ObjectField) int {
				return natural_compare(a.name.value, b.name.value)
			})
			return ObjectValue{
				...v
				fields: fields
			}
		}
		ListValue {
			return ListValue{
				...v
				values: v.values.map(sort_value_node(it))
			}
		}
		else {
			return v
		}
	}
}

fn (s &Schema) do_types_conflict(t1 TypeNode, t2 TypeNode) bool {
	if t1 is ListType {
		return if t2 is ListType { s.do_types_conflict(t1.typ, t2.typ) } else { true }
	}
	if t2 is ListType {
		return true
	}
	if t1 is NonNullType {
		return if t2 is NonNullType { s.do_types_conflict(t1.typ, t2.typ) } else { true }
	}
	if t2 is NonNullType {
		return true
	}
	n1 := t1.named().name.value
	n2 := t2.named().name.value
	leaf1 := (s.get_type(n1) or { Type{} }).is_leaf() && n1 in s.types
	leaf2 := (s.get_type(n2) or { Type{} }).is_leaf() && n2 in s.types
	if leaf1 || leaf2 {
		return n1 != n2
	}
	return false
}

fn (mut r OverlappingFieldsCanBeMergedRule) fields_and_fragment_names(mut c ValidationContext, parent_type string, set SelectionSet) FieldsAndFragmentNames {
	if cached := r.cache[set.pos] {
		return cached
	}
	mut keys := []string{}
	mut nodes := map[string][]NodeAndDef{}
	mut fragment_names := []string{}
	collect_fields_and_fragment_names(c.schema, parent_type, set, mut keys, mut nodes, mut
		fragment_names)
	result := FieldsAndFragmentNames{
		fields:    FieldMap{
			id:    set.pos
			keys:  keys
			nodes: nodes
		}
		fragments: fragment_names
	}
	r.cache[set.pos] = result
	return result
}

fn (mut r OverlappingFieldsCanBeMergedRule) referenced_fields_and_fragment_names(mut c ValidationContext, fragment FragmentDefinition) FieldsAndFragmentNames {
	if cached := r.cache[fragment.selection_set.pos] {
		return cached
	}
	name := fragment.type_condition.name.value
	parent := if name in c.schema.types { name } else { '' }
	return r.fields_and_fragment_names(mut c, parent, fragment.selection_set)
}

fn collect_fields_and_fragment_names(s &Schema, parent_type string, set SelectionSet, mut keys []string, mut nodes map[string][]NodeAndDef, mut fragment_names []string) {
	for sel in set.selections {
		match sel {
			Field {
				mut def := ?FieldDef(none)
				if t := s.get_type(parent_type) {
					if t.kind in [.object, .@interface] {
						def = t.field(sel.name.value)
					}
				}
				key := sel.response_key()
				if key !in nodes {
					keys << key
				}
				nodes[key] << NodeAndDef{
					parent_type: parent_type
					node:        sel
					def:         def
				}
			}
			FragmentSpread {
				if sel.name.value !in fragment_names {
					fragment_names << sel.name.value
				}
			}
			InlineFragment {
				mut inline_type := parent_type
				if cond := sel.type_condition {
					inline_type = if cond.name.value in s.types { cond.name.value } else { '' }
				}
				collect_fields_and_fragment_names(s, inline_type, sel.selection_set, mut
					keys, mut nodes, mut fragment_names)
			}
		}
	}
}
