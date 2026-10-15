module graphql

import context

// Source is an object being resolved: the root value, or whatever a resolver
// returned for an object field. Any V value can be one; resolvers smartcast it
// back (`if p is ArticleNode { ... }`). A `map[string]Value` resolves its
// fields by key when no resolver is registered.
pub interface Source {}

// Resolved is a resolver's result for one parent: a `Value` for a leaf (or a
// `map[string]Value` object), an `Object` for an object, a list of results, or
// a `FieldError` for that parent alone.
pub type Resolved = FieldError | Object | Value | []Resolved

// Object is an object result: what the next level's resolvers receive as their
// parent, and for an interface or union field, the name of its object type.
pub struct Object {
pub:
	source   Source
	typename string
}

// FieldError fails a field for one parent, with `message` in the response's
// errors; the field becomes null.
pub struct FieldError {
pub:
	message    string
	extensions map[string]Value
}

// obj returns an object result.
pub fn obj(source Source) Resolved {
	return Object{
		source: source
	}
}

// obj_of returns an object result whose object type is `typename`, for an
// interface or union field.
pub fn obj_of(typename string, source Source) Resolved {
	return Object{
		source:   source
		typename: typename
	}
}

// list returns a list result.
pub fn list(items []Resolved) Resolved {
	return items
}

// Resolver resolves one field for every parent at a level at once: it returns
// one result per parent, in order. An error fails the field for all of them.
// `ctx` is the request's context: the app's own values, such as the signed-in
// user, ride in it (`context.with_value`), as does its trace.
pub type Resolver = fn (ctx context.Context, info FieldInfo, parents []Source) ![]Resolved

// TypeResolver names the object type of an interface or union value, for
// results that are not an `Object` with a `typename`.
pub type TypeResolver = fn (source Source) string

// FieldInfo describes the field a resolver is resolving.
pub struct FieldInfo {
pub:
	parent_type  string
	field_name   string
	response_key string
	args         map[string]Value // coerced, with defaults
	nodes        []Field          // the field's selections, merged
	return_type  TypeNode
	operation    OperationType
	variables    map[string]Value
	schema       &Schema
	fragments    map[string]FragmentDefinition // the request's, by name
}

// arg returns the argument `name`, or null.
pub fn (i &FieldInfo) arg(name string) Value {
	return i.args[name] or { null }
}

// selected reports whether the field's selection set asks for `name`,
// directly or in a fragment.
pub fn (i &FieldInfo) selected(name string) bool {
	for f in i.nodes {
		if set := f.selection_set {
			if selection_has(set, name, i) {
				return true
			}
		}
	}
	return false
}

fn selection_has(set SelectionSet, name string, i &FieldInfo) bool {
	for sel in set.selections {
		match sel {
			Field {
				if sel.name.value == name {
					return true
				}
			}
			InlineFragment {
				if selection_has(sel.selection_set, name, i) {
					return true
				}
			}
			FragmentSpread {
				if def := i.fragments[sel.name.value] {
					if selection_has(def.selection_set, name, i) {
						return true
					}
				}
			}
		}
	}
	return false
}

// Transaction runs a request's mutations together: `begin` before the first,
// then `commit`, or `rollback` when any of them failed. `begin` returns the
// context the mutations' resolvers get, which can carry the transaction, such
// as its connection, as a value (`context.with_value`); `commit` and
// `rollback` get it back. A connection that implements
// `orm.TransactionalConnection` fits through a small adapter.
pub interface Transaction {
	begin(ctx context.Context) !context.Context
	commit(ctx context.Context) !
	rollback(ctx context.Context) !
}

// Request is a GraphQL request.
pub struct Request {
pub:
	query          string
	operation_name string
	variables      map[string]Value
}

// Response is a GraphQL response. `data` is `none` when execution didn't
// start, as after a syntax or validation error.
pub struct Response {
pub:
	data   ?Value
	errors []GraphQLError
	// request_error is set when the request failed before execution: it was
	// unparsable, invalid, or its variables were.
	request_error bool
}

