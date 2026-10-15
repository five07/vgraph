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
	// predicate functions are named `<struct>_<field>_<op>`, which two tables
	// can both produce
	mut funcs := map[string]string{}
	for table in tables {
		for p in predicates(infos[table.name], infos)! {
			if other := funcs[p.func] {
				return error('`${p.func}` would be generated for both `${other}` and `${table.name}`; rename a struct, a field or an edge')
			}
			funcs[p.func] = table.name
		}
	}
	mut files := map[string]string{}
	files['graph.v'] = graph_file(out_module, entities)
	for table in tables {
		files['${table.name}.v'] = table_file(out_module, infos[table.name], infos)!
		if !table.view {
			files['${table.name}_mutation.v'] = mutation_file(out_module, infos[table.name],
				infos)!
		}
	}
	return files
}

// check_names rejects a table or edge whose name the generated code needs for
// something else.
fn check_names(info Info) ! {
	t := info.table
	if t.name in ['client', 'new', 'with_ctx', 'ctx', 'tx', 'graphql', 'use', 'intercept', 'policy',
		'skip', 'privileged', 'on_commit', 'on_rollback'] {
		return error('table `${t.name}`: `Graph.${t.name}` is taken; rename the table')
	}
	for edge in t.edges {
		if edge.name in ['graph', 'update', 'loaded', info.field()] {
			return error('`${t.name}.${edge.name}`: `${info.node()}.${edge.name}` is taken; rename the edge')
		}
	}
}

