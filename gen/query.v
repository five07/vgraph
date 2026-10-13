module gen

import strings

// The query API of each table beyond `where` and edge loads: predicates as
// methods and as functions (for `load.or`, `load.not`), edge predicates,
// traversal from a query, result methods, aggregates, edge orders, locks and
// named edges.

// Pred is one predicate: a function returning a `load.Cond`, and a method of
// each query and builder that keeps the rows matching it.
struct Pred {
	method string
	func   string
	params string
	args   string
	body   string // the condition, from the parameters
	doc    string
	// method_body: the method's condition when it differs from the function's
	method_body string
}

// sub_conds returns the V expression of `conds` with `more` added.
fn sub_conds(conds string, more []string) string {
	if more.len == 0 {
		return conds
	}
	return 'with_conds(${conds}, ${more.join(', ')})'
}

// edge_extras returns the conditions every target of `e` meets: its type, for a
// polymorphic edge that filters its targets, and not deleted, for `soft_del`.
fn edge_extras(e Edge, with_type bool) []string {
	mut more := []string{}
	if with_type && e.type_col != '' {
		more << "load.eq('${e.type_col}', '${e.type_val}')"
	}
	if e.soft_del != '' {
		more << "load.is_null('${e.soft_del}')"
	}
	return more
}

// has_cond returns the V expression of the condition that a row of `info` has
// a target of `e` matching `conds` (a V expression of a `[]load.Cond`).
fn has_cond(info Info, e Edge, target Info, conds string) !string {
	t := info.table
	kind := info.key_type()!
	tkind := target.key_type()!
	return match e.kind {
		'one_to_many', 'one_to_one' {
			"load.in_sub('${t.key}', load.Sub{ table: '${target.table.name}', column: '${e.column}', kind: .${kind}, conds: ${sub_conds(conds, edge_extras(e, true))} })"
		}
		'many_to_one' {
			// not null too: so its negation keeps the rows whose column is null,
			// which `NOT (column IN (…))` leaves out
			has := "load.is_not_null('${e.column}'), load.in_sub('${e.column}', load.Sub{ table: '${target.table.name}', column: '${target.table.key}', kind: .${tkind}, conds: ${sub_conds(conds, edge_extras(e, false))} })"
			if e.type_col != '' {
				"load.and(load.eq('${e.type_col}', '${e.type_val}'), ${has})"
			} else {
				'load.and(${has})'
			}
		}
		'many_to_many' {
			"load.in_sub('${t.key}', load.Sub{ table: '${e.through}', column: '${e.column}', kind: .${kind}, conds: [load.in_sub('${e.through_to}', load.Sub{ table: '${target.table.name}', column: '${target.table.key}', kind: .${tkind}, conds: ${sub_conds(conds, edge_extras(e, true))} })] })"
		}
		else {
			error('`${t.name}.${e.name}`: unknown edge kind `${e.kind}`')
		}
	}
}