// to_value returns the response as it is sent: `errors` first when there are
// any, then `data`.
pub fn (r Response) to_value() Value {
	mut out := map[string]Value{}
	if r.errors.len > 0 {
		out['errors'] = Value(r.errors.map(it.to_value()))
	}
	if data := r.data {
		out['data'] = data
	}
	return Value(out)
}

// json returns the response as JSON.
pub fn (r Response) json() string {
	return r.to_value().json()
}

// Server is a schema with its resolvers, ready to execute requests.
@[heap]
pub struct Server {
pub mut:
	schema         Schema
	resolvers      map[string]Resolver     // by `Type.field`
	type_resolvers map[string]TypeResolver // by interface or union
	root           Source = map[string]Value{}
	validation     ValidateOptions
	parse_options  ParseOptions
	transaction    ?Transaction
}

// Server.new builds a schema from SDL, and returns a server with no resolvers.
pub fn Server.new(sdl string) !&Server {
	schema := build_schema(sdl)!
	errors := validate_schema(schema)
	if errors.len > 0 {
		return error(errors.map(it.message).join('\n\n'))
	}
	return &Server{
		schema: schema
	}
}

// resolve registers the resolver of `type_name.field`.
pub fn (mut s Server) resolve(type_name string, field string, resolver Resolver) {
	s.resolvers['${type_name}.${field}'] = resolver
}

// resolve_each registers a resolver of `type_name.field` that resolves one
// parent at a time.
pub fn (mut s Server) resolve_each(type_name string, field string, f fn (ctx context.Context, info FieldInfo, parent Source) !Resolved) {
	s.resolvers['${type_name}.${field}'] = fn [f] (ctx context.Context, info FieldInfo, parents []Source) ![]Resolved {
		mut out := []Resolved{cap: parents.len}
		for p in parents {
			out << f(ctx, info, p) or {
				Resolved(FieldError{
					message: err.msg()
				})
			}
		}
		return out
	}
}

// scalar sets the coercion of the custom scalar `name`.
pub fn (mut s Server) scalar(name string, scalar Scalar) {
	s.schema.scalars[name] = scalar
}

// execute runs a request: parse, validate, coerce variables, execute. Every
// resolver gets `ctx`, or for a mutation in a transaction, what `begin` made of it.
pub fn (s &Server) execute(req Request, ctx context.Context) Response {
	doc := parse(req.query, s.parse_options) or {
		return request_failed(err)
	}
	errors := validate(&s.schema, &doc, s.validation)
	if errors.len > 0 {
		return Response{
			errors:        errors
			request_error: true
		}
	}
	return s.execute_document(doc, req.operation_name, req.variables, ctx)
}

fn request_failed(err IError) Response {
	if err is GraphQLError {
		return Response{
			errors:        [err]
			request_error: true
		}
	}
	return Response{
		errors:        [GraphQLError{
			message: err.msg()
		}]
		request_error: true
	}
}

// operation_of returns the operation to run: the one named `name`, or the only
// one.
pub fn operation_of(doc &Document, name string) !OperationDefinition {
	mut found := ?OperationDefinition(none)
	for def in doc.definitions {
		if def is OperationDefinition {
			if name == '' {
				if found != none {
					return error('Must provide operation name if query contains multiple operations.')
				}
				found = def
			} else if n := def.name {
				if n.value == name {
					found = def
				}
			}
		}
	}
	return found or {
		if name != '' {
			return error('Unknown operation named "${name}".')
		}
		return error('Must provide an operation.')
	}
}

