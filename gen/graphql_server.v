module gen

import strings

// The generated GraphQL server: its resolvers, which read and write through
// the generated client, and the functions they use.

fn server_file(out_module string, infos map[string]Info, tables []Table, sdl string, hand []HandWritten) !string {
	visible := tables.filter(!it.graphql_skip).map(infos[it.name])
	nodes := visible.filter(it.is_node())
	mut b := strings.new_builder(65536)
	b.writeln(header)
	b.writeln('module ${out_module}\n')
	mut imports := ['five07.vgraph', 'five07.vgraph.graphql', 'five07.vgraph.load']
	has_time := visible.any(it.all_gql_fields().any(it.scalar == 'Time'))
	has_relay := visible.any(it.relay())
	if has_relay {
		imports << 'orm'
	}
	for info in visible {
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

// graphql returns a GraphQL server for the graph. Its resolvers read through
// the client, one query per edge per level of a request, and a request\'s
// mutations run in one transaction when the client can begin one; `r` resolves
// the fields the project\'s .graphql files add.
pub fn (g Graph) graphql(r Resolvers) !&graphql.Server {
	mut s := graphql.Server.new(schema_sdl)!
	if g.client.can_begin() {
		s.transaction = vgraph.GraphqlTransaction{
			client: g.client
		}
	}')
	if has_time {
		b.writeln("	s.scalar('Time', time_scalar)")
	}
	if has_relay {
		b.writeln("	s.scalar('Cursor', graphql.cursor_scalar)")
	}
	if nodes.len > 0 {
		names := nodes.map("'${it.table.name}'").join(', ')
		b.writeln('
	// Node: each type\'s ids are global ids, which `vgraph.global_ids` gives;
	// their ranges never move, so they are read once
	types := g.client.global_types() or {
		return error(\'the GraphQL schema has Node types, whose global ids are in `vgraph_types`: \${err.msg()}\')
	}
	for table in [${names}] {
		if table !in types.values() {
			return error(\'`\${table}` implements Node, but has no global ids: run `vgraph.global_ids` in a migration\')
		}
	}
	s.resolve(\'Query\', \'node\', fn [g, types] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		found := graphql_nodes(g.with_ctx(ctx), types, [info.arg(\'id\')])!
		return parents.map(found[0])
	})
	s.resolve(\'Query\', \'nodes\', fn [g, types] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		result := graphql.list(graphql_nodes(g.with_ctx(ctx), types, info.arg(\'ids\').as_list())!)
		return parents.map(result)
	})')
	}
	for info in visible {
		write_resolvers(mut b, info, infos)!
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
	if nodes.len > 0 {
		write_nodes_fn(mut b, nodes)!
	}
	for info in visible {
		write_gql_fields(mut b, info)
		write_gql_args(mut b, info, infos)!
		if info.relay() {
			write_relay(mut b, info, infos)!
		}
		for e in info.gql_edges(infos) {
			target := infos[e.to] or { continue }
			if is_list_edge(e) && target.relay() {
				write_edge_count(mut b, info, e, target)!
			}
		}
		ms := info.gql_mutations()
		if 'create' in ms {
			write_input_parser(mut b, info, infos, true)!
		}
		if 'update' in ms {
			write_input_parser(mut b, info, infos, false)!
		}
	}
	code := b.str()
	return code + gql_helpers(code, has_time)
}

// key_parser returns the function that reads a key of `info` from an ID, and
// the one that reads a list of them.
fn key_parser(info Info) !(string, string) {
	return match info.key_type()! {
		'int' { 'gql_int_id', 'gql_int_ids' }
		'i64' { 'gql_i64_id', 'gql_i64s' }
		else { 'gql_string_id', 'gql_strings' }
	}
}

// write_resolvers writes the registration of the resolvers of the table of
// `info`: its root field, fields, edges, connection and mutations.
fn write_resolvers(mut b strings.Builder, info Info, infos map[string]Info) ! {
	t := info.gql_type()
	p := info.prefix()
	root := info.gql_root()
	b.writeln('\n	// ${t}')
	if root != '' {
		if info.relay() {
			b.writeln('	s.resolve(\'Query\', \'${root}\', fn [g] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		page := ${p}_connection(g.with_ctx(ctx).${info.table.name}().graphql_where(info.args)!, info)!
		result := graphql.obj(page)
		return parents.map(result)
	})')
		} else {
			b.writeln('	s.resolve(\'Query\', \'${root}\', fn [g] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		found := g.with_ctx(ctx).${info.table.name}().graphql_args(info.args)!.all()!
		result := graphql.list(found.map(graphql.obj(it)))
		return parents.map(result)
	})
	s.resolve(\'Query\', \'${root}Count\', fn [g] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		n := g.with_ctx(ctx).${info.table.name}().graphql_where(info.args)!.count()!
		return parents.map(graphql.Resolved(graphql.Value(n)))
	})')
		}
	}
	if info.relay() {
		b.writeln("	s.connection('${t}Connection', '${t}Edge')")
	}
	fields := info.gql_fields()
	if fields.len > 0 {
		b.writeln('	for name in [${fields.map("'" + it.name + "'").join(', ')}] {')
		b.writeln("		s.resolve('${t}', name, resolve_${p}_field)")
		b.writeln('	}')
	}
	for e in info.gql_edges(infos) {
		target := infos[e.to] or { continue }
		rows := 'parents.map((it as ${info.node()}).${info.field()})'
		tp := target.prefix()
		if is_list_edge(e) && target.relay() {
			b.writeln('	s.resolve(\'${t}\', \'${camel(e.name)}\', fn [g] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		cg := g.with_ctx(ctx)
		p := graphql.page_args(info.args)!
		orders := ${tp}_order(info.arg(\'orderBy\'), true)!
		where := cg.${target.table.name}().graphql_where(info.args)!
		sub := where.graphql_paged(orders, p)!
		rows := ${rows}
		loaded := cg.${info.table.name}().with_${e.name}(fn [sub] (_ ${target.query()}) ${target.query()} {
			return sub
		}).nodes(rows)!
		counts := if info.selected(\'totalCount\') {
			${p}_count_${e.name}(cg, rows, where)!
		} else {
			map[string]int{}
		}
		mut out := []graphql.Resolved{cap: loaded.len}
		for n in loaded {
			page := ${tp}_page(cg, n.${e.name}, orders, p, counts[n.${info.field()}.${info.key_field()!}.str()] or {
				0
			})!
			out << graphql.obj(page)
		}
		return out
	})')
		} else if is_list_edge(e) {
			b.writeln('	s.resolve(\'${t}\', \'${camel(e.name)}\', fn [g] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		cg := g.with_ctx(ctx)
		sub := cg.${target.table.name}().graphql_args(info.args)!
		loaded := cg.${info.table.name}().with_${e.name}(fn [sub] (_ ${target.query()}) ${target.query()} {
			return sub
		}).nodes(${rows})!
		mut out := []graphql.Resolved{cap: loaded.len}
		for n in loaded {
			out << graphql.list(n.${e.name}.map(graphql.obj(it)))
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
	ms := info.gql_mutations()
	if ms.len == 0 {
		return
	}
	one, _ := key_parser(info)!
	if 'create' in ms {
		b.writeln('	s.resolve(\'Mutation\', \'create${t}\', fn [g] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		input := ${p}_create_input(info.arg(\'input\'))!
		node := g.with_ctx(ctx).${info.table.name}().create().set_input(input).save()!
		result := graphql.obj(node)
		return parents.map(result)
	})')
	}
	if 'update' in ms {
		b.writeln('	s.resolve(\'Mutation\', \'update${t}\', fn [g] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		id := ${one}(info.arg(\'id\'))!
		input := ${p}_update_input(info.arg(\'input\'))!
		node := g.with_ctx(ctx).${info.table.name}().update_one_id(id).set_input(input).save()!
		result := graphql.obj(node)
		return parents.map(result)
	})')
	}
	if 'delete' in ms {
		b.writeln('	s.resolve(\'Mutation\', \'delete${t}\', fn [g] (ctx graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
		id := ${one}(info.arg(\'id\'))!
		g.with_ctx(ctx).${info.table.name}().delete_one_id(id).exec()!
		result := graphql.Resolved(graphql.Value(id.str()))
		return parents.map(result)
	})')
	}
}

// write_nodes_fn writes `graphql_nodes`, which finds the rows of the `Node`
// tables by global id.
fn write_nodes_fn(mut b strings.Builder, nodes []Info) ! {
	b.writeln("
// graphql_nodes returns the rows with the global ids `ids`, in order, reading
// each table's in one query: an error at the place of an id no row has.
// `types` names the table of each range (`Client.global_types`).
fn graphql_nodes(g Graph, types map[int]string, ids []graphql.Value) ![]graphql.Resolved {
	mut keys := []i64{cap: ids.len}
	mut by_table := map[string][]i64{}
	for v in ids {
		key := gql_i64_id(v) or { -1 }
		keys << key
		if key >= 0 {
			by_table[types[int(key >> 32)] or { '' }] << key
		}
	}
	mut found := map[i64]graphql.Resolved{}")
	for info in nodes {
		key := info.key_field()!
		b.writeln("	if keys_of := by_table['${info.table.name}'] {
		for n in g.${info.table.name}().where_${key}_in(keys_of).all()! {
			found[n.${info.field()}.${key}] = graphql.obj_of('${info.gql_type()}', n)
		}
	}")
	}
	b.writeln('	mut out := []graphql.Resolved{cap: ids.len}
	for i, key in keys {
		out << found[key] or {
			graphql.Resolved(graphql.FieldError{
				message: \'Could not resolve to a node with the global ID of "\${ids[i].as_string()}".\'
			})
		}
	}
	return out
}')
}

// field_value returns the V expression of a field's GraphQL value.
fn field_value(f GqlField, row string) string {
	expr := '${row}.${f.column.field}'
	base := f.column.typ.trim_left('?')
	conv := fn [f, base] (v string) string {
		return match true {
			f.scalar == 'ID' { 'graphql.Value(${v}.str())' }
			f.scalar == 'JSON' { 'graphql.parse_json(${v}) or { graphql.null }' }
			base == 'enum' { 'graphql.Value(${v}.str().to_upper())' }
			base in ['i64', 'u32', 'u64', 'f32', 'f64'] { 'graphql.Value(f64(${v}))' }
			base in int_types { 'graphql.Value(int(${v}))' }
			base == 'time.Time' { 'graphql.Value(${v}.format_rfc3339())' }
			base == 'string' { 'graphql.Value(string(${v}))' }
			else { 'graphql.Value(${v})' }
		}
	}
	if f.nullable {
		return 'if v := ${expr} { ${conv('v')} } else { graphql.null }'
	}
	return conv(expr)
}

fn write_gql_fields(mut b strings.Builder, info Info) {
	p := info.prefix()
	t := info.gql_type()
	fields := info.gql_fields()
	if fields.len == 0 {
		return
	}
	b.writeln('
// resolve_${p}_field resolves the columns of `${t}`.
fn resolve_${p}_field(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	return parents.map(graphql.Resolved(${p}_value((it as ${info.node()}).${info.field()}, info.field_name)))
}

fn ${p}_value(row ${info.typ()}, field string) graphql.Value {
	return match field {')
	for f in fields {
		b.writeln("		'${f.name}' { ${field_value(f, 'row')} }")
	}
	b.writeln('		else { graphql.null }
	}
}')
}

// one_value returns the V expression of a WhereInput value `v` as the
// column's value.
fn one_value(f GqlField) string {
	base := f.column.typ.trim_left('?')
	return match true {
		f.scalar == 'ID' && base == 'string' { 'v.as_string()' }
		f.scalar == 'ID' && base == 'i64' { 'gql_i64_id(v)!' }
		f.scalar == 'ID' { 'gql_int_id(v)!' }
		base == 'time.Time' { 'gql_time(v)!' }
		base == 'string' { 'v.as_string()' }
		base in float_types { 'v.as_float()' }
		base == 'bool' { 'v.as_bool()' }
		base in ['i64', 'u64'] { 'i64(v.as_float())' }
		else { 'v.as_int()' }
	}
}

// cond_expr returns the load condition of a WhereInput predicate, with the
// argument in `v`.
fn cond_expr(f GqlField, suffix string) string {
	col := "'${f.column.name}'"
	base := f.column.typ.trim_left('?')
	if base == 'enum' {
		fn_name := '${snake(f.column.v_type_name())}_enum'
		return match suffix {
			'' { 'load.eq(${col}, ${fn_name}(v.as_string())!)' }
			'NEQ' { 'load.ne(${col}, ${fn_name}(v.as_string())!)' }
			'In' { 'load.in_ints(${col}, ${fn_name}s(v)!)' }
			'NotIn' { 'load.not_in_ints(${col}, ${fn_name}s(v)!)' }
			else { '' }
		}
	}
	one := one_value(f)
	if f.scalar in ['Float', 'Time'] && suffix in ['In', 'NotIn'] {
		// no IN of these: an OR of equals, or an AND of not equals
		list := if f.scalar == 'Time' { 'gql_times(v)!' } else { 'gql_floats(v)' }
		return if suffix == 'In' {
			'load.or(...${list}.map(load.eq(${col}, it)))'
		} else {
			'load.and(...${list}.map(load.ne(${col}, it)))'
		}
	}
	many := match true {
		base == 'string' { 'gql_strings(v)' }
		base in ['i64', 'u64'] { 'gql_i64s(v)!' }
		f.scalar == 'ID' { 'gql_int_ids(v)!' }
		else { 'gql_ints(v)' }
	}
	in_fn := match true {
		base == 'string' { 'strings' }
		base in ['i64', 'u64'] { 'i64s' }
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
		'EqualFold' { 'load.equal_fold(${col}, v.as_string())' }
		'ContainsFold' { 'load.contains_fold(${col}, v.as_string())' }
		else { '' }
	}
}

fn write_gql_args(mut b strings.Builder, info Info, infos map[string]Info) ! {
	t := info.gql_type()
	p := info.prefix()
	q := info.query()
	key := info.table.column(info.table.key)!
	b.writeln('
// graphql_where applies the `where` argument of a `${t}` list.
fn (q ${q}) graphql_where(args map[string]graphql.Value) !${q} {
	if w := args[\'where\'] {
		if w is map[string]graphql.Value {
			return q.where(...${p}_where(w)!)
		}
	}
	return q
}

// graphql_args applies the arguments of a `${t}` list: `where`, `orderBy`,
// `limit` and `offset`.
fn (q ${q}) graphql_args(args map[string]graphql.Value) !${q} {
	mut next := q.graphql_where(args)!
	if o := args[\'orderBy\'] {
		orders := ${p}_order(o, false)!
		if orders.len > 0 {
			next = next.order_by(...orders)
		}
	}
	if limit := args[\'limit\'] {
		if limit is int {
			next = next.limit(limit)
		}
	}
	if offset := args[\'offset\'] {
		if offset is int {
			next = next.offset(offset)
		}
	}
	return next
}

// ${p}_order returns the orders of an `orderBy` of `${t}`, and with `with_key`,
// the key last, unless it orders by it already.
fn ${p}_order(v graphql.Value, with_key bool) ![]load.Order {
	mut items := v.as_list()
	if items.len == 0 && v.as_map().len > 0 {
		items = [v]
	}
	mut orders := []load.Order{}
	mut keyed := false
	for item in items {
		o := item.as_map()
		desc := (o[\'direction\'] or { graphql.null }).as_string() == \'DESC\'
		field := (o[\'field\'] or { graphql.null }).as_string()
		match field {')
	for o in info.order_fields(infos) {
		if o.expr != '' {
			b.writeln("			'${o.name}' { orders << load.Order{ expr: ${v_string(o.expr)}, desc: desc, typ: '${o.typ}' } }")
		} else {
			b.writeln("			'${o.name}' {
				orders << load.Order{ column: '${o.column}', desc: desc, typ: '${o.typ}' }")
			if o.column == key.name {
				b.writeln('				keyed = true')
			}
			b.writeln('			}')
		}
	}
	b.writeln("			else { return error('`\${field}` is not a ${t}OrderField') }
		}
	}
	if with_key && !keyed {
		// the key breaks ties, in the direction of the last order, as entgql's
		orders << load.Order{
			column: '${key.name}'
			desc:   orders.len > 0 && orders.last().desc
			typ:    '${key.typ}'
		}
	}
	return orders
}")
	b.writeln('
// ${p}_where returns the conditions of a `${t}WhereInput`.
fn ${p}_where(w map[string]graphql.Value) ![]load.Cond {
	mut conds := []load.Cond{}
	for key, v in w {
		if v is graphql.Null {
			continue
		}
		match key {
			\'not\' {
				conds << load.not(load.and(...${p}_where(v.as_map())!))
			}
			\'and\' {
				for item in v.as_list() {
					conds << ${p}_where(item.as_map())!
				}
			}
			\'or\' {
				mut any := []load.Cond{}
				for item in v.as_list() {
					any << load.and(...${p}_where(item.as_map())!)
				}
				conds << load.or(...any)
			}')
	for f in info.where_fields() {
		for suffix in f.predicates() {
			name := f.name + suffix
			if suffix == 'IsNil' {
				b.writeln("			'${name}' { conds << if v.as_bool() { load.is_null('${f.column.name}') } else { load.is_not_null('${f.column.name}') } }")
			} else if suffix == 'NotNil' {
				b.writeln("			'${name}' { conds << if v.as_bool() { load.is_not_null('${f.column.name}') } else { load.is_null('${f.column.name}') } }")
			} else {
				b.writeln("			'${name}' { conds << ${cond_expr(f, suffix)} }")
			}
		}
	}
	for e in info.gql_edges(infos) {
		target := infos[e.to] or { continue }
		name := upper_first(camel(e.name))
		b.writeln("			'has${name}' { conds << if v.as_bool() { ${p}_has_${e.name}() } else { load.not(${p}_has_${e.name}()) } }")
		b.writeln("			'has${name}With' {
				mut all := []load.Cond{}
				for item in v.as_list() {
					all << ${target.prefix()}_where(item.as_map())!
				}
				conds << ${p}_has_${e.name}_with(...all)
			}")
	}
	b.writeln('			else {}
		}
	}
	return conds
}')
	// each enum's GraphQL values, back to the V enum's
	mut done := map[string]bool{}
	for f in info.all_gql_fields() {
		c := f.column
		if c.base() != 'enum' || c.v_type_name() in done {
			continue
		}
		done[c.v_type_name()] = true
		name := '${snake(c.v_type_name())}_enum'
		vt := c.v_type(info)
		b.writeln('
// ${name} returns the value of `${vt}` a GraphQL enum value names.
fn ${name}(name string) !int {
	return match name {')
		for v in c.enum_values {
			b.writeln("		'${v.to_upper()}' { int(${vt}.${v}) }")
		}
		b.writeln("		else { error('`\${name}` is not a ${c.type_name}') }
	}
}

// ${name}s returns the values of `${vt}` that a list of GraphQL enum values
// names.
fn ${name}s(v graphql.Value) ![]int {
	mut out := []int{}
	for item in v.as_list() {
		out << ${name}(item.as_string())!
	}
	return out
}")
	}
}

// order_value returns the V expression of a column of `row` as an
// `orm.Primitive`.
fn order_value(c Column, row string) string {
	expr := '${row}.${c.field}'
	base := c.base()
	conv := fn [c, base] (v string) string {
		return match true {
			base == 'enum' { 'orm.Primitive(int(${v}))' }
			c.type_name != '' { 'orm.Primitive(${base}(${v}))' }
			else { 'orm.Primitive(${v})' }
		}
	}
	if c.nullable {
		return 'if v := ${expr} { ${conv('v')} } else { orm.Primitive(orm.Null{}) }'
	}
	return conv(expr)
}

// write_relay writes the functions of a table with Relay connections: a page
// of a query, and its cursors.
fn write_relay(mut b strings.Builder, info Info, infos map[string]Info) ! {
	t := info.gql_type()
	p := info.prefix()
	q := info.query()
	n := info.node()
	key := info.table.column(info.table.key)!
	b.writeln('
// ${p}_connection returns the page of `q` that a `${t}Connection`\'s arguments
// ask for, and how many rows `q` matches when `totalCount` is asked for.
fn ${p}_connection(q ${q}, info graphql.FieldInfo) !graphql.Connection {
	p := graphql.page_args(info.args)!
	orders := ${p}_order(info.arg(\'orderBy\'), true)!
	rows := q.graphql_paged(orders, p)!.all()!
	total := if info.selected(\'totalCount\') { q.count()! } else { 0 }
	return ${p}_page(q.graph, rows, orders, p, total)
}

// graphql_paged returns `q` in `orders`, which end with the key (reversed for
// `last`), past the cursors of `p`, and limited to one row past the page.
fn (q ${q}) graphql_paged(orders []load.Order, p graphql.PageArgs) !${q} {
	types := orders.map(it.typ)
	nulls := load.nulls_largest(q.graph.client.conn)
	mut conds := q.query.conds.clone()
	if c := p.after {
		conds << load.keyset(orders, load.decode_cursor(c, types)!, true, nulls)!
	}
	if c := p.before {
		conds << load.keyset(orders, load.decode_cursor(c, types)!, false, nulls)!
	}
	backward := p.last != none
	mut next := q
	next.query = load.Query{
		...q.query
		conds:  conds
		order:  \'\'
		desc:   false
		orders: if backward { orders.map(load.Order{ ...it, desc: !it.desc }) } else { orders }
		limit:  if c := p.first {
			c + 1
		} else if c := p.last {
			c + 1
		} else {
			0
		}
		offset: 0
	}
	return next
}

// ${p}_page returns `nodes`, read in `orders` (reversed for `last`) and one row
// past the page, as a connection.
fn ${p}_page(g Graph, nodes []${n}, orders []load.Order, p graphql.PageArgs, total int) !graphql.Connection {
	mut page := nodes.clone()
	mut has_next := false
	mut has_previous := false
	if count := p.first {
		if page.len > count {
			has_next = true
			page = page[..count].clone()
		}
	} else if count := p.last {
		if page.len > count {
			has_previous = true
			page = page[..count].clone()
		}
		page.reverse_in_place()
	}
	cursors := ${p}_cursors(g, page.map(it.${info.field()}), orders)!
	return graphql.connection(page.map(graphql.Source(it)), cursors, has_next, has_previous, total)
}

// ${p}_cursors returns the cursors of `rows`: the values of their order
// columns, those of edges read in one query.
fn ${p}_cursors(g Graph, rows []${info.typ()}, orders []load.Order) ![]string {
	exprs := load.expr_values(g.client.conn, \'${info.table.name}\', \'${key.name}\', .${info.key_type()!},
		rows.map(it.${key.field}.str()), orders)!
	mut out := []string{cap: rows.len}
	for row in rows {
		from_exprs := exprs[row.${key.field}.str()] or { []orm.Primitive{} }
		mut values := []orm.Primitive{cap: orders.len}
		for i, o in orders {
			values << if o.expr != \'\' {
				from_exprs[i] or { orm.Primitive(orm.Null{}) }
			} else {
				${p}_order_value(row, o.column)
			}
		}
		out << load.encode_cursor(values)
	}
	return out
}

// ${p}_order_value returns a column of a `${info.table.name}` row, for a cursor.
fn ${p}_order_value(row ${info.typ()}, column string) orm.Primitive {
	return match column {')
	mut seen := map[string]bool{}
	for o in info.order_fields(infos) {
		if o.expr != '' || o.column in seen {
			continue
		}
		seen[o.column] = true
		c := info.table.column(o.column)!
		b.writeln("		'${c.name}' { ${order_value(c, 'row')} }")
	}
	if key.name !in seen {
		b.writeln("		'${key.name}' { ${order_value(key, 'row')} }")
	}
	b.writeln('		else { orm.Primitive(orm.Null{}) }
	}
}')
}

// write_edge_count writes the function that counts the targets of the list
// edge `e` of each row, for a connection\'s `totalCount`.
fn write_edge_count(mut b strings.Builder, info Info, e Edge, target Info) ! {
	p := info.prefix()
	key := info.key_field()!
	conds := sub_conds("g.client.prepare_query('${target.table.name}', sub.query)!.conds",
		edge_extras(e, true))
	b.writeln('
// ${p}_count_${e.name} counts the `${e.name}` of each of `rows` that `sub` keeps, by the
// row\'s key.
fn ${p}_count_${e.name}(g Graph, rows []${info.typ()}, sub ${target.query()}) !map[string]int {
	conds := ${conds}')
	if e.kind == 'many_to_many' {
		b.writeln("	return load.count_through(g.client.conn, '${e.through}', '${e.column}', '${e.through_to}',
		rows.map(it.${key}.str()), .${info.key_type()!}, .${target.key_type()!}, '${target.table.name}', '${target.table.key}', load.Query{
		conds: conds
	})
}")
	} else {
		b.writeln("	return load.count_each(g.client.conn, '${target.table.name}', '${e.column}', rows.map(it.${key}.str()),
		.${info.key_type()!}, load.Query{
		conds: conds
	})
}")
	}
}

// input_value returns the V expression of an input field's value `v`, a
// `graphql.Value`, as the V field's type, without its option.
fn input_value(f InputField, info Info) !string {
	match f.kind {
		.column {
			c := f.column
			if c.json_type != '' {
				return 'v.json()'
			}
			base := c.base()
			is_id := c.name == info.table.key
				|| info.table.edges.any(it.kind == 'many_to_one' && it.column == c.name)
			mut expr := match true {
				is_id && base == 'int' { 'gql_int_id(v)!' }
				is_id && base == 'i64' { 'gql_i64_id(v)!' }
				is_id { 'v.as_string()' }
				base == 'enum' {
					'unsafe { ${c.v_type(info)}(${snake(c.v_type_name())}_enum(v.as_string())!) }'
				}
				base == 'int' { 'v.as_int()' }
				base in ['i8', 'i16', 'u8', 'u16'] { '${base}(v.as_int())' }
				base in ['i64', 'u32', 'u64'] { '${base}(v.as_float())' }
				base == 'f64' { 'v.as_float()' }
				base == 'f32' { 'f32(v.as_float())' }
				base == 'bool' { 'v.as_bool()' }
				base == 'time.Time' { 'gql_time(v)!' }
				else { 'v.as_string()' }
			}
			if c.type_name != '' && base != 'enum' {
				expr = '${c.v_type(info)}(${expr})'
			}
			return expr
		}
		.clear_column, .clear_edge {
			return 'v.as_bool()'
		}
		.set_edge {
			one, _ := key_parser(f.target)!
			return if one == 'gql_string_id' { 'v.as_string()' } else { '${one}(v)!' }
		}
		.add_ids, .remove_ids {
			_, many := key_parser(f.target)!
			return if many == 'gql_strings' { 'gql_strings(v)' } else { '${many}(v)!' }
		}
	}
}

// write_input_parser writes the function that reads a `Create<T>Input` or
// `Update<T>Input` value into the client's input.
fn write_input_parser(mut b strings.Builder, info Info, infos map[string]Info, create bool) ! {
	p := info.prefix()
	kind := if create { 'create' } else { 'update' }
	vt := '${if create { 'Create' } else { 'Update' }}${info.entity.struct_name}Input'
	b.writeln('
// ${p}_${kind}_input reads the input of `${kind}${info.gql_type()}`.
fn ${p}_${kind}_input(value graphql.Value) !${vt} {
	mut input := ${vt}{}
	for name, v in value.as_map() {
		if v is graphql.Null {
			continue
		}
		match name {')
	for f in input_fields(info, infos, create) {
		expr := input_value(f, info)!
		mut check := ''
		if f.kind == .column {
			types := info.table.edges.filter(it.type_col == f.column.name).map(it.type_val)
			if types.len > 0 {
				list := types.map("'${it}'").join(', ')
				check = "\n				if v.as_string() !in [${list}] {
					return error('`${f.name}` is one of ${types.join(', ')}')
				}"
			}
		}
		b.writeln("			'${f.name}' {${check}
				input.${f.v} = ${expr}
			}")
	}
	b.writeln('			else {}
		}
	}
	return input
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
	'gql_int_id':    '
// gql_int_id reads an int key from an ID.
fn gql_int_id(v graphql.Value) !int {
	s := v.as_string()
	n := s.int()
	if n.str() != s {
		return error(\'invalid ID "\${s}"\')
	}
	return n
}'
	'gql_string_id': '
// gql_string_id reads a string key from an ID.
fn gql_string_id(v graphql.Value) !string {
	return v.as_string()
}'
	'gql_int_ids':   '
fn gql_int_ids(v graphql.Value) ![]int {
	mut out := []int{}
	for item in v.as_list() {
		out << gql_int_id(item)!
	}
	return out
}'
	'gql_i64_id':    '
// gql_i64_id reads an i64 key from an ID.
fn gql_i64_id(v graphql.Value) !i64 {
	s := v.as_string()
	n := s.i64()
	if n.str() != s {
		return error(\'invalid ID "\${s}"\')
	}
	return n
}'
	'gql_i64s':      '
fn gql_i64s(v graphql.Value) ![]i64 {
	mut out := []i64{}
	for item in v.as_list() {
		out << if item is string { gql_i64_id(item)! } else { i64(item.as_float()) }
	}
	return out
}'
	'gql_ints':      '
fn gql_ints(v graphql.Value) []int {
	return v.as_list().map(it.as_int())
}'
	'gql_floats':    '
fn gql_floats(v graphql.Value) []f64 {
	return v.as_list().map(it.as_float())
}'
	'gql_strings':   '
fn gql_strings(v graphql.Value) []string {
	return v.as_list().map(it.as_string())
}'
	'gql_times':     '
fn gql_times(v graphql.Value) ![]time.Time {
	mut out := []time.Time{}
	for item in v.as_list() {
		out << gql_time(item)!
	}
	return out
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