fn graph_file(out_module string, entities []Entity) string {
	mut b := strings.new_builder(2048)
	b.writeln(header)
	b.writeln('module ${out_module}\n')
	b.writeln('import context')
	b.writeln('import orm')
	b.writeln('import five07.vgraph')
	b.writeln('import five07.vgraph.load')
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

// with_ctx returns a graph whose queries and writes carry `ctx` to hooks and
// privacy rules, with the app\'s own values in it, such as its user
// (`context.with_value`). The GraphQL server passes each request\'s context on.
pub fn (g Graph) with_ctx(ctx context.Context) Graph {
	return Graph{
		client: g.client.with_ctx(ctx)
	}
}

// ctx returns the context `with_ctx` gave, or `context.background()`.
pub fn (g Graph) ctx() context.Context {
	return g.client.ctx
}

// tx runs `f` in a transaction: it commits when `f` succeeds, and rolls back
// when it fails. The graph `f` gets runs every query and write in the
// transaction; inside one already, `f` joins it.
pub fn (g Graph) tx(f fn (tx Graph) !) ! {
	client := g.client.begin()!
	f(Graph{ client: client }) or {
		client.rollback() or {}
		return err
	}
	client.commit()!
}

// use registers hooks for the writes of every table, before each table\'s own.
// Register them at startup, before the graph serves requests.
pub fn (g Graph) use(hooks ...vgraph.Hook) {
	g.client.use(...hooks)
}

// intercept registers interceptors for the queries of every table, before
// each table\'s own.
pub fn (g Graph) intercept(interceptors ...vgraph.Interceptor) {
	g.client.intercept(...interceptors)
}

// policy registers privacy rules for every table, before each table\'s own.
pub fn (g Graph) policy(policies ...vgraph.Policy) {
	g.client.policy(...policies)
}

// skip returns a graph that leaves out the hooks and interceptors named
// `names`, such as `soft_delete`.
pub fn (g Graph) skip(names ...string) Graph {
	return Graph{
		client: g.client.skip(...names)
	}
}

// privileged returns a graph that skips privacy rules, for seeds, migrations
// and system jobs.
pub fn (g Graph) privileged() Graph {
	return Graph{
		client: g.client.privileged()
	}
}

// on_commit runs `f` once the transaction of `g` (in `tx`) commits; outside
// one, at once.
pub fn (g Graph) on_commit(f fn ()) {
	g.client.on_commit(f)
}

// on_rollback runs `f` if the transaction of `g` (in `tx`) rolls back.
pub fn (g Graph) on_rollback(f fn ()) {
	g.client.on_rollback(f)
}

// NotFoundError is the error of `first()` when no row matches, and of a write
// to one row that doesn\'t exist.
pub struct NotFoundError {
	Error
pub:
	table string
}

// msg names the table that had no matching row.
pub fn (e NotFoundError) msg() string {
	return "no `\${e.table}` row matches"
}

// NotSingularError is the error of `only()` and `only_id()` when more than one
// row matches.
pub struct NotSingularError {
	Error
pub:
	table string
}

// msg names the table that had more than one matching row.
pub fn (e NotSingularError) msg() string {
	return "more than one `\${e.table}` row matches"
}

// NotLoadedError is the error of a node\'s `<edge>_or_err()` when its query
// didn\'t load the edge.
pub struct NotLoadedError {
	Error
pub:
	edge string
}

// msg names the edge that wasn\'t loaded.
pub fn (e NotLoadedError) msg() string {
	return "`\${e.edge}` wasn\'t loaded: ask for it with `with_<edge>`"
}

// with_conds returns `conds` and `more`, for a subquery\'s conditions.
fn with_conds(conds []load.Cond, more ...load.Cond) []load.Cond {
	mut all := conds.clone()
	all << more
	return all
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
	if t.columns.any(it.json_type != '') {
		imports << 'json2'
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
		if edge.kind in ['one_to_many', 'many_to_many'] {
			b.writeln('	named_${edge.name} map[string][]fn (${targets[i].query()}) ${targets[i].query()}')
		}
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
		if edge.kind in ['one_to_many', 'many_to_many'] {
			b.writeln('	named_${edge.name} map[string][]${targets[i].node()} // set by `with_named_${edge.name}()`')
		}
	}
	b.writeln('	// loaded: the edges the query loaded
	loaded []string
}')

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

// limit keeps at most `count` rows. In `with_<edge>`, it keeps at most `count`
// of each row\'s targets.
pub fn (q ${q}) limit(count int) ${q} {
	mut next := q
	next.query = load.Query{
		...q.query
		limit: count
	}
	return next
}

// offset skips the first `count` rows. In `with_<edge>`, it skips the first
// `count` of each row\'s targets.
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
	return load.count_where[${info.typ()}](q.graph.client.conn, q.graph.client.prepare_query(\'${t.name}\', q.query)!)
}')
	preds := predicates(info, infos)!
	write_pred_functions(mut b, preds)
	write_order_methods(mut b, t, q)
	write_query_api(mut b, info, infos, preds)!
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
	rows := load.select_where[${info.typ()}](q.graph.client.conn, q.graph.client.prepare_query(\'${t.name}\', q.query)!)!
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
}')
	write_nodes(mut b, info, infos)!
	write_edge_methods(mut b, info, infos)!
	for c in t.columns {
		if c.json_type == '' {
			continue
		}
		jt := c.json_v_type(info)
		text := if c.nullable {
			"n.${info.field()}.${c.field} or { return error('`${t.name}.${c.name}` is null') }"
		} else {
			'n.${info.field()}.${c.field}'
		}
		b.writeln('
// ${c.field}_value returns `${c.name}`, decoded from JSON.
pub fn (n ${n}) ${c.field}_value() !${jt} {
	text := ${text}
	return json2.decode[${jt}](text)!
}')
	}
	for i, edge in t.edges {
		write_traversal(mut b, info, edge, targets[i])!
	}
	return b.str()
}

// write_order_methods writes `order_by_<field>` and `order_by_<field>_desc`
// for each column of `t`, which add an order column.
fn write_order_methods(mut b strings.Builder, t Table, q string) {
	for c in t.columns {
		if !c.scalar() || c.json_type != '' {
			continue
		}
		b.writeln('
// order_by_${c.field} orders the rows by `${c.name}`, ascending, after the orders
// given before.
pub fn (q ${q}) order_by_${c.field}() ${q} {
	return q.order_by(load.asc(\'${c.name}\'))
}

// order_by_${c.field}_desc orders the rows by `${c.name}`, descending, after the
// orders given before.
pub fn (q ${q}) order_by_${c.field}_desc() ${q} {
	return q.order_by(load.desc(\'${c.name}\'))
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
	parts << "query: q.graph.client.prepare_edge_query('${edge.to}', sub.query)!"
	return parts.join(', ')
}

// filters_unordered returns the named options that narrow an edge's rows,
// read by key, unordered, from `prepared`, the prepared query of `sub`.
fn filters_unordered(edge Edge, with_type bool) string {
	mut parts := []string{}
	if with_type && edge.type_col != '' {
		parts << "type_col: '${edge.type_col}'"
		parts << "type_val: '${edge.type_val}'"
	}
	if edge.soft_del != '' {
		parts << "soft_del: '${edge.soft_del}'"
	}
	parts << "query: load.Query{ ...prepared, order: '', desc: false, orders: []load.Order{}, limit: 0, offset: 0 }"
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