// execute_document runs an operation of a validated document.
pub fn (s &Server) execute_document(doc &Document, operation_name string, inputs map[string]Value, ctx context.Context) Response {
	op := operation_of(doc, operation_name) or { return request_failed(err) }
	variables := s.schema.coerce_variable_values(doc, op.variable_definitions, inputs) or {
		return Response{
			errors:        (err as VariableErrors).errors
			request_error: true
		}
	}
	if op.operation == .subscription {
		return Response{
			errors:        [located(doc, op.pos, 'Subscriptions are not supported.')]
			request_error: true
		}
	}
	root_name := s.schema.root_type(op.operation) or {
		return Response{
			errors: [located(doc, op.pos, 'Schema is not configured to execute ${op.operation} operation.')]
		}
	}
	root_type := s.schema.get_type(root_name) or {
		return Response{
			errors: [located(doc, op.pos, 'Schema is not configured to execute ${op.operation} operation.')]
		}
	}
	mut fragments := map[string]FragmentDefinition{}
	for def in doc.definitions {
		if def is FragmentDefinition {
			fragments[def.name.value] = def
		}
	}
	mut ex := Execution{
		server:    s
		doc:       doc
		ctx:       ctx
		operation: op
		variables: variables
		fragments: fragments
	}
	ex.slots << Slot{
		kind:   .object
		parent: -1
	}
	// a request's mutations run in one transaction, when the server has one
	tx := if op.operation == .mutation { s.transaction } else { ?Transaction(none) }
	if t := tx {
		ex.ctx = t.begin(ctx) or {
			return Response{
				errors: [GraphQLError{
					message: 'Could not start a transaction: ${err.msg()}'
				}]
			}
		}
	}
	ex.execute_selection(root_type, [op.selection_set], [Item{
		source: s.root
		slot:   0
	}])
	if t := tx {
		if ex.errors.len > 0 {
			t.rollback(ex.ctx) or {
				ex.errors << GraphQLError{
					message: 'Could not roll back the transaction: ${err.msg()}'
				}
			}
		} else {
			t.commit(ex.ctx) or {
				ex.errors << GraphQLError{
					message: 'Could not commit the transaction: ${err.msg()}'
				}
			}
		}
	}
	return Response{
		data:   ex.render(0)
		errors: ex.errors
	}
}

// VariableErrors are the problems with a request's variables.
pub struct VariableErrors {
	Error
pub:
	errors []GraphQLError
}

// msg joins the problems.
pub fn (e VariableErrors) msg() string {
	return e.errors.map(it.message).join('\n')
}

// coerce_variable_values checks a request's variables against the operation's
// definitions, and fills in defaults, as graphql-js's `getVariableValues` does.
pub fn (s &Schema) coerce_variable_values(doc &Document, defs []VariableDefinition, inputs map[string]Value) !map[string]Value {
	mut errors := []GraphQLError{}
	mut out := map[string]Value{}
	for def in defs {
		name := def.variable.name.value
		if !s.is_input_type(def.typ) {
			errors << located(doc, def.typ.pos(), 'Variable "$${name}" expected value of type "${print_type(def.typ)}" which cannot be used as an input type.')
			continue
		}
		value := inputs[name] or {
			if d := def.default_value {
				if coerced := s.value_from_ast(d, def.typ, map[string]Value{}) {
					out[name] = coerced
				}
			} else if def.typ is NonNullType {
				errors << located(doc, def.pos, 'Variable "$${name}" of required type "${print_type(def.typ)}" was not provided.')
			}
			continue
		}
		if value is Null && def.typ is NonNullType {
			errors << located(doc, def.pos, 'Variable "$${name}" of non-null type "${print_type(def.typ)}" must not be null.')
			continue
		}
		mut problems := []InputProblem{}
		coerced := s.coerce_input_value(value, def.typ, []PathItem{}, mut problems)
		for p in problems {
			mut prefix := 'Variable "$${name}" got invalid value ${inspect(p.value)}'
			if p.path.len > 0 {
				prefix += ' at "${name}${print_path(p.path)}"'
			}
			errors << located(doc, def.pos, prefix + '; ' + p.message)
		}
		if problems.len == 0 {
			out[name] = coerced
		}
	}
	if errors.len > 0 {
		return VariableErrors{
			errors: errors
		}
	}
	return out
}

