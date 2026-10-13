module gen

import strings

// Info is what generating one table needs: the table, and its struct.
struct Info {
	table  Table
	entity Entity
}

fn (i Info) query() string {
	return '${i.entity.struct_name}Query'
}

fn (i Info) node() string {
	return '${i.entity.struct_name}Node'
}

// typ is the struct's type, as the generated code imports it.
fn (i Info) typ() string {
	return '${i.entity.alias()}.${i.entity.struct_name}'
}

// field is the node field that holds the row, such as `article`.
fn (i Info) field() string {
	return snake(i.entity.struct_name)
}

fn (i Info) key_field() !string {
	return i.table.column(i.table.key)!.field
}

// key_type is the `load.KeyType` of the table's key: `int`, `i64` or `string`.
fn (i Info) key_type() !string {
	return i.table.column(i.table.key)!.typ.trim_left('?')
}

// generate returns the files of the client module `out_module`, keyed by file
// name: `graph.v`, and one file per table.
pub fn generate(out_module string, entities []Entity, tables []Table) !map[string]string {
	mut infos := map[string]Info{}
	for table in tables {
		struct_name := table.struct_.all_after_last('.')
		mut entity := ?Entity(none)
		for e in entities {
			if e.struct_name == struct_name && table.struct_.ends_with('${e.module_path.all_after_last('.')}.${struct_name}') {
				entity = e
			}
		}
		infos[table.name] = Info{
			table:  table
			entity: entity or { return error('no entity found for table `${table.name}` (`${table.struct_}`)') }
		}
	}
	for table in tables {
		check_names(infos[table.name])!
	}
	mut files := map[string]string{}
	files['graph.v'] = graph_file(out_module, entities)
	for table in tables {
		files['${table.name}.v'] = table_file(out_module, infos[table.name], infos)!
	}
	return files
}

// check_names rejects a table or edge whose name the generated code needs for
// something else.
fn check_names(info Info) ! {
	t := info.table
	if t.name in ['client', 'new'] {
		return error('table `${t.name}`: `Graph.${t.name}` is taken; rename the table')
	}
	for edge in t.edges {
		if edge.name in ['graph', info.field()] {
			return error('`${t.name}.${edge.name}`: `${info.node()}.${edge.name}` is taken; rename the edge')
		}
	}
}

