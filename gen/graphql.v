module gen

import graphql
import os
import strings

// The GraphQL half of `vgraph gen`: a schema with entgql's conventions for the
// tables, merged with the project's own `.graphql` files, and a server whose
// resolvers load and write through the generated client.

// GraphqlFile is a `.graphql` file of the project, merged into the schema, or,
// in an `operations` folder, checked against it.
pub struct GraphqlFile {
pub:
	path string // relative to the project, for messages
	text string
}

// is_operations reports whether the file is in an `operations` folder: it
// holds operations, not schema.
fn (f GraphqlFile) is_operations() bool {
	return 'operations' in f.path.split(os.path_separator)#[..-1]
}

// Go's initialisms, which entgql keeps in capitals in field names (`userID`).
const initialisms = ['acl', 'api', 'ascii', 'aws', 'cpu', 'css', 'dns', 'eof', 'gb', 'guid', 'hcl',
	'html', 'http', 'https', 'id', 'ip', 'json', 'kb', 'lhs', 'mac', 'mb', 'qps', 'ram', 'rhs',
	'rpc', 'sla', 'smtp', 'sql', 'ssh', 'sso', 'tcp', 'tls', 'ttl', 'udp', 'ui', 'uid', 'uri',
	'url', 'utf8', 'uuid', 'vm', 'xml', 'xmpp', 'xsrf', 'xss']

// camel returns the GraphQL name of a snake_case name, as entgql derives it
// from Go's: `created_at` is `createdAt`, `user_id` is `userID`.
pub fn camel(name string) string {
	words := name.split('_').filter(it != '')
	if words.len == 0 {
		return name
	}
	mut b := strings.new_builder(name.len)
	b.write_string(words[0])
	for w in words[1..] {
		if w in initialisms {
			b.write_string(w.to_upper())
		} else {
			b.write_string(w[..1].to_upper() + w[1..])
		}
	}
	return b.str()
}

// upper_first returns `name` with its first letter in capitals: `ownerID` is
// `OwnerID`.
fn upper_first(name string) string {
	return if name != '' { name[..1].to_upper() + name[1..] } else { name }
}