fn print_path(path []PathItem) string {
	return path.map(match it {
		int { '[${it}]' }
		string { '.${it}' }
	}).join('')
}

struct InputProblem {
	path    []PathItem
	value   Value
	message string
}

// coerce_input_value coerces a variable's value to `t`, as graphql-js's
// `coerceInputValue` does, recording each problem in `problems`.
pub fn (s &Schema) coerce_input_value(value Value, t TypeNode, path []PathItem, mut problems []InputProblem) Value {
	if t is NonNullType {
		if value !is Null {
			return s.coerce_input_value(value, t.typ, path, mut problems)
		}
		problems << InputProblem{
			path:    path
			value:   value
			message: 'Expected non-nullable type "${print_type(t)}" not to be null.'
		}
		return null
	}
	if value is Null {
		return null
	}
	if t is ListType {
		if value is []Value {
			mut out := []Value{}
			for i, item in value {
				mut item_path := path.clone()
				item_path << PathItem(i)
				out << s.coerce_input_value(item, t.typ, item_path, mut problems)
			}
			return Value(out)
		}
		return Value([s.coerce_input_value(value, t.typ, path, mut problems)])
	}
	named := t as NamedType
	typ := s.get_type(named.name.value) or { return null }
	match typ.kind {
		.input_object {
			if value !is map[string]Value {
				problems << InputProblem{
					path:    path
					value:   value
					message: 'Expected type "${typ.name}" to be an object.'
				}
				return null
			}
			input := value as map[string]Value
			mut out := map[string]Value{}
			for field in typ.input_fields {
				field_value := input[field.name] or {
					if d := field.default_value {
						out[field.name] = d
					} else if field.typ is NonNullType {
						problems << InputProblem{
							path:    path
							value:   value
							message: 'Field "${field.name}" of required type "${print_type(field.typ)}" was not provided.'
						}
					}
					continue
				}
				mut field_path := path.clone()
				field_path << PathItem(field.name)
				out[field.name] = s.coerce_input_value(field_value, field.typ, field_path, mut
					problems)
			}
			for key, _ in input {
				if _ := typ.input_field(key) {
				} else {
					problems << InputProblem{
						path:    path
						value:   value
						message: 'Field "${key}" is not defined by type "${typ.name}".' +
							did_you_mean('', suggestion_list(key, typ.input_fields.map(it.name)))
					}
				}
			}
			if typ.is_one_of {
				if out.len != 1 {
					problems << InputProblem{
						path:    path
						value:   value
						message: 'Exactly one key must be specified for OneOf type "${typ.name}".'
					}
				}
				for key, v in out {
					if v is Null {
						mut key_path := path.clone()
						key_path << PathItem(key)
						problems << InputProblem{
							path:    key_path
							value:   v
							message: 'Field "${key}" must be non-null.'
						}
					}
					break
				}
			}
			return Value(out)
		}
		.@enum {
			if value !is string {
				value_str := inspect(value)
				problems << InputProblem{
					path:    path
					value:   value
					message: 'Enum "${typ.name}" cannot represent non-string value: ${value_str}.' +
						did_you_mean('the enum value', suggestion_list(value_str, typ.values.map(it.name)))
				}
				return null
			}
			name := value as string
			if _ := typ.enum_value(name) {
				return value
			}
			problems << InputProblem{
				path:    path
				value:   value
				message: 'Value "${name}" does not exist in "${typ.name}" enum.' +
					did_you_mean('the enum value', suggestion_list(name, typ.values.map(it.name)))
			}
			return null
		}
		.scalar {
			return s.parse_scalar_value(typ.name, value) or {
				message := if typ.name in specified_scalars || err.msg() == '' {
					if err.msg() == '' { 'Expected type "${typ.name}".' } else { err.msg() }
				} else {
					'Expected type "${typ.name}". ${err.msg()}'
				}
				problems << InputProblem{
					path:    path
					value:   value
					message: message
				}
				return null
			}
		}
		else {
			return null
		}
	}
}