// predicates returns the predicates of the table of `info`: each field's, by
// type, and each edge's.
fn predicates(info Info, infos map[string]Info) ![]Pred {
	t := info.table
	prefix := snake(info.entity.struct_name)
	mut preds := []Pred{}
	for c in t.columns {
		col := "'${c.name}'"
		if c.scalar() && c.json_type == '' {
			vt := c.v_type(info)
			value := c.to_prim('value')
			add_pred(mut preds, prefix, c, 'eq', 'value ${vt}', 'value', 'load.eq(${col}, ${value})',
				'`${c.name}` is `value`')
			add_pred(mut preds, prefix, c, 'ne', 'value ${vt}', 'value', 'load.ne(${col}, ${value})',
				'`${c.name}` is not `value`')
			if c.ordered() {
				for op, words in {
					'lt': 'comes before'
					'le': 'comes at or before'
					'gt': 'comes after'
					'ge': 'comes at or after'
				} {
					add_pred(mut preds, prefix, c, op, 'value ${vt}', 'value', 'load.${op}(${col}, ${value})',
						'`${c.name}` ${words} `value`')
				}
			}
			if c.base() in int_types || c.base() in ['string', 'enum'] {
				list, conv := c.list()
				values := if conv == '' { 'values' } else { 'values.map(${conv})' }
				add_pred(mut preds, prefix, c, 'in', 'values []${vt}', 'values', 'load.in_${list}(${col}, ${values})',
					'`${c.name}` is one of `values`')
				add_pred(mut preds, prefix, c, 'not_in', 'values []${vt}', 'values', 'load.not_in_${list}(${col}, ${values})',
					'`${c.name}` is none of `values`')
			}
			if c.base() == 'string' {
				add_pred(mut preds, prefix, c, 'like', 'pattern string', 'pattern', 'load.like(${col}, pattern)',
					'`${c.name}` matches the SQL LIKE `pattern`')
				add_pred(mut preds, prefix, c, 'contains', 'value string', 'value', 'load.contains(${col}, value)',
					'`${c.name}` contains `value`')
				add_pred(mut preds, prefix, c, 'has_prefix', 'value string', 'value', 'load.has_prefix(${col}, value)',
					'`${c.name}` starts with `value`')
				add_pred(mut preds, prefix, c, 'has_suffix', 'value string', 'value', 'load.has_suffix(${col}, value)',
					'`${c.name}` ends with `value`')
				add_pred(mut preds, prefix, c, 'equal_fold', 'value string', 'value', 'load.equal_fold(${col}, value)',
					'`${c.name}` is `value`, ignoring case')
				add_pred(mut preds, prefix, c, 'contains_fold', 'value string', 'value', 'load.contains_fold(${col}, value)',
					'`${c.name}` contains `value`, ignoring case')
			}
		}
		if c.nullable {
			add_pred(mut preds, prefix, c, 'is_null', '', '', 'load.is_null(${col})', '`${c.name}` is null')
			add_pred(mut preds, prefix, c, 'is_not_null', '', '', 'load.is_not_null(${col})', '`${c.name}` is not null')
		}
	}
	for e in t.edges {
		target := infos[e.to] or { continue }
		preds << Pred{
			method: 'has_${e.name}'
			func:   '${prefix}_has_${e.name}'
			body:   has_cond(info, e, target, '[]load.Cond{}')!
			doc:    'it has a `${e.name}`'
		}
		preds << Pred{
			method:      'has_${e.name}_with'
			func:        '${prefix}_has_${e.name}_with'
			params:      'conds ...load.Cond'
			args:        '...conds'
			body:        has_cond(info, e, target, 'conds')!
			doc:         'it has a `${e.name}` that matches `conds`'
			method_body: '${prefix}_has_${e.name}_with(...configure(q.graph.${target.table.name}()).query.conds)'
		}
	}
	return preds
}

fn add_pred(mut preds []Pred, prefix string, c Column, op string, params string, args string, body string, doc string) {
	preds << Pred{
		method: if op == 'eq' { 'where_${c.field}' } else { 'where_${c.field}_${op}' }
		func:   '${prefix}_${c.field}_${op}'
		params: params
		args:   args
		body:   body
		doc:    doc
	}
}