fn graph_file(out_module string, entities []Entity) string {
	mut b := strings.new_builder(2048)
	b.writeln(header)
	b.writeln('module ${out_module}\n')
	b.writeln('import orm')
	b.writeln('import five07.vgraph')
	for path in imports_of(entities) {
		b.writeln('import ${import_line(path)}')
	}
	b.writeln('
// Graph is the typed client for the schema: start a query with the method named
// after a table, such as `articles()`.
pub struct Graph {
pub:
	client vgraph.Client
}

// Graph.new registers every struct of the schema, checks its edges, and returns a
// client that runs on `conn`.
pub fn Graph.new(conn orm.Connection) !Graph {
	return Graph{
		client: vgraph.Client.new(conn, schema()!)!
	}
}

// schema returns the schema with every struct registered, for migrations
// (`vgraph.add_edge_indexes`) and anything else that needs it without a
// connection. `Graph.new` checks it.
pub fn schema() !vgraph.Schema {
	mut s := vgraph.Schema{}')
	for e in entities {
		b.writeln('\ts.add[${e.alias()}.${e.struct_name}]()!')
	}
	b.writeln('	return s
}

// NotFoundError is the error of `first()` when no row matches.
pub struct NotFoundError {
	Error
pub:
	table string
}

// msg names the table that had no matching row.
pub fn (e NotFoundError) msg() string {
	return "no `\${e.table}` row matches"
}')
	return b.str()
}

fn table_file(out_module string, info Info, infos map[string]Info) !string {
	t := info.table
	q := info.query()
	n := info.node()
	mut targets := []Info{}
	for edge in t.edges {
		targets << infos[edge.to] or {
			return error('`${t.name}.${edge.name}` leads to `${edge.to}`, which has no struct')
		}
	}
	mut b := strings.new_builder(8192)
	b.writeln(header)
	b.writeln('module ${out_module}\n')
	mut imports := ['five07.vgraph.load']
	if t.columns.any(it.typ.trim_left('?') == 'time.Time') {
		imports << 'time'
	}
	mut paths := [info.entity.module_path]
	paths << targets.map(it.entity.module_path)
	for path in paths {
		line := import_line(path)
		if line !in imports {
			imports << line
		}
	}
	for line in imports {
		b.writeln('import ${line}')
	}

	// the query
	b.writeln('
// ${q} selects `${t.name}` rows, and the edges to load with them. Start one with
// `Graph.${t.name}()`.
pub struct ${q} {
	graph Graph
mut:
	query load.Query')
	for i, edge in t.edges {
		b.writeln('	with_${edge.name} bool
	${edge.name}_fns []fn (${targets[i].query()}) ${targets[i].query()}')
	}
	b.writeln('}')

	// the node
	b.writeln('
// ${n} is a `${t.name}` row, with the edges its query loaded.
pub struct ${n} {
	graph Graph
pub mut:
	${info.field()} ${info.typ()}')
	for i, edge in t.edges {
		typ := if edge.kind in ['many_to_one', 'one_to_one'] {
			'?&${targets[i].node()}'
		} else {
			'[]${targets[i].node()}'
		}
		b.writeln('	${edge.name} ${typ} // set by `with_${edge.name}()`')
	}
	b.writeln('}')

	b.writeln('
// ${t.name} starts a query of `${t.name}`.
pub fn (g Graph) ${t.name}() ${q} {
	return ${q}{
		graph: g
	}
}

// where keeps the rows that match every one of `conds`, built with
// `five07.vgraph.load`, such as `load.like(\'title\', \'V%\')`.
pub fn (q ${q}) where(conds ...load.Cond) ${q} {
	mut next := q
	mut all := q.query.conds.clone()
	all << conds
	next.query = load.Query{
		...q.query
		conds: all
	}
	return next
}

// limit keeps at most `count` rows. It applies to `all()` and `first()`, not to
// the rows of an edge load.
pub fn (q ${q}) limit(count int) ${q} {
	mut next := q
	next.query = load.Query{
		...q.query
		limit: count
	}
	return next
}

// offset skips the first `count` rows. It applies to `all()` and `first()`, not
// to the rows of an edge load.
pub fn (q ${q}) offset(count int) ${q} {
	mut next := q
	next.query = load.Query{
		...q.query
		offset: count
	}
	return next
}

// count returns how many rows match, in one query; order, limit and offset
// do not apply.
pub fn (q ${q}) count() !int {
	return load.count_where[${info.typ()}](q.graph.client.conn, q.query)
}')
	write_predicates(mut b, t, q)
	for i, edge in t.edges {
		target := targets[i]
		b.writeln('
// with_${edge.name} loads each row\'s `${edge.name}` (${edge.kind} `${edge.to}`) with it, in one
// query for all the rows. `configure` narrows them, and can load their edges.
pub fn (q ${q}) with_${edge.name}(configure ...fn (${target.query()}) ${target.query()}) ${q} {
	mut next := q
	next.with_${edge.name} = true
	next.${edge.name}_fns = configure
	return next
}')
	}
	b.writeln('
// all returns the matching rows, with the requested edges.
pub fn (q ${q}) all() ![]${n} {
	rows := load.select_where[${info.typ()}](q.graph.client.conn, q.query)!
	return q.nodes(rows)
}

// first returns the first matching row, with the requested edges, or a
// `NotFoundError`.
pub fn (q ${q}) first() !${n} {
	nodes := q.limit(1).all()!
	if nodes.len == 0 {
		return NotFoundError{
			table: \'${t.name}\'
		}
	}
	return nodes[0]
}

// nodes loads the requested edges onto `rows`, which the caller already has: one
// query per edge, however many rows there are.
pub fn (q ${q}) nodes(rows []${info.typ()}) ![]${n} {
	mut nodes := rows.map(${n}{
		graph: q.graph
		${info.field()}: it
	})')
	for i, edge in t.edges {
		write_edge_load(mut b, info, edge, targets[i])!
	}
	b.writeln('	return nodes\n}')
	for i, edge in t.edges {
		write_traversal(mut b, info, edge, targets[i])!
	}
	return b.str()
}

fn write_predicates(mut b strings.Builder, t Table, q string) {
	for c in t.columns {
		base := c.typ.trim_left('?')
		if base !in ['int', 'i64', 'f64', 'bool', 'string', 'time.Time'] {
			continue
		}
		b.writeln('
// where_${c.field} keeps the rows whose `${c.name}` is `value`.
pub fn (q ${q}) where_${c.field}(value ${base}) ${q} {
	return q.where(load.eq(\'${c.name}\', value))
}')
		if base in ['int', 'i64', 'f64', 'time.Time'] {
			for op, words in {
				'lt': 'before'
				'le': 'at or before'
				'gt': 'after'
				'ge': 'at or after'
			} {
				b.writeln('
// where_${c.field}_${op} keeps the rows whose `${c.name}` comes ${words} `value`.
pub fn (q ${q}) where_${c.field}_${op}(value ${base}) ${q} {
	return q.where(load.${op}(\'${c.name}\', value))
}')
			}
		}
		if base in ['int', 'i64', 'string'] {
			fn_name := match base {
				'int' { 'in_ints' }
				'i64' { 'in_i64s' }
				else { 'in_strings' }
			}
			b.writeln('
// where_${c.field}_in keeps the rows whose `${c.name}` is one of `values`.
pub fn (q ${q}) where_${c.field}_in(values []${base}) ${q} {
	return q.where(load.${fn_name}(\'${c.name}\', values))
}')
		}
		if base == 'string' {
			b.writeln('
// where_${c.field}_like keeps the rows whose `${c.name}` matches the SQL LIKE `pattern`.
pub fn (q ${q}) where_${c.field}_like(pattern string) ${q} {
	return q.where(load.like(\'${c.name}\', pattern))
}')
		}
		if c.nullable {
			b.writeln('
// where_${c.field}_is_null keeps the rows whose `${c.name}` is null.
pub fn (q ${q}) where_${c.field}_is_null() ${q} {
	return q.where(load.is_null(\'${c.name}\'))
}

// where_${c.field}_is_not_null keeps the rows whose `${c.name}` is not null.
pub fn (q ${q}) where_${c.field}_is_not_null() ${q} {
	return q.where(load.is_not_null(\'${c.name}\'))
}')
		}
		b.writeln('
// order_by_${c.field} orders the rows by `${c.name}`, ascending.
pub fn (q ${q}) order_by_${c.field}() ${q} {
	mut next := q
	next.query = load.Query{
		...q.query
		order: \'${c.name}\'
		desc:  false
	}
	return next
}

// order_by_${c.field}_desc orders the rows by `${c.name}`, descending.
pub fn (q ${q}) order_by_${c.field}_desc() ${q} {
	mut next := q
	next.query = load.Query{
		...q.query
		order: \'${c.name}\'
		desc:  true
	}
	return next
}')
	}
}

// filters returns the named options that narrow an edge's rows.
fn filters(edge Edge, with_type bool) string {
	mut parts := []string{}
	if with_type && edge.type_col != '' {
		parts << "type_col: '${edge.type_col}'"
		parts << "type_val: '${edge.type_val}'"
	}
	if edge.soft_del != '' {
		parts << "soft_del: '${edge.soft_del}'"
	}
	parts << 'query: sub.query'
	return parts.join(', ')
}

// type_check returns the condition that a row of `info` is on the polymorphic
// edge `edge`, or '' when the edge isn't polymorphic.
fn type_check(row string, info Info, edge Edge) !string {
	if edge.type_col == '' {
		return ''
	}
	field := info.table.column(edge.type_col)!.field
	return "${row}.${field} == '${edge.type_val}'"
}

fn write_edge_load(mut b strings.Builder, info Info, edge Edge, target Info) ! {
	t := info.table
	key := info.key_field()!
	b.writeln('	if q.with_${edge.name} {
		mut sub := q.graph.${target.table.name}()
		for configure in q.${edge.name}_fns {
			sub = configure(sub)
		}')
	match edge.kind {
		'one_to_many', 'one_to_one' {
			fk := target.table.column(edge.column)!
			b.writeln("		children := sub.nodes(load.select_in[${target.typ()}](q.graph.client.conn, '${edge.column}',
			rows.map(it.${key}.str()), ${filters(edge, true)})!)!
		mut by_parent := map[string][]${target.node()}{}
		for child in children {")
			if fk.nullable {
				b.writeln('			if parent := child.${target.field()}.${fk.field} {
				by_parent[parent.str()] << child
			}')
			} else {
				b.writeln('			by_parent[child.${target.field()}.${fk.field}.str()] << child')
			}
			if edge.kind == 'one_to_one' {
				b.writeln('		}
		// at most one each: the first, in the order of the query
		for mut node in nodes {
			if found := by_parent[node.${info.field()}.${key}.str()] {
				node.${edge.name} = &${target.node()}{
					...found[0]
				}
			}
		}')
			} else {
				b.writeln('		}
		for mut node in nodes {
			node.${edge.name} = by_parent[node.${info.field()}.${key}.str()] or { [] }
		}')
			}
		}
		'many_to_one' {
			fk := t.column(edge.column)!
			target_key := target.key_field()!
			check := type_check('row', info, edge)!
			b.writeln('		mut keys := []string{}
		for row in rows {')
			if check != '' {
				b.writeln('			if !(${check}) {
				continue
			}')
			}
			if fk.nullable {
				b.writeln('			if key := row.${fk.field} {
				keys << key.str()
			}')
			} else {
				b.writeln('			keys << row.${fk.field}.str()')
			}
			b.writeln("		}
		targets := sub.nodes(load.select_in[${target.typ()}](q.graph.client.conn, '${target.table.key}',
			load.unique(keys), ${filters(edge, false)})!)!
		mut by_key := map[string]&${target.node()}{}
		for target in targets {
			by_key[target.${target.field()}.${target_key}.str()] = &${target.node()}{
				...target
			}
		}
		for mut node in nodes {")
			node_check := type_check('node.${info.field()}', info, edge)!
			if node_check != '' {
				b.writeln('			if !(${node_check}) {
				continue
			}')
			}
			if fk.nullable {
				b.writeln('			if key := node.${info.field()}.${fk.field} {
				if target := by_key[key.str()] {
					node.${edge.name} = target
				}
			}')
			} else {
				b.writeln('			if target := by_key[node.${info.field()}.${fk.field}.str()] {
				node.${edge.name} = target
			}')
			}
			b.writeln('		}')
		}
		'many_to_many' {
			target_key := target.key_field()!
			b.writeln("		pairs := load.link_pairs(q.graph.client.conn, '${edge.through}', '${edge.column}',
			'${edge.through_to}', rows.map(it.${key}.str()), .${info.key_type()!}, .${target.key_type()!})!
		targets := sub.nodes(load.select_in[${target.typ()}](q.graph.client.conn, '${target.table.key}',
			load.unique(pairs.map(it[1])), ${filters(edge, true)})!)!
		// each parent's targets in the order of the query
		mut parents_of := map[string][]string{}
		for pair in pairs {
			parents_of[pair[1]] << pair[0]
		}
		mut linked := map[string][]${target.node()}{}
		for target in targets {
			for parent in parents_of[target.${target.field()}.${target_key}.str()] or { [] } {
				linked[parent] << target
			}
		}
		for mut node in nodes {
			node.${edge.name} = linked[node.${info.field()}.${key}.str()] or { [] }
		}")
		}
		else {
			return error('`${t.name}.${edge.name}`: unknown edge kind `${edge.kind}`')
		}
	}
	b.writeln('	}')
}

fn write_traversal(mut b strings.Builder, info Info, edge Edge, target Info) ! {
	n := info.node()
	row := 'n.${info.field()}'
	tq := target.query()
	mut extra := []string{}
	if edge.soft_del != '' {
		extra << "load.is_null('${edge.soft_del}')"
	}
	match edge.kind {
		'one_to_many', 'one_to_one' {
			mut conds := ["load.eq('${edge.column}', ${row}.${info.key_field()!})"]
			if edge.type_col != '' {
				conds << "load.eq('${edge.type_col}', '${edge.type_val}')"
			}
			conds << extra
			b.writeln('
// query_${edge.name} starts a query of this row\'s `${edge.name}`.
pub fn (n ${n}) query_${edge.name}() ${tq} {
	return n.graph.${target.table.name}().where(${conds.join(", ")})
}')
		}
		'many_to_one' {
			fk := info.table.column(edge.column)!
			none_query := "n.graph.${target.table.name}().where(load.in_ints('${target.table.key}', []))"
			b.writeln('
// query_${edge.name} starts a query of this row\'s `${edge.name}`, which matches
// nothing when the row has none.
pub fn (n ${n}) query_${edge.name}() ${tq} {')
			check := type_check(row, info, edge)!
			if check != '' {
				b.writeln('	if !(${check}) {
		return ${none_query}
	}')
			}
			if fk.nullable {
				b.writeln('	key := ${row}.${fk.field} or { return ${none_query} }')
			} else {
				b.writeln('	key := ${row}.${fk.field}')
			}
			mut conds := ["load.eq('${target.table.key}', key)"]
			conds << extra
			b.writeln('	return n.graph.${target.table.name}().where(${conds.join(", ")})
}')
		}
		'many_to_many' {
			mut conds := ["load.in_keys('${target.table.key}', pairs.map(it[1]), .${target.key_type()!})"]
			if edge.type_col != '' {
				conds << "load.eq('${edge.type_col}', '${edge.type_val}')"
			}
			conds << extra
			b.writeln("
// query_${edge.name} starts a query of this row's `${edge.name}`. It reads the join
// table `${edge.through}` first, so it can fail.
pub fn (n ${n}) query_${edge.name}() !${tq} {
	pairs := load.link_pairs(n.graph.client.conn, '${edge.through}', '${edge.column}',
		'${edge.through_to}', [${row}.${info.key_field()!}.str()], .${info.key_type()!}, .${target.key_type()!})!
	return n.graph.${target.table.name}().where(${conds.join(", ")})
}")
		}
		else {}
	}
}

// snake returns `article_tag` for `ArticleTag`.
fn snake(name string) string {
	mut b := strings.new_builder(name.len + 4)
	for i, c in name {
		if c.is_capital() {
			if i > 0 {
				b.write_u8(`_`)
			}
			b.write_u8(c + 32)
		} else {
			b.write_u8(c)
		}
	}
	return b.str()
}