// Execution is the state of one operation's execution.
struct Execution {
	server    &Server
	doc       &Document
	operation OperationDefinition
	variables map[string]Value
	fragments map[string]FragmentDefinition
mut:
	ctx    context.Context // the transaction's, for a mutation in one
	slots  []Slot
	errors []GraphQLError
}

// Item is an object waiting to have its fields resolved: its source, and the
// slot of its result.
struct Item {
	source Source
	slot   int
}

enum SlotKind {
	pending
	null
	leaf
	object
	list
}

// Slot is one value of the response being built: the response is a tree of
// slots, so a field that fails can null its nearest nullable ancestor.
struct Slot {
mut:
	kind     SlotKind
	value    Value
	keys     []string
	children []int
	parent   int
	key      string // the field's key in the parent object, or ''
	index    int    // the item's index in the parent list
	non_null bool   // a null here nulls the parent
}

fn (mut ex Execution) new_slot(parent int, key string, index int, non_null bool) int {
	ex.slots << Slot{
		parent:   parent
		key:      key
		index:    index
		non_null: non_null
	}
	return ex.slots.len - 1
}

// set_null makes a slot null, and its parent too when the slot is non-null.
fn (mut ex Execution) set_null(slot int) {
	mut i := slot
	for i >= 0 {
		ex.slots[i].kind = .null
		if !ex.slots[i].non_null {
			return
		}
		i = ex.slots[i].parent
	}
}

fn (ex &Execution) path_of(slot int) []PathItem {
	mut path := []PathItem{}
	mut i := slot
	for i > 0 {
		s := ex.slots[i]
		if s.key == '' {
			path.prepend(PathItem(s.index))
		} else {
			path.prepend(PathItem(s.key))
		}
		i = s.parent
	}
	return path
}

fn (mut ex Execution) field_error(slot int, nodes []Field, message string, extensions map[string]Value) {
	ex.errors << GraphQLError{
		message:    message
		locations:  nodes.map(ex.doc.location(it.pos))
		path:       ex.path_of(slot)
		extensions: extensions
	}
	ex.set_null(slot)
}

fn (ex &Execution) render(slot int) Value {
	s := ex.slots[slot]
	return match s.kind {
		.null, .pending {
			null
		}
		.leaf {
			s.value
		}
		.object {
			mut out := map[string]Value{}
			for i, key in s.keys {
				out[key] = ex.render(s.children[i])
			}
			Value(out)
		}
		.list {
			mut out := []Value{cap: s.children.len}
			for child in s.children {
				out << ex.render(child)
			}
			Value(out)
		}
	}
}

// SubBatch is the objects one field produced, of one object type, waiting for
// their own fields.
struct SubBatch {
mut:
	typ   Type
	sets  []SelectionSet
	items []Item
}

// execute_selection resolves the fields that `sets` select on `items`, which
// are all objects of `object_type`: each field once, for all of them, and then
// the objects those fields produced, a field at a time.
fn (mut ex Execution) execute_selection(object_type Type, sets []SelectionSet, items []Item) {
	s := &ex.server.schema
	mut groups := []FieldGroup{}
	mut index := map[string]int{}
	mut visited := map[string]bool{}
	for set in sets {
		s.collect_fields_into(ex.fragments, ex.variables, object_type.name, set, mut groups, mut
			index, mut visited)
	}
	for group in groups {
		ex.execute_field(object_type, group, items)
	}
}

