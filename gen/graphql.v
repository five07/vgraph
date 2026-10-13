module gen

import graphql
import os
import strings

// The GraphQL half of `vgraph gen`: a schema with entgql's conventions for the
// tables, merged with the project's own `.graphql` files, and a server whose
// resolvers load through the generated client.

// GraphqlFile is a `.graphql` file of the project, merged into the schema.
pub struct GraphqlFile {
pub:
	path string // relative to the project, for messages
	text string
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

// upper_snake returns `CREATED_AT` for `created_at`.
fn upper_snake(name string) string {
	return name.to_upper()
}

// GqlField is a column as a GraphQL field.
struct GqlField {
	name     string // the GraphQL name
	column   Column
	scalar   string // ID, String, Int, Float, Boolean or Time
	nullable bool
	key      bool // the primary key
	foreign  bool // a column a many_to_one edge follows
}

fn (f GqlField) typ() string {
	return if f.nullable { f.scalar } else { f.scalar + '!' }
}

fn gql_scalar(c Column) ?string {
	return match c.typ.trim_left('?') {
		'int', 'i64' { 'Int' }
		'f64' { 'Float' }
		'bool' { 'Boolean' }
		'string' { 'String' }
		'time.Time' { 'Time' }
		else { none }
	}
}

fn (i Info) gql_type() string {
	return i.entity.struct_name
}

fn (i Info) gql_root() string {
	return camel(i.table.name)
}

fn (i Info) gql_fields() []GqlField {
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

fn is_list_edge(e Edge) bool {
	return e.kind in ['one_to_many', 'many_to_many']
}

fn (i Info) gql_edges(infos map[string]Info) []Edge {
	return i.table.edges.filter(!(infos[it.to] or { Info{} }).table.graphql_skip)
}

// predicates returns the WhereInput predicates of a field: the suffixes after
// its name, as entgql names them.
fn (f GqlField) predicates() []string {
	mut out := ['', 'NEQ']
	match f.scalar {
		'ID' {
			out << ['In', 'NotIn']
			if f.key {
				out << ['GT', 'GTE', 'LT', 'LTE']
			}
		}
		'String' {
			out << ['In', 'NotIn', 'GT', 'GTE', 'LT', 'LTE', 'Contains', 'HasPrefix', 'HasSuffix']
		}
		'Int' {
			out << ['In', 'NotIn', 'GT', 'GTE', 'LT', 'LTE']
		}
		'Float', 'Time' {
			out << ['GT', 'GTE', 'LT', 'LTE']
		}
		else {}
	}
	if f.nullable {
		out << ['IsNil', 'NotNil']
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

const list_args = 'where: WHERE, orderBy: ORDER, limit: Int, offset: Int'

fn list_args_of(target Info) string {
	return list_args.replace('WHERE', '${target.gql_type()}WhereInput').replace('ORDER',
		'${target.gql_type()}Order')
}

// base_sdl returns the schema generated from the tables.
fn base_sdl(infos map[string]Info, tables []Table) string {
	mut b := strings.new_builder(8192)
	visible := tables.filter(!it.graphql_skip).map(infos[it.name])
	mut has_time := false
	b.writeln('type Query {')
	for info in visible {
		b.writeln('  ${info.gql_root()}(${list_args_of(info)}): [${info.gql_type()}!]!')
		b.writeln('  ${info.gql_root()}Count(where: ${info.gql_type()}WhereInput): Int!')
	}
	b.writeln('}')
	for info in visible {
		fields := info.gql_fields()
		has_time = has_time || fields.any(it.scalar == 'Time')
		b.writeln('')
		b.writeln('type ${info.gql_type()} {')
		for f in fields {
			b.writeln('  ${f.name}: ${f.typ()}')
		}
		for e in info.gql_edges(infos) {
			target := infos[e.to] or { continue }
			if is_list_edge(e) {
				b.writeln('  ${camel(e.name)}(${list_args_of(target)}): [${target.gql_type()}!]')
			} else {
				b.writeln('  ${camel(e.name)}: ${target.gql_type()}')
			}
		}
		b.writeln('}')
		b.writeln('')
		b.writeln('"""')
		b.writeln('${info.gql_type()}WhereInput is used for filtering ${info.gql_type()} objects.')
		b.writeln('"""')
		b.writeln('input ${info.gql_type()}WhereInput {')
		for f in fields {
			for i, suffix in f.predicates() {
				if i == 0 {
					b.writeln('  """${f.name} field predicates"""')
				}
				b.writeln('  ${f.name}${suffix}: ${predicate_type(f, suffix)}')
			}
		}
		b.writeln('}')
		b.writeln('')
		b.writeln('"""Ordering options for ${info.gql_type()} lists"""')
		b.writeln('input ${info.gql_type()}Order {')
		b.writeln('  """The ordering direction."""')
		b.writeln('  direction: OrderDirection! = ASC')
		b.writeln('  """The field by which to order ${info.gql_type()}s."""')
		b.writeln('  field: ${info.gql_type()}OrderField!')
		b.writeln('}')
		b.writeln('')
		b.writeln('"""Properties by which ${info.gql_type()} lists can be ordered."""')
		b.writeln('enum ${info.gql_type()}OrderField {')
		for f in fields {
			b.writeln('  ${upper_snake(f.column.field)}')
		}
		b.writeln('}')
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
	if has_time {
		b.writeln('')
		b.writeln('"""An RFC 3339 date and time, such as `2026-10-13T07:30:00Z`."""')
		b.writeln('scalar Time @specifiedBy(url: "https://scalars.graphql.org/chillicream/date-time.html")')
	}
	return b.str()
}

// GraphqlOutput is what the GraphQL half of `vgraph gen` writes.
pub struct GraphqlOutput {
pub:
	schema    string   // schema.graphql: the whole schema, printed
	server    string   // graphql.v: the server and its resolvers
	resolvers string   // resolvers.v, new or with stubs appended; '' when unchanged
	stubs     []string // the stubs added
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
// and returns the files to write. `resolvers` is the current resolvers.v, or ''
// when there is none; `defined` is the text of the module's other hand-written
// files, to find the methods already written.
pub fn generate_graphql(out_module string, entities []Entity, tables []Table, files []GraphqlFile, resolvers string, defined string) !GraphqlOutput {
	infos := infos_of(entities, tables)!
	mut type_names := map[string]string{}
	for t in tables {
		if t.graphql_skip {
			continue
		}
		name := infos[t.name].gql_type()
		if other := type_names[name] {
			return error("tables `${other}` and `${t.name}` would both be the GraphQL type `${name}`; hide one with `@[graphql: '-']`")
		}
		type_names[name] = t.name
	}
	base := base_sdl(infos, tables)
	base_schema := graphql.build_schema(base) or {
		return error('the generated GraphQL schema is invalid (a vgraph bug): ${err.msg()}\n${base}')
	}
	mut merged := base
	mut starts := []int{} // the line each file starts at in `merged`
	for f in files {
		merged += '\n\n'
		starts << merged.count('\n') + 1
		merged += f.text
	}
	doc := graphql.parse(merged) or { return error(locate(err, files, starts)) }
	errors := graphql.validate_sdl(doc, none)
	if errors.len > 0 {
		return error(errors.map(locate(it, files, starts)).join('\n'))
	}
	schema := graphql.build_ast_schema(doc)!
	schema_errors := graphql.validate_schema(schema)
	if schema_errors.len > 0 {
		return error(schema_errors.map(locate(it, files, starts)).join('\n'))
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
	printed := graphql.print_schema(schema)
	return GraphqlOutput{
		schema:    '# ${header.all_after('// ')}\n\n' + printed + '\n'
		server:    server_file(out_module, infos, tables, printed, hand)
		resolvers: resolvers_file(out_module, resolvers, defined, hand)
		stubs:     hand.filter(!has_method(resolvers + defined, it.method)).map('${it.typ}.${it.field}')
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

// locate prefixes an error with the file and line it is in.
fn locate(err IError, files []GraphqlFile, starts []int) string {
	if err is graphql.GraphQLError {
		for loc in err.locations {
			for i := starts.len - 1; i >= 0; i-- {
				if loc.line >= starts[i] {
					return '${files[i].path}:${loc.line - starts[i] + 1}:${loc.column}: ${err.message}'
				}
			}
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
		b.writeln('// its methods need, such as the stores they call.')
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

fn server_file(out_module string, infos map[string]Info, tables []Table, sdl string, hand []HandWritten) string {
	visible := tables.filter(!it.graphql_skip).map(infos[it.name])
	mut b := strings.new_builder(32768)
	b.writeln(header)
	b.writeln('module ${out_module}\n')
	mut imports := ['five07.vgraph.graphql', 'five07.vgraph.load']
	mut has_time := false
	for info in visible {
		if info.gql_fields().any(it.scalar == 'Time') {
			has_time = true
		}
		line := import_line(info.entity.module_path)
		if line !in imports {
			imports << line
		}
	}
	if has_time {
		imports << 'time'
	}
	for line in imports {
		b.writeln('import ${line}')
	}
	b.writeln('
// schema_sdl is the GraphQL schema: the tables, with entgql\'s conventions, and
// the project\'s own .graphql files. schema.graphql holds the same.
pub const schema_sdl = ${v_string(sdl)}

// graphql returns a GraphQL server for the graph. Its resolvers load through the
// client, one query per edge per level of a request; `r` resolves the fields the
// project\'s .graphql files add.
pub fn (g Graph) graphql(r Resolvers) !&graphql.Server {
	mut s := graphql.Server.new(schema_sdl)!')
	if has_time {
		b.writeln("	s.scalar('Time', time_scalar)")
	}
	for info in visible {
		t := info.gql_type()
		root := info.gql_root()
		b.writeln('
	// ${t}
	s.resolve(\'Query\', \'${root}\', fn [g] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		found := g.with_ctx(ctx).${info.table.name}().graphql_args(info.args)!.all()!
		result := graphql.list(found.map(graphql.obj(it)))
		return parents.map(result)
	})
	s.resolve(\'Query\', \'${root}Count\', fn [g] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		n := g.with_ctx(ctx).${info.table.name}().graphql_args(info.args)!.count()!
		return parents.map(graphql.Resolved(graphql.Value(n)))
	})')
		fields := info.gql_fields()
		if fields.len > 0 {
			b.writeln('	for name in [${fields.map("'" + it.name + "'").join(', ')}] {')
			b.writeln("		s.resolve('${t}', name, resolve_${snake(t)}_field)")
			b.writeln('	}')
		}
		for e in info.gql_edges(infos) {
			target := infos[e.to] or { continue }
			rows := 'parents.map((it as ${info.node()}).${info.field()})'
			if is_list_edge(e) {
				b.writeln('	s.resolve(\'${t}\', \'${camel(e.name)}\', fn [g] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		cg := g.with_ctx(ctx)
		sub := cg.${target.table.name}().graphql_args(info.args)!
		loaded := cg.${info.table.name}().with_${e.name}(fn [sub] (_ ${target.query()}) ${target.query()} {
			return sub
		}).nodes(${rows})!
		mut out := []graphql.Resolved{cap: loaded.len}
		for n in loaded {
			out << graphql.list(page(n.${e.name}, info.args).map(graphql.obj(it)))
		}
		return out
	})')
			} else {
				b.writeln('	s.resolve(\'${t}\', \'${camel(e.name)}\', fn [g] (ctx graphql.Context, _ graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		loaded := g.with_ctx(ctx).${info.table.name}().with_${e.name}().nodes(${rows})!
		return loaded.map(fn (n ${info.node()}) graphql.Resolved {
			if target := n.${e.name} {
				return graphql.obj(*target)
			}
			return graphql.null
		})
	})')
			}
		}
	}
	if hand.len > 0 {
		b.writeln("\n	// the fields the project's .graphql files add")
	}
	for h in hand {
		b.writeln("	s.resolve('${h.typ}', '${h.field}', fn [r] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {")
		b.writeln('		return r.${h.method}(ctx, info, parents)')
		b.writeln('	})')
	}
	b.writeln('	return s\n}')
	// per table: field values, arguments
	for info in visible {
		write_gql_fields(mut b, info)
		write_gql_args(mut b, info)
	}
	code := b.str()
	return code + gql_helpers(code, has_time)
}

// field_value returns the V expression of a field's GraphQL value.
fn field_value(f GqlField, row string) string {
	expr := '${row}.${f.column.field}'
	base := f.column.typ.trim_left('?')
	conv := fn [f, base] (v string) string {
		return match true {
			f.scalar == 'ID' { 'graphql.Value(${v}.str())' }
			base == 'i64' { 'graphql.Value(f64(${v}))' }
			base == 'time.Time' { 'graphql.Value(${v}.format_rfc3339())' }
			else { 'graphql.Value(${v})' }
		}
	}
	if f.nullable {
		return 'if v := ${expr} { ${conv('v')} } else { graphql.null }'
	}
	return conv(expr)
}

fn write_gql_fields(mut b strings.Builder, info Info) {
	t := info.gql_type()
	fields := info.gql_fields()
	if fields.len == 0 {
		return
	}
	b.writeln('
// resolve_${snake(t)}_field resolves the columns of `${t}`.
fn resolve_${snake(t)}_field(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	return parents.map(graphql.Resolved(${snake(t)}_value((it as ${info.node()}).${info.field()}, info.field_name)))
}

fn ${snake(t)}_value(row ${info.typ()}, field string) graphql.Value {
	return match field {')
	for f in fields {
		b.writeln("		'${f.name}' { ${field_value(f, 'row')} }")
	}
	b.writeln('		else { graphql.null }
	}
}')
}

// cond_expr returns the load condition of a WhereInput predicate, with the
// argument in `v`.
fn cond_expr(f GqlField, suffix string) string {
	col := "'${f.column.name}'"
	base := f.column.typ.trim_left('?')
	one := match true {
		f.scalar == 'ID' && base == 'string' { 'v.as_string()' }
		f.scalar == 'ID' && base == 'i64' { 'gql_i64_id(v)!' }
		f.scalar == 'ID' { 'gql_int_id(v)!' }
		base == 'time.Time' { 'gql_time(v)!' }
		base == 'string' { 'v.as_string()' }
		base == 'f64' { 'v.as_float()' }
		base == 'bool' { 'v.as_bool()' }
		base == 'i64' { 'i64(v.as_float())' }
		else { 'v.as_int()' }
	}
	many := match true {
		base == 'string' { 'gql_strings(v)' }
		base == 'i64' { 'gql_i64s(v)!' }
		f.scalar == 'ID' { 'gql_int_ids(v)!' }
		else { 'gql_ints(v)' }
	}
	in_fn := match base {
		'string' { 'strings' }
		'i64' { 'i64s' }
		else { 'ints' }
	}
	return match suffix {
		'' { 'load.eq(${col}, ${one})' }
		'NEQ' { 'load.ne(${col}, ${one})' }
		'In' { 'load.in_${in_fn}(${col}, ${many})' }
		'NotIn' { 'load.not_in_${in_fn}(${col}, ${many})' }
		'GT' { 'load.gt(${col}, ${one})' }
		'GTE' { 'load.ge(${col}, ${one})' }
		'LT' { 'load.lt(${col}, ${one})' }
		'LTE' { 'load.le(${col}, ${one})' }
		'Contains' { 'load.contains(${col}, v.as_string())' }
		'HasPrefix' { 'load.has_prefix(${col}, v.as_string())' }
		'HasSuffix' { 'load.has_suffix(${col}, v.as_string())' }
		else { '' }
	}
}

fn write_gql_args(mut b strings.Builder, info Info) {
	t := info.gql_type()
	q := info.query()
	fields := info.gql_fields()
	b.writeln('
// graphql_args applies the arguments of a `${t}` list: `where`, `orderBy`,
// `limit` and `offset`.
fn (q ${q}) graphql_args(args map[string]graphql.Value) !${q} {
	mut next := q
	if w := args[\'where\'] {
		if w is map[string]graphql.Value {
			next = next.where(...${snake(t)}_where(w)!)
		}
	}
	if o := args[\'orderBy\'] {
		if o is map[string]graphql.Value {
			field := (o[\'field\'] or { graphql.null }).as_string()
			column := match field {')
	for f in fields {
		b.writeln("				'${upper_snake(f.column.field)}' { '${f.column.name}' }")
	}
	b.writeln("				else { '' }
			}
			next.query = load.Query{
				...next.query
				order: column
				desc:  (o['direction'] or { graphql.null }).as_string() == 'DESC'
			}
		}
	}
	if limit := args['limit'] {
		if limit is int {
			next = next.limit(limit)
		}
	}
	if offset := args['offset'] {
		if offset is int {
			next = next.offset(offset)
		}
	}
	return next
}")
	b.writeln('
// ${snake(t)}_where returns the conditions of a `${t}WhereInput`.
fn ${snake(t)}_where(w map[string]graphql.Value) ![]load.Cond {
	mut conds := []load.Cond{}
	for key, v in w {
		if v is graphql.Null {
			continue
		}
		match key {')
	for f in fields {
		for suffix in f.predicates() {
			name := f.name + suffix
			if suffix == 'IsNil' {
				b.writeln("			'${name}' { if v.as_bool() { conds << load.is_null('${f.column.name}') } }")
			} else if suffix == 'NotNil' {
				b.writeln("			'${name}' { if v.as_bool() { conds << load.is_not_null('${f.column.name}') } }")
			} else {
				b.writeln("			'${name}' { conds << ${cond_expr(f, suffix)} }")
			}
		}
	}
	b.writeln('			else {}
		}
	}
	return conds
}')
}

// gql_helpers returns the helper functions `code` calls, so the generated
// module has no unused ones.
fn gql_helpers(code string, has_time bool) string {
	mut used := if has_time { code + gql_time_helpers } else { code }
	mut added := map[string]bool{}
	// helpers call helpers: add until nothing new is called
	for {
		mut more := false
		for name, helper in gql_helper_fns {
			if name !in added && (used.contains('${name}(') || used.contains('${name}[')) {
				added[name] = true
				used += helper
				more = true
			}
		}
		if !more {
			break
		}
	}
	mut b := strings.new_builder(4096)
	for name, helper in gql_helper_fns {
		if name in added {
			b.writeln(helper)
		}
	}
	if has_time {
		b.writeln(gql_time_helpers)
	}
	return b.str()
}

const gql_helper_fns = {
	'page':        "
// page returns the part of a list that `limit` and `offset` ask for: an edge
// loads every row in one query, and each parent's list is cut here.
fn page[T](items []T, args map[string]graphql.Value) []T {
	offset := (args['offset'] or { graphql.null }).as_int()
	limit := (args['limit'] or { graphql.null }).as_int()
	start := if offset > 0 { offset } else { 0 }
	if start >= items.len {
		return []T{}
	}
	end := if limit > 0 && start + limit < items.len { start + limit } else { items.len }
	return items[start..end]
}"
	'gql_int_id':  '
// gql_int_id reads an int key from an ID.
fn gql_int_id(v graphql.Value) !int {
	s := v.as_string()
	n := s.int()
	if n.str() != s {
		return error(\'invalid ID "\${s}"\')
	}
	return n
}'
	'gql_int_ids': '
fn gql_int_ids(v graphql.Value) ![]int {
	mut out := []int{}
	for item in v.as_list() {
		out << gql_int_id(item)!
	}
	return out
}'
	'gql_i64_id':  '
// gql_i64_id reads an i64 key from an ID.
fn gql_i64_id(v graphql.Value) !i64 {
	s := v.as_string()
	n := s.i64()
	if n.str() != s {
		return error(\'invalid ID "\${s}"\')
	}
	return n
}'
	'gql_i64s':    '
fn gql_i64s(v graphql.Value) ![]i64 {
	mut out := []i64{}
	for item in v.as_list() {
		out << if item is string { gql_i64_id(item)! } else { i64(item.as_float()) }
	}
	return out
}'
	'gql_ints':    '
fn gql_ints(v graphql.Value) []int {
	return v.as_list().map(it.as_int())
}'
	'gql_strings': '
fn gql_strings(v graphql.Value) []string {
	return v.as_list().map(it.as_string())
}'
}

const gql_time_helpers = '
// gql_time reads a Time.
fn gql_time(v graphql.Value) !time.Time {
	return time.parse_rfc3339(v.as_string()) or {
		return error(\'invalid Time "\${v.as_string()}": use RFC 3339, such as 2026-10-13T07:30:00Z\')
	}
}

// time_scalar checks Time values: RFC 3339 strings.
const time_scalar = graphql.Scalar{
	parse_value:   fn (v graphql.Value) !graphql.Value {
		if v !is string {
			return error(\'Time must be an RFC 3339 string\')
		}
		gql_time(v)!
		return v
	}
	parse_literal: fn (node graphql.ValueNode, _ map[string]graphql.Value) !graphql.Value {
		if node is graphql.StringValue {
			gql_time(graphql.Value(node.value))!
			return graphql.Value(node.value)
		}
		return error(\'Time must be an RFC 3339 string\')
	}
}'

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