// write_pred_functions writes the predicate functions of a table.
fn write_pred_functions(mut b strings.Builder, preds []Pred) {
	for p in preds {
		b.writeln('
// ${p.func} returns the condition that ${p.doc}.
pub fn ${p.func}(${p.params}) load.Cond {
	return ${p.body}
}')
	}
}

// write_pred_methods writes the predicate methods of the query or builder
// `typ`, which has a `where(conds ...load.Cond)` method and a `graph`.
fn write_pred_methods(mut b strings.Builder, typ string, preds []Pred, infos map[string]Info, info Info) {
	for p in preds {
		if p.method_body != '' {
			// has_<edge>_with: from a query of the target
			edge := p.method.all_before_last('_with').all_after('has_')
			mut target_query := ''
			for e in info.table.edges {
				if e.name == edge {
					target_query = (infos[e.to] or { continue }).query()
				}
			}
			b.writeln('
// ${p.method} keeps the rows that have a `${edge}` that `configure` keeps.
pub fn (q ${typ}) ${p.method}(configure fn (${target_query}) ${target_query}) ${typ} {
	return q.where(${p.method_body})
}')
			continue
		}
		b.writeln('
// ${p.method} keeps the rows where ${p.doc}.
pub fn (q ${typ}) ${p.method}(${p.params}) ${typ} {
	return q.where(${p.func}(${p.args}))
}')
	}
}

// order_sql returns the SQL expression that orders the rows of `info` by the
// edge `e`: its number of targets (`field` empty), or, for a unique edge, its
// target's `field`. The table read is `t0`.
fn order_sql(info Info, e Edge, target Info, field string) string {
	t := info.table
	match e.kind {
		'one_to_many', 'one_to_one' {
			mut where := '"t1"."${e.column}" = "t0"."${t.key}"'
			if e.type_col != '' {
				where += ' AND "t1"."${e.type_col}" = \'${e.type_val}\''
			}
			if e.soft_del != '' {
				where += ' AND "t1"."${e.soft_del}" IS NULL'
			}
			if field == '' {
				return '(SELECT COUNT(*) FROM "${target.table.name}" AS "t1" WHERE ${where})'
			}
			return '(SELECT "t1"."${field}" FROM "${target.table.name}" AS "t1" WHERE ${where} LIMIT 1)'
		}
		'many_to_one' {
			mut where := '"t1"."${target.table.key}" = "t0"."${e.column}"'
			if e.type_col != '' {
				where += ' AND "t0"."${e.type_col}" = \'${e.type_val}\''
			}
			return '(SELECT "t1"."${field}" FROM "${target.table.name}" AS "t1" WHERE ${where})'
		}
		else {
			return '(SELECT COUNT(*) FROM "${e.through}" AS "t1" WHERE "t1"."${e.column}" = "t0"."${t.key}")'
		}
	}
}

// write_query_api writes the methods of the query of `info` beyond `where`,
// `with_<edge>` and `all`.
fn write_query_api(mut b strings.Builder, info Info, infos map[string]Info, preds []Pred) ! {
	t := info.table
	q := info.query()
	n := info.node()
	key := info.key_type()!
	prefix := snake(info.entity.struct_name)
	conn := 'q.graph.client.conn'
	prepared := "q.graph.client.prepare_query('${t.name}', q.query)!"
	write_pred_methods(mut b, q, preds, infos, info)

	// traversal from a query
	for e in t.edges {
		target := infos[e.to] or { continue }
		tq := target.query()
		tkind := target.key_type()!
		extras := edge_extras(e, e.kind != 'many_to_one')
		mut conds := []string{}
		match e.kind {
			'one_to_many', 'one_to_one' {
				conds << "load.in_sub('${e.column}', load.Sub{ table: '${t.name}', column: '${t.key}', kind: .${key}, conds: q.query.conds })"
			}
			'many_to_one' {
				source := if e.type_col != '' {
					"with_conds(q.query.conds, load.eq('${e.type_col}', '${e.type_val}'))"
				} else {
					'q.query.conds'
				}
				conds << "load.in_sub('${target.table.key}', load.Sub{ table: '${t.name}', column: '${e.column}', kind: .${tkind}, conds: ${source} })"
			}
			else {
				conds << "load.in_sub('${target.table.key}', load.Sub{ table: '${e.through}', column: '${e.through_to}', kind: .${tkind}, conds: [load.in_sub('${e.column}', load.Sub{ table: '${t.name}', column: '${t.key}', kind: .${key}, conds: q.query.conds })] })"
			}
		}
		conds << extras
		b.writeln('
// query_${e.name} starts a query of the `${e.name}` of the rows that match this
// query\'s conditions; its order, limit and offset don\'t apply.
pub fn (q ${q}) query_${e.name}() ${tq} {
	return q.graph.${target.table.name}().where(${conds.join(', ')})
}')
	}

	// results
	convert := match key {
		'int' { '.map(it.int())' }
		'i64' { '.map(it.i64())' }
		else { '' }
	}
	b.writeln('
// only returns the one matching row, with the requested edges: a
// `NotFoundError` when there is none, a `NotSingularError` when there are more.
pub fn (q ${q}) only() !${n} {
	nodes := q.limit(2).all()!
	if nodes.len == 0 {
		return NotFoundError{
			table: \'${t.name}\'
		}
	}
	if nodes.len > 1 {
		return NotSingularError{
			table: \'${t.name}\'
		}
	}
	return nodes[0]
}

// ids returns the keys of the matching rows, in order, and no edges.
pub fn (q ${q}) ids() ![]${key} {
	keys := load.select_keys_where(${conn}, \'${t.name}\', \'${t.key}\', .${key}, ${prepared}, true)!
	return keys${convert}
}

// first_id returns the key of the first matching row, or a `NotFoundError`.
pub fn (q ${q}) first_id() !${key} {
	ids := q.limit(1).ids()!
	if ids.len == 0 {
		return NotFoundError{
			table: \'${t.name}\'
		}
	}
	return ids[0]
}

// only_id returns the key of the one matching row: a `NotFoundError` when
// there is none, a `NotSingularError` when there are more.
pub fn (q ${q}) only_id() !${key} {
	ids := q.limit(2).ids()!
	if ids.len == 0 {
		return NotFoundError{
			table: \'${t.name}\'
		}
	}
	if ids.len > 1 {
		return NotSingularError{
			table: \'${t.name}\'
		}
	}
	return ids[0]
}

// exist reports whether any row matches.
pub fn (q ${q}) exist() !bool {
	return q.limit(1).ids()!.len > 0
}

// select reads only `columns`, and the key, of the rows; the others keep their
// zero values. An edge load needs the columns it follows.
pub fn (q ${q}) select(columns ...string) ${q} {
	mut all := columns.clone()
	if \'${t.key}\' !in all {
		all << \'${t.key}\'
	}
	mut next := q
	next.query = load.Query{
		...q.query
		columns: all
	}
	return next
}

// unique makes `scan` read each distinct row once.
pub fn (q ${q}) unique() ${q} {
	mut next := q
	next.query = load.Query{
		...q.query
		distinct: true
	}
	return next
}

// scan reads the matching rows into `T`, the app\'s struct for some of the
// columns, by column name.
pub fn (q ${q}) scan[T]() ![]T {
	return load.select_into[T](${conn}, \'${t.name}\', \'${t.key}\', .${key}, ${prepared})
}

// order_by orders the rows by `orders` too, after the orders given before,
// such as `vgraph.desc(\'id\').nulls_last()`.
pub fn (q ${q}) order_by(orders ...load.Order) ${q} {
	mut all := q.query.orders.clone()
	all << orders
	mut next := q
	next.query = load.Query{
		...q.query
		orders: all
	}
	return next
}')
	for mode in ['update', 'share'] {
		b.writeln('
// for_${mode} locks the matching rows (FOR ${mode.to_upper()}) until the transaction ends.
// It runs in `tx`, on PostgreSQL.
pub fn (q ${q}) for_${mode}() ${q} {
	mut next := q
	next.query = load.Query{
		...q.query
		lock: load.Lock{
			...q.query.lock
			mode: .${mode}
		}
	}
	return next
}')
	}
	for opt, words in {
		'no_wait':     'fails at once on a row another transaction locked'
		'skip_locked': 'leaves out the rows other transactions locked'
	} {
		b.writeln('
// ${opt} makes the lock one that ${words}.
pub fn (q ${q}) ${opt}() ${q} {
	mut next := q
	next.query = load.Query{
		...q.query
		lock: load.Lock{
			...q.query.lock
			${opt}: true
		}
	}
	return next
}')
	}

	// aggregates
	for c in t.columns {
		if !c.numeric() {
			continue
		}
		for name, kind in {
			'sum':  'sum'
			'min':  'min'
			'max':  'max'
			'mean': 'avg'
		} {
			b.writeln('
// ${name}_${c.field} returns the ${name} of `${c.name}` over the matching rows, in one
// query; 0 when none has a value.
pub fn (q ${q}) ${name}_${c.field}() !f64 {
	return load.aggregate_where(${conn}, \'${t.name}\', \'${t.key}\', ${prepared}, .${kind}, \'${c.name}\')
}')
		}
	}
	gb := '${info.entity.struct_name}GroupBy'
	b.writeln('
// ${gb} groups the rows of a `${q}`. Start one with `group_by`.
pub struct ${gb} {
	query ${q}
pub:
	columns    []string
	aggregates []load.Aggregate
}

// group_by groups the matching rows by `columns`. It needs a vgraph driver.
pub fn (q ${q}) group_by(columns ...string) ${gb} {
	return ${gb}{
		query:   q
		columns: columns
	}
}

// aggregate adds what each group gets, such as `vgraph.count()` or
// `vgraph.sum(\'views\')`.
pub fn (g ${gb}) aggregate(aggregates ...load.Aggregate) ${gb} {
	mut all := g.aggregates.clone()
	all << aggregates
	return ${gb}{
		...g
		aggregates: all
	}
}

// all returns the groups, ordered by their columns.
pub fn (g ${gb}) all() ![]load.Group {
	q := g.query
	return load.group_where(${conn}, \'${t.name}\', ${prepared}, g.columns.map(load.GroupColumn{
		name: it
		typ:  ${prefix}_column_type(it)
	}), g.aggregates)
}

// scan reads the groups into `T`, by name: its fields named after the grouped
// columns and the aggregates (`count`, `sum_views`).
pub fn (g ${gb}) scan[T]() ![]T {
	return load.scan_groups[T](g.all()!)
}

// ${prefix}_column_type returns the V type of a column of `${t.name}`.
fn ${prefix}_column_type(column string) string {
	return match column {')
	for c in t.columns {
		b.writeln("		'${c.name}' { '${c.typ}' }")
	}
	b.writeln("		else { '' }
	}
}")

	// edge orders, and named edges
	for e in t.edges {
		target := infos[e.to] or { continue }
		if e.kind in ['one_to_many', 'many_to_many'] {
			b.writeln('
// order_by_${e.name}_count orders the rows by their number of `${e.name}`.
pub fn (q ${q}) order_by_${e.name}_count() ${q} {
	return q.order_by(load.Order{
		expr: ${v_string(order_sql(info, e, target, ''))}
	})
}

// order_by_${e.name}_count_desc orders the rows by their number of `${e.name}`, most
// first.
pub fn (q ${q}) order_by_${e.name}_count_desc() ${q} {
	return q.order_by(load.Order{
		expr: ${v_string(order_sql(info, e, target, ''))}
		desc: true
	})
}

// with_named_${e.name} loads `${e.name}` as `configure` says into
// `named_${e.name}[name]`, besides any other load of it.
pub fn (q ${q}) with_named_${e.name}(name string, configure ...fn (${target.query()}) ${target.query()}) ${q} {
	mut next := q
	mut named := q.named_${e.name}.clone()
	named[name] = configure
	next.named_${e.name} = named
	return next
}')
		} else {
			for c in target.table.columns {
				if !c.scalar() || c.json_type != '' {
					continue
				}
				// a many_to_one edge's key is its own column; and a field's order
				// takes its name first
				if (e.kind == 'many_to_one' && c.name == target.table.key)
					|| t.columns.any(it.field == '${e.name}_${c.field}') {
					continue
				}
				expr := v_string(order_sql(info, e, target, c.name))
				b.writeln('
// order_by_${e.name}_${c.field} orders the rows by the `${c.name}` of their `${e.name}`.
pub fn (q ${q}) order_by_${e.name}_${c.field}() ${q} {
	return q.order_by(load.Order{
		expr: ${expr}
	})
}

// order_by_${e.name}_${c.field}_desc orders the rows by the `${c.name}` of their
// `${e.name}`, descending.
pub fn (q ${q}) order_by_${e.name}_${c.field}_desc() ${q} {
	return q.order_by(load.Order{
		expr: ${expr}
		desc: true
	})
}')
			}
		}
	}
}

// write_edge_methods writes, for each edge, the private method that loads it
// for some rows, keyed by each row's key, and the node's `<edge>_or_err`.
fn write_edge_methods(mut b strings.Builder, info Info, infos map[string]Info) ! {
	t := info.table
	q := info.query()
	n := info.node()
	key := info.key_field()!
	for e in t.edges {
		target := infos[e.to] or { continue }
		tq := target.query()
		tn := target.node()
		b.writeln('
// load_${e.name} loads the `${e.name}` of `rows`, keyed by each row\'s key.
fn (q ${q}) load_${e.name}(rows []${info.typ()}, fns []fn (${tq}) ${tq}) !map[string][]${tn} {
	mut sub := q.graph.${target.table.name}()
	for configure in fns {
		sub = configure(sub)
	}')
		match e.kind {
			'one_to_many', 'one_to_one' {
				fk := target.table.column(e.column)!
				// a limit or offset applies to each row's children
				b.writeln("	children := sub.nodes(load.select_each[${target.typ()}](q.graph.client.conn, '${e.column}',
		rows.map(it.${key}.str()), ${filters(e, true)})!)!
	mut by_parent := map[string][]${tn}{}
	for child in children {")
				if fk.nullable {
					b.writeln('		if parent := child.${target.field()}.${fk.field} {
			by_parent[parent.str()] << child
		}')
				} else {
					b.writeln('		by_parent[child.${target.field()}.${fk.field}.str()] << child')
				}
				b.writeln('	}
	return by_parent
}')
			}
			'many_to_one' {
				fk := t.column(e.column)!
				target_key := target.key_field()!
				check := type_check('row', info, e)!
				fk_expr := if fk.nullable { 'fk' } else { 'row.${fk.field}' }
				b.writeln('	mut keys := []string{}
	for row in rows {')
				if check != '' {
					b.writeln('		if !(${check}) {
			continue
		}')
				}
				if fk.nullable {
					b.writeln('		if fk := row.${fk.field} {
			keys << fk.str()
		}')
				} else {
					b.writeln('		keys << row.${fk.field}.str()')
				}
				b.writeln("	}
	targets := sub.nodes(load.select_in[${target.typ()}](q.graph.client.conn, '${target.table.key}',
		load.unique(keys), ${filters(e, false)})!)!
	mut by_key := map[string]${tn}{}
	for target in targets {
		by_key[target.${target.field()}.${target_key}.str()] = target
	}
	mut found := map[string][]${tn}{}
	for row in rows {")
				if check != '' {
					b.writeln('		if !(${check}) {
			continue
		}')
				}
				if fk.nullable {
					b.writeln('		fk := row.${fk.field} or { continue }')
				}
				b.writeln('		if target := by_key[${fk_expr}.str()] {
			found[row.${key}.str()] = [target]
		}
	}
	return found
}')
			}
			'many_to_many' {
				target_key := target.key_field()!
				conds := sub_conds('prepared.conds', edge_extras(e, true))
				// a limit or offset applies to each row's targets: the join rows
				// come cut, in the targets' order
				b.writeln("	if sub.query.limit > 0 || sub.query.offset > 0 {
		prepared := q.graph.client.prepare_edge_query('${e.to}', sub.query)!
		cut := load.link_each(q.graph.client.conn, '${e.through}', '${e.column}', '${e.through_to}',
			rows.map(it.${key}.str()), .${info.key_type()!}, .${target.key_type()!}, '${target.table.name}', '${target.table.key}', load.Query{
			...prepared
			conds: ${conds}
		})!
		// the targets by key: the join rows give their order
		found := sub.nodes(load.select_in[${target.typ()}](q.graph.client.conn, '${target.table.key}',
			load.unique(cut.map(it[1])), ${filters_unordered(e, true)})!)!
		mut by_key := map[string]${tn}{}
		for target in found {
			by_key[target.${target.field()}.${target_key}.str()] = target
		}
		mut cut_linked := map[string][]${tn}{}
		for pair in cut {
			if target := by_key[pair[1]] {
				cut_linked[pair[0]] << target
			}
		}
		return cut_linked
	}")
				b.writeln("	pairs := load.link_pairs(q.graph.client.conn, '${e.through}', '${e.column}',
		'${e.through_to}', rows.map(it.${key}.str()), .${info.key_type()!}, .${target.key_type()!})!
	targets := sub.nodes(load.select_in[${target.typ()}](q.graph.client.conn, '${target.table.key}',
		load.unique(pairs.map(it[1])), ${filters(e, true)})!)!
	// each parent's targets in the order of the query
	mut parents_of := map[string][]string{}
	for pair in pairs {
		parents_of[pair[1]] << pair[0]
	}
	mut linked := map[string][]${tn}{}
	for target in targets {
		for parent in parents_of[target.${target.field()}.${target_key}.str()] or { [] } {
			linked[parent] << target
		}
	}
	return linked
}")
			}
			else {
				return error('`${t.name}.${e.name}`: unknown edge kind `${e.kind}`')
			}
		}
		if e.kind in ['many_to_one', 'one_to_one'] {
			b.writeln('
// ${e.name}_or_err returns the `${e.name}`: a `NotLoadedError` when the query didn\'t
// load it, a `NotFoundError` when the row has none.
pub fn (n ${n}) ${e.name}_or_err() !&${tn} {
	if \'${e.name}\' !in n.loaded {
		return NotLoadedError{
			edge: \'${t.name}.${e.name}\'
		}
	}
	if target := n.${e.name} {
		return target
	}
	return NotFoundError{
		table: \'${e.to}\'
	}
}')
		} else {
			b.writeln('
// ${e.name}_or_err returns the `${e.name}`, or a `NotLoadedError` when the query
// didn\'t load them.
pub fn (n ${n}) ${e.name}_or_err() ![]${tn} {
	if \'${e.name}\' !in n.loaded {
		return NotLoadedError{
			edge: \'${t.name}.${e.name}\'
		}
	}
	return n.${e.name}
}')
		}
	}
}

// write_nodes writes `nodes`, which loads the requested edges onto rows.
fn write_nodes(mut b strings.Builder, info Info, infos map[string]Info) ! {
	t := info.table
	q := info.query()
	n := info.node()
	key := info.key_field()!
	b.writeln('
// nodes loads the requested edges onto `rows`, which the caller already has: one
// query per edge, however many rows there are.
pub fn (q ${q}) nodes(rows []${info.typ()}) ![]${n} {
	mut nodes := rows.map(${n}{
		graph: q.graph
		${info.field()}: it
	})')
	for e in t.edges {
		target := infos[e.to] or { continue }
		row_key := 'node.${info.field()}.${key}.str()'
		b.writeln('	if q.with_${e.name} {
		found := q.load_${e.name}(rows, q.${e.name}_fns)!
		for mut node in nodes {')
		if e.kind in ['many_to_one', 'one_to_one'] {
			b.writeln('			// at most one each: the first, in the order of the query
			list := found[${row_key}] or { [] }
			if list.len > 0 {
				node.${e.name} = &${target.node()}{
					...list[0]
				}
			}')
		} else {
			b.writeln('			node.${e.name} = found[${row_key}] or { [] }')
		}
		b.writeln("			node.loaded << '${e.name}'
		}
	}")
		if e.kind in ['one_to_many', 'many_to_many'] {
			b.writeln('	for name, fns in q.named_${e.name} {
		found := q.load_${e.name}(rows, fns)!
		for mut node in nodes {
			node.named_${e.name}[name] = found[${row_key}] or { [] }
		}
	}')
		}
	}
	b.writeln('	return nodes\n}')
}