fn (mut ex Execution) execute_field(object_type Type, group FieldGroup, items []Item) {
	s := &ex.server.schema
	node := group.fields[0]
	name := node.name.value
	def := s.field_def(object_type, name) or { return }
	non_null := def.typ is NonNullType
	mut slots := []int{cap: items.len}
	for item in items {
		slot := ex.new_slot(item.slot, group.key, 0, non_null)
		ex.slots[item.slot].keys << group.key
		ex.slots[item.slot].children << slot
		slots << slot
	}
	args := s.argument_values(def.args, node.arguments, ex.variables, ex.doc, node.pos) or {
		for slot in slots {
			ex.field_error(slot, group.fields, err.msg(), map[string]Value{})
		}
		return
	}
	info := FieldInfo{
		parent_type:  object_type.name
		field_name:   name
		response_key: group.key
		args:         args
		nodes:        group.fields
		return_type:  def.typ
		operation:    ex.operation.operation
		variables:    ex.variables
		schema:       s
		fragments:    ex.fragments
	}
	results := ex.resolve(info, items) or {
		for slot in slots {
			ex.field_error(slot, group.fields, err.msg(), map[string]Value{})
		}
		return
	}
	if results.len != items.len {
		for slot in slots {
			ex.field_error(slot, group.fields, 'The resolver of ${object_type.name}.${name} returned ${results.len} results for ${items.len} parents.',
				map[string]Value{})
		}
		return
	}
	mut subs := []SubBatch{}
	mut sub_index := map[string]int{}
	for i, result in results {
		ex.complete(info, def.typ, slots[i], result, mut subs, mut sub_index)
	}
	for sub in subs {
		ex.execute_selection(sub.typ, sub.sets, sub.items)
	}
}

// resolve runs the field's resolver for every parent: a registered one, a
// built-in one for introspection, or the default, which reads a map's key.
fn (mut ex Execution) resolve(info FieldInfo, items []Item) ![]Resolved {
	sources := items.map(it.source)
	if info.field_name == '__typename' {
		return sources.map(Resolved(Value(info.parent_type)))
	}
	if info.parent_type == ex.server.schema.query or { '' } {
		if info.field_name == '__schema' {
			return sources.map(obj(IntroSchema{}))
		}
		if info.field_name == '__type' {
			name := info.arg('name')
			if name is string {
				if _ := ex.server.schema.get_type(name) {
					return sources.map(obj(IntroType{
						typ: NamedType{
							name: Name{
								value: name
							}
						}
					}))
				}
			}
			return sources.map(Resolved(null))
		}
	}
	if info.parent_type in introspection_types {
		return sources.map(introspect(info, it))
	}
	if resolver := ex.server.resolvers['${info.parent_type}.${info.field_name}'] {
		return resolver(ex.ctx, info, sources)!
	}
	return sources.map(default_resolve(info, it))
}

fn default_resolve(info FieldInfo, source Source) Resolved {
	if source is map[string]Value {
		return source[info.field_name] or { null }
	}
	return FieldError{
		message: 'No resolver for ${info.parent_type}.${info.field_name}.'
	}
}