// singular returns the singular of an edge's name, as entgql's inflection
// gives it for the inputs' `<edge>IDs`: `pets` is `pet`, `children` `child`.
fn singular(name string) string {
	irregular := {
		'children': 'child'
		'people':   'person'
		'men':      'man'
		'women':    'woman'
		'mice':     'mouse'
		'geese':    'goose'
	}
	for plural, one in irregular {
		if name == plural || name.ends_with('_${plural}') {
			return name.all_before_last(plural) + one
		}
	}
	return match true {
		name.ends_with('ies') && name.len > 3 { name#[..-3] + 'y' }
		name.ends_with('sses') || name.ends_with('xes') || name.ends_with('ches')
			|| name.ends_with('shes') {
			name#[..-2]
		}
		name.ends_with('ss') || name.ends_with('us') || name.ends_with('is') { name }
		name.ends_with('s') { name#[..-1] }
		else { name }
	}
}

// upper_snake returns `CREATED_AT` for `created_at`.
fn upper_snake(name string) string {
	return name.to_upper()
}

// GqlField is a column as a GraphQL field.
struct GqlField {
	name     string // the GraphQL name
	column   Column
	scalar   string // ID, String, Int, Float, Boolean, Time, JSON or an enum type
	nullable bool
	key      bool // the primary key
	foreign  bool // a column a many_to_one edge follows
}

fn (f GqlField) typ() string {
	return if f.nullable { f.scalar } else { f.scalar + '!' }
}

fn gql_scalar(c Column) ?string {
	if c.json_type != '' {
		return 'JSON'
	}
	b := c.base()
	return match true {
		b in int_types { 'Int' }
		b in float_types { 'Float' }
		b == 'bool' { 'Boolean' }
		b == 'string' { 'String' }
		b == 'time.Time' { 'Time' }
		b == 'enum' { 'ENUM' }
		else { none }
	}
}

// gql_enum returns the GraphQL enum type of an enum column, as entgql names it:
// the type, then the field, such as `ArticleStatus`.
fn (i Info) gql_enum(c Column) string {
	return i.gql_type() + pascal(c.field)
}

// pascal returns `ArticleStatus` for `article_status`.
fn pascal(name string) string {
	return name.split('_').map(if it.len > 0 { it[0..1].to_upper() + it[1..] } else { it }).join('')
}

// gql_type returns the table's GraphQL type: its `graphql()` option, or the
// struct's name.
fn (i Info) gql_type() string {
	n := i.table.graphql.type_name
	return if n != '' { n } else { i.entity.struct_name }
}

// gql_root returns the root field listing the table, or '' for none.
fn (i Info) gql_root() string {
	qf := i.table.graphql.query_field
	return match qf {
		'-' { '' }
		'' { camel(i.table.name) }
		else { qf }
	}
}

fn (i Info) relay() bool {
	return i.table.graphql.relay
}

fn (i Info) is_node() bool {
	return i.table.graphql.node
}

// gql_mutations returns the mutations the schema has for the table: none for a
// view.
fn (i Info) gql_mutations() []string {
	return if i.table.view { []string{} } else { i.table.graphql.mutations }
}

// prefix starts the names of the generated functions of the table.
fn (i Info) prefix() string {
	return snake(i.entity.struct_name)
}

// all_gql_fields returns the columns that have a GraphQL type, as fields, but
// those `@[graphql: '-']` hides.
fn (i Info) all_gql_fields() []GqlField {
	mut foreign := map[string]bool{}
	for e in i.table.edges {
		if e.kind == 'many_to_one' {
			foreign[e.column] = true
		}
	}
	mut out := []GqlField{}
	for c in i.table.columns {
		if c.graphql_skip {
			continue
		}
		mut scalar := gql_scalar(c) or { continue }
		if scalar == 'ENUM' {
			scalar = i.gql_enum(c)
		}
		key := c.name == i.table.key
		if key || c.name in foreign {
			scalar = 'ID'
		}
		out << GqlField{
			name:     camel(c.field)
			column:   c
			scalar:   scalar
			nullable: c.nullable
			key:      key
			foreign:  c.name in foreign
		}
	}
	return out
}

// gql_fields returns the fields of the object type: not sensitive, and not
// left out of it.
fn (i Info) gql_fields() []GqlField {
	return i.all_gql_fields().filter(!it.column.sensitive && 'object' !in it.column.graphql_skip_in)
}

// where_fields returns the fields the WhereInput has predicates for.
fn (i Info) where_fields() []GqlField {
	return i.all_gql_fields().filter(!it.column.sensitive && 'where' !in it.column.graphql_skip_in)
}

fn is_list_edge(e Edge) bool {
	return e.kind in ['one_to_many', 'many_to_many']
}

// gql_edges returns the edges the schema has: not hidden, to visible tables.
fn (i Info) gql_edges(infos map[string]Info) []Edge {
	return i.table.edges.filter(!it.graphql_skip
		&& !(infos[it.to] or { Info{} }).table.graphql_skip)
}

// OrderField is a value of the OrderField enum: a column, or an SQL expression
// of an edge, of the V type `typ`.
struct OrderField {
	name   string
	column string
	expr   string
	typ    string
}

// order_fields returns the values of the table's OrderField enum: its fields,
// the number of each list edge's targets, and the fields unique edges name.
fn (i Info) order_fields(infos map[string]Info) []OrderField {
	mut out := []OrderField{}
	for f in i.all_gql_fields() {
		c := f.column
		if f.scalar == 'JSON' || c.sensitive || 'order' in c.graphql_skip_in || c.order_field == '-' {
			continue
		}
		out << OrderField{
			name:   if c.order_field != '' { c.order_field } else { upper_snake(c.field) }
			column: c.name
			typ:    c.typ
		}
	}
	for e in i.gql_edges(infos) {
		target := infos[e.to] or { continue }
		if is_list_edge(e) {
			out << OrderField{
				name: '${upper_snake(e.name)}_COUNT'
				expr: order_sql(i, e, target, '')
				typ:  'int'
			}
		} else if e.order_field != '' {
			c := target.table.column(e.order_field) or { continue }
			out << OrderField{
				name: '${upper_snake(e.name)}_${upper_snake(c.field)}'
				expr: order_sql(i, e, target, c.name)
				typ:  c.typ
			}
		}
	}
	return out
}

// predicates returns the WhereInput predicates of a field: the suffixes after
// its name, in entgql's order.
fn (f GqlField) predicates() []string {
	if f.scalar == 'JSON' {
		return if f.nullable { ['IsNil', 'NotNil'] } else { []string{} }
	}
	mut out := ['', 'NEQ']
	match true {
		f.scalar == 'ID' {
			out << ['In', 'NotIn']
			if f.key {
				out << ['GT', 'GTE', 'LT', 'LTE']
			}
		}
		f.column.base() == 'enum' {
			out << ['In', 'NotIn']
		}
		f.scalar == 'String' {
			out << ['In', 'NotIn', 'GT', 'GTE', 'LT', 'LTE', 'Contains', 'HasPrefix', 'HasSuffix']
		}
		f.scalar in ['Int', 'Float', 'Time'] {
			out << ['In', 'NotIn', 'GT', 'GTE', 'LT', 'LTE']
		}
		else {}
	}
	if f.nullable {
		out << ['IsNil', 'NotNil']
	}
	if f.scalar == 'String' {
		out << ['EqualFold', 'ContainsFold']
	}
	return out
}

fn predicate_type(f GqlField, suffix string) string {
	return match suffix {
		'In', 'NotIn' { '[${f.scalar}!]' }
		'IsNil', 'NotNil' { 'Boolean' }
		else { f.scalar }
	}
}

// list_args returns the arguments of a list of `target`: a connection's, or
// `limit` and `offset`.
fn list_args(target Info) string {
	t := target.gql_type()
	if target.relay() {
		return 'after: Cursor, first: Int, before: Cursor, last: Int, orderBy: [${t}Order!], where: ${t}WhereInput'
	}
	return 'where: ${t}WhereInput, orderBy: [${t}Order!], limit: Int, offset: Int'
}

// list_type returns the type of a list of `target`.
fn list_type(target Info, root bool) string {
	if target.relay() {
		return '${target.gql_type()}Connection!'
	}
	return if root { '[${target.gql_type()}!]!' } else { '[${target.gql_type()}!]' }
}

// description returns a GraphQL description of `text`, indented, or '' when
// there is none.
fn description(text string, indent string) string {
	if text == '' {
		return ''
	}
	escaped := text.replace('"""', '\\"""')
	if escaped.contains('\n') || escaped.ends_with('"') {
		return '${indent}"""\n${escaped.split('\n').map(indent + it).join('\n')}\n${indent}"""\n'
	}
	return '${indent}"""${escaped}"""\n'
}

// field_suffix returns what follows a field's type: `@deprecated` and the
// field's own directives.
fn field_suffix(deprecated string, directives []string, with_directives bool) string {
	mut out := ''
	if deprecated != '' {
		out += ' @deprecated(reason: "${deprecated.replace('\\', '\\\\').replace('"', '\\"')}")'
	}
	if with_directives && directives.len > 0 {
		out += ' ' + directives.join(' ')
	}
	return out
}

// InputField is a field of a mutation's input, with its V field in the
// table's `Create<T>Input` or `Update<T>Input`, and what it sets.
struct InputField {
	name     string // the GraphQL name
	v        string // the V field
	gql_type string // the GraphQL type
	v_type   string // the V field's type
	kind     InputKind
	column   Column
	edge     Edge
	target   Info
	doc      string
}

enum InputKind {
	column       // a column's value
	clear_column // sets a nullable column to null
	set_edge     // a one_to_one edge's target
	clear_edge   // removes every target of an edge
	add_ids      // adds targets to a list edge
	remove_ids   // removes targets from a list edge
}

// key_v_type returns the V type of the keys of `info`.
fn key_v_type(info Info) string {
	return info.key_type() or { 'int' }
}

// input_fields returns the fields of the create (`create`) or update input of
// the table of `info`.
fn input_fields(info Info, infos map[string]Info, create bool) []InputField {
	t := info.table
	skip := if create { 'create_input' } else { 'update_input' }
	immutable_columns := t.edges.filter(it.immutable && it.kind == 'many_to_one').map(it.column)
	required_columns := t.edges.filter(it.required && it.kind == 'many_to_one').map(it.column)
	mut out := []InputField{}
	for f in info.all_gql_fields() {
		c := f.column
		if !c.scalar() || skip in c.graphql_skip_in {
			continue
		}
		if create && c.serial {
			continue
		}
		if !create && (f.key || c.immutable || c.name in immutable_columns) {
			continue
		}
		v_type := if c.json_type != '' { 'string' } else { c.v_type(info) }
		required := (create && !c.optional && !c.nullable) || c.name in required_columns
		out << InputField{
			name:     f.name
			v:        c.field
			gql_type: if required && create { f.scalar + '!' } else { f.scalar }
			v_type:   '?${v_type}'
			kind:     .column
			column:   c
			doc:      c.comment
		}
		if !create && c.nullable && c.type_name == '' {
			// the edge's name for the column of a many_to_one edge
			mut name := f.name
			for e in t.edges {
				if e.kind == 'many_to_one' && e.column == c.name && e.type_col == ''
					&& c.field == '${e.name}_id' {
					name = camel(e.name)
				}
			}
			out << InputField{
				name:     'clear${upper_first(name)}'
				v:        'clear_${c.field}'
				gql_type: 'Boolean'
				v_type:   'bool'
				kind:     .clear_column
				column:   c
			}
		}
	}
	for e in info.gql_edges(infos) {
		if !create && e.immutable {
			continue
		}
		target := infos[e.to] or { continue }
		kt := key_v_type(target)
		match e.kind {
			'one_to_one' {
				out << InputField{
					name:     '${camel(e.name)}ID'
					v:        '${e.name}_id'
					gql_type: 'ID'
					v_type:   '?${kt}'
					kind:     .set_edge
					edge:     e
					target:   target
				}
				if !create {
					out << InputField{
						name:     'clear${upper_first(camel(e.name))}'
						v:        'clear_${e.name}'
						gql_type: 'Boolean'
						v_type:   'bool'
						kind:     .clear_edge
						edge:     e
						target:   target
					}
				}
			}
			'one_to_many', 'many_to_many' {
				one := camel(singular(e.name))
				if create {
					out << InputField{
						name:     '${one}IDs'
						v:        '${singular(e.name)}_ids'
						gql_type: '[ID!]'
						v_type:   '[]${kt}'
						kind:     .add_ids
						edge:     e
						target:   target
					}
				} else {
					out << InputField{
						name:     'add${upper_first(one)}IDs'
						v:        'add_${singular(e.name)}_ids'
						gql_type: '[ID!]'
						v_type:   '[]${kt}'
						kind:     .add_ids
						edge:     e
						target:   target
					}
					out << InputField{
						name:     'remove${upper_first(one)}IDs'
						v:        'remove_${singular(e.name)}_ids'
						gql_type: '[ID!]'
						v_type:   '[]${kt}'
						kind:     .remove_ids
						edge:     e
						target:   target
					}
					out << InputField{
						name:     'clear${upper_first(camel(e.name))}'
						v:        'clear_${e.name}'
						gql_type: 'Boolean'
						v_type:   'bool'
						kind:     .clear_edge
						edge:     e
						target:   target
					}
				}
			}
			else {}
		}
	}
	return out
}

// check_inputs rejects two input fields of one name.
fn check_inputs(info Info, fields []InputField, typ string) ! {
	mut seen := map[string]bool{}
	mut seen_v := map[string]bool{}
	for f in fields {
		if f.name in seen || f.v in seen_v {
			return error('`${info.table.name}`: the ${typ} would have two fields named `${f.name}`; rename a field or an edge, or leave one out with `graphql_skip_in`')
		}
		seen[f.name] = true
		seen_v[f.v] = true
	}
}

// base_sdl returns the schema generated from the tables, with the tables'
// directives when `with_directives` is set.
fn base_sdl(infos map[string]Info, tables []Table, with_directives bool) string {
	mut b := strings.new_builder(16384)
	visible := tables.filter(!it.graphql_skip).map(infos[it.name])
	nodes := visible.filter(it.is_node())
	mut has_time := false
	mut has_json := false
	mut has_relay := false
	b.writeln('type Query {')
	if nodes.len > 0 {
		b.writeln('  """Fetches an object given its ID."""')
		b.writeln('  node(')
		b.writeln('    """ID of the object."""')
		b.writeln('    id: ID!')
		b.writeln('  ): Node')
		b.writeln('  """Lookup nodes by a list of IDs."""')
		b.writeln('  nodes(')
		b.writeln('    """The list of node IDs."""')
		b.writeln('    ids: [ID!]!')
		b.writeln('  ): [Node]!')
	}
	for info in visible {
		root := info.gql_root()
		if root == '' {
			continue
		}
		b.writeln('  ${root}(${list_args(info)}): ${list_type(info, true)}')
		if !info.relay() {
			b.writeln('  ${root}Count(where: ${info.gql_type()}WhereInput): Int!')
		}
	}
	b.writeln('}')
	with_mutations := visible.filter(it.gql_mutations().len > 0)
	if with_mutations.len > 0 {
		b.writeln('')
		b.writeln('type Mutation {')
		for info in with_mutations {
			t := info.gql_type()
			ms := info.gql_mutations()
			if 'create' in ms {
				b.writeln('  """Creates a ${t}."""')
				b.writeln('  create${t}(input: Create${t}Input!): ${t}!')
			}
			if 'update' in ms {
				b.writeln('  """Updates the ${t} with the id `id`."""')
				b.writeln('  update${t}(id: ID!, input: Update${t}Input!): ${t}!')
			}
			if 'delete' in ms {
				b.writeln('  """Deletes the ${t} with the id `id`, and returns the id."""')
				b.writeln('  delete${t}(id: ID!): ID!')
			}
		}
		b.writeln('}')
	}
	if nodes.len > 0 {
		b.writeln('')
		b.writeln('"""')
		b.writeln('An object with an ID.')
		b.writeln('Follows the [Relay Global Object Identification Specification](https://relay.dev/graphql/objectidentification.htm)')
		b.writeln('"""')
		b.writeln('interface Node {')
		b.writeln('  """The id of the object."""')
		b.writeln('  id: ID!')
		b.writeln('}')
	}
	for info in visible {
		t := info.gql_type()
		fields := info.gql_fields()
		all := info.all_gql_fields()
		has_time = has_time || all.any(it.scalar == 'Time')
		has_json = has_json || all.any(it.scalar == 'JSON')
		has_relay = has_relay || info.relay()
		b.writeln('')
		implements := if info.is_node() { ' implements Node' } else { '' }
		directives := if with_directives && info.table.graphql.directives.len > 0 {
			' ' + info.table.graphql.directives.join(' ')
		} else {
			''
		}
		b.writeln('type ${t}${implements}${directives} {')
		for f in fields {
			b.write_string(description(f.column.comment, '  '))
			b.writeln('  ${f.name}: ${f.typ()}${field_suffix(f.column.deprecated, f.column.directives, with_directives)}')
		}
		for e in info.gql_edges(infos) {
			target := infos[e.to] or { continue }
			suffix := field_suffix('', e.directives, with_directives)
			if is_list_edge(e) {
				b.writeln('  ${camel(e.name)}(${list_args(target)}): ${list_type(target, false)}${suffix}')
			} else {
				b.writeln('  ${camel(e.name)}: ${target.gql_type()}${suffix}')
			}
		}
		b.writeln('}')
		if info.relay() {
			b.writeln('')
			b.writeln('"""A connection to a list of items."""')
			b.writeln('type ${t}Connection {')
			b.writeln('  """A list of edges."""')
			b.writeln('  edges: [${t}Edge]')
			b.writeln('  """Information to aid in pagination."""')
			b.writeln('  pageInfo: PageInfo!')
			b.writeln('  """Identifies the total count of items in the connection."""')
			b.writeln('  totalCount: Int!')
			b.writeln('}')
			b.writeln('')
			b.writeln('"""An edge in a connection."""')
			b.writeln('type ${t}Edge {')
			b.writeln('  """The item at the end of the edge."""')
			b.writeln('  node: ${t}')
			b.writeln('  """A cursor for use in pagination."""')
			b.writeln('  cursor: Cursor!')
			b.writeln('}')
		}
		write_where_sdl(mut b, info, infos)
		b.writeln('')
		b.writeln('"""Ordering options for ${t} connections"""')
		b.writeln('input ${t}Order {')
		b.writeln('  """The ordering direction."""')
		b.writeln('  direction: OrderDirection! = ASC')
		b.writeln('  """The field by which to order ${t}s."""')
		b.writeln('  field: ${t}OrderField!')
		b.writeln('}')
		b.writeln('')
		b.writeln('"""Properties by which ${t} connections can be ordered."""')
		b.writeln('enum ${t}OrderField {')
		for o in info.order_fields(infos) {
			b.writeln('  ${o.name}')
		}
		b.writeln('}')
		mut enums := map[string]bool{}
		for f in all {
			if f.column.base() == 'enum' && f.scalar !in enums {
				enums[f.scalar] = true
				b.writeln('')
				b.writeln('"""${f.scalar} is enum for the field ${f.name}"""')
				b.writeln('enum ${f.scalar} {')
				for v in f.column.enum_values {
					b.writeln('  ${v.to_upper()}')
				}
				b.writeln('}')
			}
		}
		ms := info.gql_mutations()
		for create in [true, false] {
			if (create && 'create' !in ms) || (!create && 'update' !in ms) {
				continue
			}
			kind := if create { 'Create' } else { 'Update' }
			b.writeln('')
			b.writeln('"""')
			b.writeln('${kind}${t}Input is used for ${kind.to_lower()} ${t} object.')
			b.writeln('"""')
			b.writeln('input ${kind}${t}Input {')
			for f in input_fields(info, infos, create) {
				b.write_string(description(f.doc, '  '))
				// a required input field can't be deprecated
				deprecated := if f.gql_type.ends_with('!') { '' } else { f.column.deprecated }
				b.writeln('  ${f.name}: ${f.gql_type}${field_suffix(deprecated, []string{}, false)}')
			}
			b.writeln('}')
		}
	}
	b.writeln('')
	b.writeln('"""')
	b.writeln('Possible directions in which to order a list of items when provided an `orderBy` argument.')
	b.writeln('"""')
	b.writeln('enum OrderDirection {')
	b.writeln('  """Specifies an ascending order for a given `orderBy` argument."""')
	b.writeln('  ASC')
	b.writeln('  """Specifies a descending order for a given `orderBy` argument."""')
	b.writeln('  DESC')
	b.writeln('}')
	if has_relay {
		b.writeln('')
		b.writeln('"""')
		b.writeln('Information about pagination in a connection.')
		b.writeln('https://relay.dev/graphql/connections.htm#sec-undefined.PageInfo')
		b.writeln('"""')
		b.writeln('type PageInfo {')
		b.writeln('  """When paginating forwards, are there more items?"""')
		b.writeln('  hasNextPage: Boolean!')
		b.writeln('  """When paginating backwards, are there more items?"""')
		b.writeln('  hasPreviousPage: Boolean!')
		b.writeln('  """When paginating backwards, the cursor to continue."""')
		b.writeln('  startCursor: Cursor')
		b.writeln('  """When paginating forwards, the cursor to continue."""')
		b.writeln('  endCursor: Cursor')
		b.writeln('}')
		b.writeln('')
		b.writeln('"""')
		b.writeln('Define a Relay Cursor type:')
		b.writeln('https://relay.dev/graphql/connections.htm#sec-Cursor')
		b.writeln('"""')
		b.writeln('scalar Cursor')
	}
	if has_json {
		b.writeln('')
		b.writeln('"""A JSON value: an object, a list, a string, a number, a boolean or null."""')
		b.writeln('scalar JSON')
	}
	if has_time {
		b.writeln('')
		b.writeln('"""An RFC 3339 date and time, such as `2026-10-13T07:30:00Z`."""')
		b.writeln('scalar Time @specifiedBy(url: "https://scalars.graphql.org/chillicream/date-time.html")')
	}
	return b.str()
}

// write_where_sdl writes the WhereInput of the table of `info`.
fn write_where_sdl(mut b strings.Builder, info Info, infos map[string]Info) {
	t := info.gql_type()
	b.writeln('')
	b.writeln('"""')
	b.writeln('${t}WhereInput is used for filtering ${t} objects.')
	b.writeln('Input was generated by ent.')
	b.writeln('"""')
	b.writeln('input ${t}WhereInput {')
	b.writeln('  not: ${t}WhereInput')
	b.writeln('  and: [${t}WhereInput!]')
	b.writeln('  or: [${t}WhereInput!]')
	for f in info.where_fields() {
		for i, suffix in f.predicates() {
			if i == 0 {
				b.writeln('  """${f.name} field predicates"""')
			}
			b.writeln('  ${f.name}${suffix}: ${predicate_type(f, suffix)}')
		}
	}
	for e in info.gql_edges(infos) {
		target := infos[e.to] or { continue }
		name := upper_first(camel(e.name))
		b.writeln('  """${camel(e.name)} edge predicates"""')
		b.writeln('  has${name}: Boolean')
		b.writeln('  has${name}With: [${target.gql_type()}WhereInput!]')
	}
	b.writeln('}')
}

// check_gql_names rejects tables whose GraphQL names clash: two types of one
// name, two root fields, or a name the generated schema needs.
fn check_gql_names(infos map[string]Info, tables []Table) ! {
	visible := tables.filter(!it.graphql_skip).map(infos[it.name])
	has_node := visible.any(it.is_node())
	has_relay := visible.any(it.relay())
	mut types := map[string]string{}
	mut fields := map[string]string{}
	if has_node {
		types['Node'] = 'the Node interface'
		fields['node'] = 'Node'
		fields['nodes'] = 'Node'
	}
	if has_relay {
		types['PageInfo'] = 'Relay connections'
		types['Cursor'] = 'Relay connections'
	}
	for name in ['Query', 'Mutation', 'OrderDirection', 'Time', 'JSON'] {
		types[name] = 'the generated schema'
	}
	hint := "rename it with `type_name` or `query_field` in its `graphql()` options, or hide one with `@[graphql: '-']`"
	for info in visible {
		t := info.gql_type()
		mut names := [t, '${t}WhereInput', '${t}Order', '${t}OrderField']
		if info.relay() {
			names << ['${t}Connection', '${t}Edge']
		}
		ms := info.gql_mutations()
		if 'create' in ms {
			names << 'Create${t}Input'
		}
		if 'update' in ms {
			names << 'Update${t}Input'
		}
		for f in info.all_gql_fields() {
			if f.column.base() == 'enum' {
				names << f.scalar
			}
		}
		for name in names {
			if other := types[name] {
				if other != info.table.name {
					return error('table `${info.table.name}`: its GraphQL type `${name}` is taken by ${other}; ${hint}')
				}
			}
			types[name] = '`${info.table.name}`'
		}
		root := info.gql_root()
		if root != '' {
			mut roots := [root]
			if !info.relay() {
				roots << '${root}Count'
			}
			for r in roots {
				if other := fields[r] {
					return error('table `${info.table.name}`: its root field `${r}` is taken by ${other}; ${hint}')
				}
				fields[r] = '`${info.table.name}`'
			}
		}
	}
}

// GraphqlOutput is what the GraphQL half of `vgraph gen` writes.
pub struct GraphqlOutput {
pub:
	schema     string   // schema.graphql: the whole schema, printed
	server     string   // graphql.v: the server and its resolvers
	resolvers  string   // resolvers.v, new or with stubs appended; '' when unchanged
	stubs      []string // the stubs added
	operations int      // the operations checked against the schema
}

// HandWritten is a field the project's `.graphql` files add, which a method of
// `Resolvers` resolves.
struct HandWritten {
	typ    string
	field  string
	method string
	sdl    string // the field's definition, for the stub's comment
}

// generate_graphql builds the schema from the tables and `files`, checks it,
// checks the operations of the files in `operations` folders against it, and
// returns the files to write. `resolvers` is the current resolvers.v, or ''
// when there is none; `defined` is the text of the module's other hand-written
// files, to find the methods already written.
pub fn generate_graphql(out_module string, entities []Entity, tables []Table, all_files []GraphqlFile, resolvers string, defined string) !GraphqlOutput {
	infos := infos_of(entities, tables)!
	check_gql_names(infos, tables)!
	for t in tables {
		info := infos[t.name]
		if !t.graphql_skip {
			check_inputs(info, input_fields(info, infos, true), 'Create${info.gql_type()}Input')!
			check_inputs(info, input_fields(info, infos, false), 'Update${info.gql_type()}Input')!
		}
	}
	base_schema := graphql.build_schema(base_sdl(infos, tables, false)) or {
		return error('the generated GraphQL schema is invalid (a vgraph bug): ${err.msg()}\n${base_sdl(infos, tables, false)}')
	}
	files := all_files.filter(!it.is_operations())
	operations := all_files.filter(it.is_operations())
	mut merged := base_sdl(infos, tables, true)
	mut starts := []int{} // the line each file starts at in `merged`
	for f in files {
		merged += '\n\n'
		starts << merged.count('\n') + 1
		merged += f.text
	}
	doc := graphql.parse(merged) or { return error(locate(err, files, starts)) }
	// operations in a schema file would be dropped: they go in `operations/`
	mut misplaced := []string{}
	for def in doc.definitions {
		match def {
			graphql.OperationDefinition {
				name := if n := def.name { ' `${n.value}`' } else { '' }
				misplaced << locate(graphql.GraphQLError{
					message:   'the operation${name} is not schema: put operations in an `operations` folder, which vgraph gen checks against the schema'
					locations: [doc.location(def.pos)]
				}, files, starts)
			}
			graphql.FragmentDefinition {
				misplaced << locate(graphql.GraphQLError{
					message:   'the fragment `${def.name.value}` is not schema: put fragments in an `operations` folder, which vgraph gen checks against the schema'
					locations: [doc.location(def.pos)]
				}, files, starts)
			}
			else {}
		}
	}
	if misplaced.len > 0 {
		return error(misplaced.join('\n'))
	}
	errors := graphql.validate_sdl(doc, none)
	if errors.len > 0 {
		mut lines := errors.map(locate(it, files, starts))
		if errors.any(it.message.contains('"Mutation') || it.message.contains('named "Mutation"')) {
			lines << "the generated mutations clash with the project's: leave a table's out with `mutations: []` in its `graphql()` options, or rename the project's"
		}
		return error(lines.join('\n'))
	}
	schema := graphql.build_ast_schema(doc)!
	schema_errors := graphql.validate_schema(schema)
	if schema_errors.len > 0 {
		return error(schema_errors.map(locate(it, files, starts)).join('\n'))
	}
	// the operations, against the whole schema
	mut op_errors := []string{}
	mut op_count := 0
	for f in operations {
		op_doc := graphql.parse(f.text) or {
			op_errors << locate(err, [f], [1])
			continue
		}
		for def in op_doc.definitions {
			if def is graphql.OperationDefinition {
				op_count++
			} else if def !is graphql.FragmentDefinition {
				op_errors << locate(graphql.GraphQLError{
					message:   'an `operations` folder holds operations and fragments only; schema goes elsewhere'
					locations: [op_doc.location(def_pos(def))]
				}, [f], [1])
			}
		}
		for e in graphql.validate(&schema, &op_doc, graphql.ValidateOptions{}) {
			op_errors << locate(e, [f], [1])
		}
	}
	if op_errors.len > 0 {
		return error(op_errors.join('\n'))
	}
	// the fields the files add: on the root types, and on the generated types
	mut hand := []HandWritten{}
	for name in schema.type_names {
		t := schema.types[name] or { continue }
		if t.kind != .object || name.starts_with('__') {
			continue
		}
		is_root := name in [schema.query or { '' }, schema.mutation or { '' },
			schema.subscription or { '' }]
		generated := base_schema.get_type(name)
		if !is_root && generated == none {
			continue
		}
		for f in t.fields {
			if g := generated {
				if _ := g.field(f.name) {
					continue
				}
			}
			hand << HandWritten{
				typ:    name
				field:  f.name
				method: '${snake(name)}_${snake(f.name)}'
				sdl:    '${f.name}${print_args(f.args)}: ${graphql.print_type(f.typ)}'
			}
		}
	}
	// graphql-js prints no applied directives: the tables' and the files' are
	// printed as Apollo's subgraph schemas print them
	printed := graphql.print_schema_with(schema, applied_directives: true)
	return GraphqlOutput{
		schema:     '# ${header.all_after('// ')}\n\n' + printed + '\n'
		server:     server_file(out_module, infos, tables, printed, hand)!
		resolvers:  resolvers_file(out_module, resolvers, defined, hand)
		stubs:      hand.filter(!has_method(resolvers + defined, it.method)).map('${it.typ}.${it.field}')
		operations: op_count
	}
}

// def_pos returns where a definition starts.
fn def_pos(def graphql.Definition) int {
	return match def {
		graphql.DirectiveDefinition { def.pos }
		graphql.FragmentDefinition { def.pos }
		graphql.OperationDefinition { def.pos }
		graphql.SchemaDefinition { def.pos }
		graphql.TypeDefinition { 0 }
	}
}

fn print_args(args []graphql.InputValueDef) string {
	if args.len == 0 {
		return ''
	}
	return '(' + args.map('${it.name}: ${graphql.print_type(it.typ)}').join(', ') + ')'
}

fn infos_of(entities []Entity, tables []Table) !map[string]Info {
	mut infos := map[string]Info{}
	for table in tables {
		struct_name := table.struct_.all_after_last('.')
		mut entity := ?Entity(none)
		for e in entities {
			if e.struct_name == struct_name
				&& table.struct_.ends_with('${e.module_path.all_after_last('.')}.${struct_name}') {
				entity = e
			}
		}
		infos[table.name] = Info{
			table:  table
			entity: entity or { return error('no entity found for table `${table.name}`') }
		}
	}
	return infos
}

// locate prefixes an error with the file and line it is in: a project file's,
// when one of its locations is in one, else the generated schema's.
fn locate(err IError, files []GraphqlFile, starts []int) string {
	if err is graphql.GraphQLError {
		for loc in err.locations {
			for i := starts.len - 1; i >= 0; i-- {
				if loc.line >= starts[i] {
					return '${files[i].path}:${loc.line - starts[i] + 1}:${loc.column}: ${err.message}'
				}
			}
		}
		for loc in err.locations {
			return 'schema.graphql (generated):${loc.line}:${loc.column}: ${err.message}'
		}
		return err.message
	}
	return err.msg()
}

fn has_method(text string, method string) bool {
	return text.contains(') ${method}(')
}

// resolvers_file returns resolvers.v with a stub for each field in `hand`
// that has no method yet, or '' when nothing changes.
fn resolvers_file(out_module string, current string, defined string, hand []HandWritten) string {
	missing := hand.filter(!has_method(current + defined, it.method))
	if current != '' && missing.len == 0 {
		return ''
	}
	mut b := strings.new_builder(4096)
	if current == '' {
		b.writeln("// Resolvers resolves the fields that this project's .graphql files add to the")
		b.writeln('// schema. `vgraph gen` wrote this file, and adds a method here for each new')
		b.writeln('// field; it never changes what is already here. Give `Resolvers` whatever')
		b.writeln('// its methods need, such as the graph. A method reads and writes through')
		b.writeln("// `graph.with_ctx(ctx)`: in a mutation, that is the request's transaction.")
		b.writeln('module ${out_module}')
		if missing.len > 0 {
			b.writeln('')
			b.writeln('import five07.vgraph.graphql')
		}
		if !defined.contains('struct Resolvers') {
			b.writeln('')
			b.writeln('pub struct Resolvers {}')
		}
	} else {
		b.write_string(current.trim_right('\n'))
		b.writeln('')
		if missing.len > 0 && !current.contains('import five07.vgraph.graphql') {
			// the stubs need graphql: put the import after the module line
			text := b.str()
			b = strings.new_builder(4096)
			module_line := text.index('\nmodule ') or { -1 }
			if module_line >= 0 {
				end := text.index_after('\n', module_line + 1) or { text.len }
				b.write_string(text[..end + 1])
				b.writeln('\nimport five07.vgraph.graphql')
				b.write_string(text[end + 1..])
			} else {
				b.write_string(text)
			}
		}
	}
	for h in missing {
		b.writeln('')
		b.writeln('// ${h.method} resolves `${h.typ}.${h.field}`: `${h.sdl}`.')
		b.writeln('pub fn (r Resolvers) ${h.method}(_ graphql.Context, _ graphql.FieldInfo, _ []graphql.Source) ![]graphql.Resolved {')
		b.writeln("\treturn error('${h.typ}.${h.field} is not implemented')")
		b.writeln('}')
	}
	return b.str()
}

// v_string returns `s` as a V string literal.
fn v_string(s string) string {
	return "'" + s.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$') + "'"
}

// read_graphql_files returns the project's `.graphql` files, sorted, skipping
// hidden folders, the generated module, and projects of their own.
pub fn read_graphql_files(root string, skip []string) ![]GraphqlFile {
	mut found := []GraphqlFile{}
	mut dirs := [root]
	for dirs.len > 0 {
		dir := dirs.pop()
		for name in os.ls(dir)! {
			path := os.join_path(dir, name)
			if os.is_dir(path) {
				if !name.starts_with('.') && name !in skip
					&& !os.exists(os.join_path(path, 'v.mod')) {
					dirs << path
				}
				continue
			}
			if name.ends_with('.graphql') || name.ends_with('.graphqls') {
				found << GraphqlFile{
					path: path.all_after(root).trim_left(os.path_separator)
					text: os.read_file(path)!
				}
			}
		}
	}
	found.sort(a.path < b.path)
	return found
}