// complete turns a resolver's result into the response at `slot`, as
// graphql-js's `completeValue` does, queueing the objects it finds.
fn (mut ex Execution) complete(info FieldInfo, t TypeNode, slot int, result Resolved, mut subs []SubBatch, mut sub_index map[string]int) {
	if result is FieldError {
		ex.field_error(slot, info.nodes, result.message, result.extensions)
		return
	}
	if t is NonNullType {
		if is_null_result(result) {
			ex.field_error(slot, info.nodes, 'Cannot return null for non-nullable field ${info.parent_type}.${info.field_name}.',
				map[string]Value{})
			return
		}
		ex.complete(info, t.typ, slot, result, mut subs, mut sub_index)
		return
	}
	if is_null_result(result) {
		ex.slots[slot].kind = .null
		return
	}
	if t is ListType {
		items := list_items(result) or {
			ex.field_error(slot, info.nodes, 'Expected Iterable, but did not find one for field "${info.parent_type}.${info.field_name}".',
				map[string]Value{})
			return
		}
		ex.slots[slot].kind = .list
		item_non_null := t.typ is NonNullType
		for i, item in items {
			child := ex.new_slot(slot, '', i, item_non_null)
			ex.slots[slot].children << child
			ex.complete(info, t.typ, child, item, mut subs, mut sub_index)
		}
		return
	}
	s := &ex.server.schema
	named := s.get_type(t.named().name.value) or { return }
	match named.kind {
		.scalar, .@enum {
			value := match result {
				Value { result }
				else { Value(null) }
			}
			if result !is Value {
				ex.field_error(slot, info.nodes, 'Expected a value for leaf field "${info.parent_type}.${info.field_name}", got an object.',
					map[string]Value{})
				return
			}
			serialized := if named.kind == .@enum {
				s.serialize_enum(named, value) or {
					ex.field_error(slot, info.nodes, err.msg(), map[string]Value{})
					return
				}
			} else {
				s.serialize_scalar(named.name, value) or {
					ex.field_error(slot, info.nodes, err.msg(), map[string]Value{})
					return
				}
			}
			if serialized is Null {
				ex.field_error(slot, info.nodes, 'Expected `${named.name}.serialize(${inspect(value)})` to return non-nullable value, returned: null',
					map[string]Value{})
				return
			}
			ex.slots[slot].kind = .leaf
			ex.slots[slot].value = serialized
		}
		.object, .@interface, .@union {
			mut source := Source(map[string]Value{})
			mut typename := ''
			match result {
				Object {
					source = result.source
					typename = result.typename
				}
				Value {
					if result is map[string]Value {
						source = result
						if tn := result['__typename'] {
							if tn is string {
								typename = tn
							}
						}
					} else {
						ex.field_error(slot, info.nodes, 'Expected value of type "${named.name}" but got: ${inspect(result)}.',
							map[string]Value{})
						return
					}
				}
				else {}
			}
			mut runtime := named
			if named.is_abstract() {
				if typename == '' {
					if resolver := ex.server.type_resolvers[named.name] {
						typename = resolver(source)
					}
				}
				if typename == '' {
					ex.field_error(slot, info.nodes, 'Abstract type "${named.name}" must resolve to an Object type at runtime for field "${info.parent_type}.${info.field_name}". Either the "${named.name}" type should provide a "resolveType" function or each possible type should provide an "isTypeOf" function.',
						map[string]Value{})
					return
				}
				runtime = s.get_type(typename) or {
					ex.field_error(slot, info.nodes, 'Abstract type "${named.name}" was resolved to a type "${typename}" that does not exist inside the schema.',
						map[string]Value{})
					return
				}
				if runtime.kind != .object {
					ex.field_error(slot, info.nodes, 'Abstract type "${named.name}" was resolved to a non-object type "${typename}".',
						map[string]Value{})
					return
				}
				if !s.is_sub_type(named.name, typename) {
					ex.field_error(slot, info.nodes, 'Runtime Object type "${typename}" is not a possible type for "${named.name}".',
						map[string]Value{})
					return
				}
			}
			ex.slots[slot].kind = .object
			mut sets := []SelectionSet{}
			for f in info.nodes {
				if set := f.selection_set {
					sets << set
				}
			}
			if i := sub_index[runtime.name] {
				subs[i].items << Item{
					source: source
					slot:   slot
				}
			} else {
				sub_index[runtime.name] = subs.len
				subs << SubBatch{
					typ:   runtime
					sets:  sets
					items: [Item{
						source: source
						slot:   slot
					}]
				}
			}
		}
		.input_object {}
	}
}

fn is_null_result(r Resolved) bool {
	if r is Value {
		return r is Null
	}
	return false
}

fn list_items(r Resolved) ?[]Resolved {
	if r is []Resolved {
		return r
	}
	if r is Value {
		if r is []Value {
			return r.map(Resolved(it))
		}
	}
	return none
}

// serialize_enum returns an enum value's name, or fails as graphql-js does.
fn (s &Schema) serialize_enum(t Type, v Value) !Value {
	if v is string {
		if _ := t.enum_value(v) {
			return v
		}
	}
	return error('Enum "${t.name}" cannot represent value: ${inspect(v)}')
}
