module gen

import strings

// The write API of each table: its typed mutation, and the builders for
// creates, updates and deletes, generated into `<table>_mutation.v`.

// reserved_getters are the methods of a generated mutation that its typed
// getters, named after the fields, must not take.
const reserved_getters = ['data', 'operation', 'table_name', 'changed_columns', 'field_value',
	'added_ids', 'removed_ids', 'edge_cleared', 'set_field_value', 'clear_field_value']

// Setter is one method of a builder, as `name(params) body`.
struct Setter {
	name   string
	params string
	// body returns the next builder's data from `b.data`
	data string
	doc  string
}

fn (i Info) mutation() string {
	return '${i.entity.struct_name}Mutation'
}

fn (i Info) create() string {
	return '${i.entity.struct_name}Create'
}

fn (i Info) create_bulk() string {
	return '${i.entity.struct_name}CreateBulk'
}

fn (i Info) update_one() string {
	return '${i.entity.struct_name}UpdateOne'
}

fn (i Info) update() string {
	return '${i.entity.struct_name}Update'
}

fn (i Info) delete_one() string {
	return '${i.entity.struct_name}DeleteOne'
}

fn (i Info) delete() string {
	return '${i.entity.struct_name}Delete'
}

// primitive returns the V expression of `value`, a `typ`, as an
// `orm.Primitive`.
fn primitive(value string) string {
	return 'orm.Primitive(${value})'
}

// nillable returns the expression of an option `value` as an
// `orm.Primitive`: null for `none`.
fn nillable(value string) string {
	return 'if v := ${value} { orm.Primitive(v) } else { orm.Primitive(orm.Null{}) }'
}

// field_setters returns the setters of the columns a create (`create`) or an
// update may set.
fn field_setters(info Info, create bool) []Setter {
	mut setters := []Setter{}
	for c in info.table.columns {
		base := c.typ.trim_left('?')
		if base !in ['int', 'i64', 'f64', 'bool', 'string', 'time.Time'] {
			continue
		}
		if create && c.serial {
			continue
		}
		if !create && (c.name == info.table.key || c.immutable) {
			continue
		}
		setters << Setter{
			name:   'set_${c.field}'
			params: 'value ${base}'
			data:   "b.data.with_value('${c.name}', ${primitive('value')})"
			doc:    'sets `${c.name}`'
		}
		if c.nullable {
			setters << Setter{
				name:   'set_nillable_${c.field}'
				params: 'value ?${base}'
				data:   "b.data.with_value('${c.name}', ${nillable('value')})"
				doc:    'sets `${c.name}`, to null for `none`'
			}
			if !create {
				setters << Setter{
					name: 'clear_${c.field}'
					data: "b.data.with_value('${c.name}', orm.Primitive(orm.Null{}))"
					doc:  'sets `${c.name}` to null'
				}
			}
		}
		// not on a column that holds another row's key
		holds_key := info.table.edges.any(it.kind == 'many_to_one' && it.column == c.name)
		if !create && base in ['int', 'i64', 'f64'] && !holds_key {
			setters << Setter{
				name:   'add_${c.field}'
				params: 'delta ${base}'
				data:   "b.data.with_add('${c.name}', ${primitive('delta')})"
				doc:    'adds `delta` to `${c.name}`, in the database'
			}
		}
	}
	return setters
}

// edge_setters returns the setters of the edges of a create (`create`) or an
// update.
fn edge_setters(info Info, infos map[string]Info, create bool) ![]Setter {
	mut setters := []Setter{}
	t := info.table
	for e in t.edges {
		target := infos[e.to] or { continue }
		key := target.key_type()!
		target_key := '${target.field()}.${target.key_field()!}'
		match e.kind {
			'many_to_one' {
				column := t.column(e.column)!
				mut set := "b.data.with_value('${e.column}', ${primitive('id')})"
				if e.type_col != '' {
					set = "${set}.with_value('${e.type_col}', orm.Primitive('${e.type_val}'))"
				}
				// a field setter does the same, unless the edge is polymorphic
				if column.field != '${e.name}_id' || e.type_col != '' {
					setters << Setter{
						name:   'set_${e.name}_id'
						params: 'id ${key}'
						data:   set
						doc:    'sets `${e.name}` to the `${e.to}` row with the key `id`'
					}
				}
				setters << Setter{
					name:   'set_${e.name}'
					params: 'node ${target.node()}'
					data:   set.replace(primitive('id'), primitive('node.${target_key}'))
					doc:    'sets `${e.name}` to `node`'
				}
				if !create && column.nullable {
					setters << Setter{
						name: 'clear_${e.name}'
						data: "b.data.with_value('${e.column}', orm.Primitive(orm.Null{}))"
						doc:  'removes the `${e.name}`'
					}
				}
			}
			'one_to_one' {
				nullable := target.table.column(e.column)!.nullable
				// on an update, the target that had it loses it first, when it can
				prefix := if !create && nullable {
					"b.data.with_cleared('${e.name}')"
				} else {
					'b.data'
				}
				setters << Setter{
					name:   'set_${e.name}_id'
					params: 'id ${key}'
					data:   "${prefix}.with_added('${e.name}', [id.str()])"
					doc:    'sets `${e.name}` to the `${e.to}` row with the key `id`'
				}
				setters << Setter{
					name:   'set_${e.name}'
					params: 'node ${target.node()}'
					data:   "${prefix}.with_added('${e.name}', [node.${target_key}.str()])"
					doc:    'sets `${e.name}` to `node`'
				}
				if !create {
					setters << Setter{
						name: 'clear_${e.name}'
						data: "b.data.with_cleared('${e.name}')"
						doc:  'removes the `${e.name}`'
					}
				}
			}
			'one_to_many', 'many_to_many' {
				setters << Setter{
					name:   'add_${e.name}_ids'
					params: 'ids ...${key}'
					data:   "b.data.with_added('${e.name}', ids.map(it.str()))"
					doc:    'adds the `${e.to}` rows with the keys `ids` to `${e.name}`'
				}
				setters << Setter{
					name:   'add_${e.name}'
					params: 'nodes ...${target.node()}'
					data:   "b.data.with_added('${e.name}', nodes.map(it.${target_key}.str()))"
					doc:    'adds `nodes` to `${e.name}`'
				}
				if !create {
					setters << Setter{
						name:   'remove_${e.name}_ids'
						params: 'ids ...${key}'
						data:   "b.data.with_removed('${e.name}', ids.map(it.str()))"
						doc:    'removes the `${e.to}` rows with the keys `ids` from `${e.name}`'
					}
					setters << Setter{
						name:   'remove_${e.name}'
						params: 'nodes ...${target.node()}'
						data:   "b.data.with_removed('${e.name}', nodes.map(it.${target_key}.str()))"
						doc:    'removes `nodes` from `${e.name}`'
					}
					setters << Setter{
						name: 'clear_${e.name}'
						data: "b.data.with_cleared('${e.name}')"
						doc:  'removes every row from `${e.name}`, before any are added'
					}
				}
			}
			else {}
		}
	}
	return setters
}

// setters_of returns every setter of a create or an update builder, and
// rejects two of one name.
fn setters_of(info Info, infos map[string]Info, create bool) ![]Setter {
	mut all := field_setters(info, create)
	all << edge_setters(info, infos, create)!
	mut seen := map[string]bool{}
	for s in all {
		if s.name in seen {
			return error('`${info.table.name}`: two setters would be named `${s.name}`; rename a field or an edge')
		}
		seen[s.name] = true
	}
	return all
}

fn write_setters(mut b strings.Builder, typ string, setters []Setter) {
	for s in setters {
		b.writeln('
// ${s.name} ${s.doc}.
pub fn (b ${typ}) ${s.name}(${s.params}) ${typ} {
	return ${typ}{
		...b
		data: ${s.data}
	}
}')
	}
}

fn mutation_file(out_module string, info Info, infos map[string]Info) !string {
	t := info.table
	n := info.node()
	q := info.query()
	key := info.key_type()!
	key_field := info.key_field()!
	mut b := strings.new_builder(16384)
	b.writeln(header)
	b.writeln('module ${out_module}\n')
	mut imports := ['orm', 'five07.vgraph', 'five07.vgraph.load']
	if t.columns.any(it.typ.trim_left('?') == 'time.Time') {
		imports << 'time'
	}
	for line in imports {
		b.writeln('import ${line}')
	}

	// the typed mutation
	mt := info.mutation()
	b.writeln('
// ${mt} is a write to `${t.name}` before it runs, with a typed getter for each
// column. It implements `vgraph.Mutation`.
pub struct ${mt} {
pub mut:
	data vgraph.MutationData
}

// operation returns what the write does.
pub fn (m ${mt}) operation() vgraph.Op {
	return m.data.operation()
}

// table_name returns the table the write is to.
pub fn (m ${mt}) table_name() string {
	return m.data.table_name()
}

// changed_columns returns the columns the write sets, null included.
pub fn (m ${mt}) changed_columns() []string {
	return m.data.changed_columns()
}

// field_value returns the value the write sets `column` to, or `none`.
pub fn (m ${mt}) field_value(column string) ?orm.Primitive {
	return m.data.field_value(column)
}

// added_ids returns the keys the write adds to `edge`.
pub fn (m ${mt}) added_ids(edge string) []string {
	return m.data.added_ids(edge)
}

// removed_ids returns the keys the write removes from `edge`.
pub fn (m ${mt}) removed_ids(edge string) []string {
	return m.data.removed_ids(edge)
}

// edge_cleared reports whether the write removes every target of `edge`.
pub fn (m ${mt}) edge_cleared(edge string) bool {
	return m.data.edge_cleared(edge)
}

// set_field_value makes the write set `column` to `value`.
pub fn (mut m ${mt}) set_field_value(column string, value orm.Primitive) {
	m.data.set_field_value(column, value)
}

// clear_field_value makes the write set `column` to null.
pub fn (mut m ${mt}) clear_field_value(column string) {
	m.data.clear_field_value(column)
}')
	for c in t.columns {
		base := c.typ.trim_left('?')
		if base !in ['int', 'i64', 'f64', 'bool', 'string', 'time.Time'] {
			continue
		}
		if c.field in reserved_getters {
			return error('`${t.name}.${c.field}`: `${mt}.${c.field}` is taken; rename the field')
		}
		b.writeln('
// ${c.field} returns the value the write sets `${c.name}` to, or `none` when it
// doesn\'t set it, or sets it to null.
pub fn (m ${mt}) ${c.field}() ?${base} {
	value := m.data.values[\'${c.name}\'] or { return none }
	return if value is ${base} { value } else { none }
}')
	}

	// create
	cr := info.create()
	crb := info.create_bulk()
	b.writeln('
// ${cr} builds the insert of one `${t.name}` row, and of its edges. Start one
// with `Graph.${t.name}().create()`.
pub struct ${cr} {
	graph Graph
pub:
	data vgraph.MutationData
}

// create starts the insert of one row. The query\'s conditions don\'t apply.
pub fn (q ${q}) create() ${cr} {
	return ${cr}{
		graph: q.graph
		data:  vgraph.MutationData{
			op:    .create
			table: \'${t.name}\'
		}
	}
}')
	write_setters(mut b, cr, setters_of(info, infos, true)!)
	write_conflict(mut b, cr)
	b.writeln('
// save inserts the row and its edges, in one transaction, and returns it, read
// back. With `do_nothing`, a row that conflicts returns a `NotFoundError`.
pub fn (b ${cr}) save() !${n} {
	key := b.graph.client.create(b.data)!
	if key == \'\' {
		return NotFoundError{
			table: \'${t.name}\'
		}
	}
	return b.graph.${t.name}_by_keys([key])![0]
}

// exec inserts the row and its edges, in one transaction.
pub fn (b ${cr}) exec() ! {
	b.graph.client.create(b.data)!
}

// ${crb} builds the insert of several `${t.name}` rows. Start one with
// `Graph.${t.name}().create_bulk()`.
pub struct ${crb} {
	graph Graph
pub:
	builders []${cr}
}

// create_bulk starts the insert of the rows `builders` describe.
pub fn (q ${q}) create_bulk(builders ...${cr}) ${crb} {
	return ${crb}{
		graph:    q.graph
		builders: builders
	}
}

// map_create_bulk starts the insert of one row for each of `items`, which
// `configure` describes.
pub fn (q ${q}) map_create_bulk[T](items []T, configure fn (${cr}, T) ${cr}) ${crb} {
	return q.create_bulk(...items.map(configure(q.create(), it)))
}')
	write_conflict(mut b, crb)
	b.writeln('
// save inserts the rows and their edges, in one transaction, and returns them,
// read back, in order. With `do_nothing`, the rows that conflict are left out.
pub fn (b ${crb}) save() ![]${n} {
	keys := b.graph.client.create_bulk(b.builders.map(it.data))!
	return b.graph.${t.name}_by_keys(keys.filter(it != \'\'))
}

// exec inserts the rows and their edges, in one transaction.
pub fn (b ${crb}) exec() ! {
	b.graph.client.create_bulk(b.builders.map(it.data))!
}')

	// update one
	uo := info.update_one()
	b.writeln('
// ${uo} builds the update of one `${t.name}` row, and of its edges. Start one
// with `Graph.${t.name}().update_one(node)`, `update_one_id(id)` or
// `node.update()`.
pub struct ${uo} {
	graph Graph
pub:
	data vgraph.MutationData
}

// update_one starts the update of the row of `node`.
pub fn (q ${q}) update_one(node ${n}) ${uo} {
	return q.update_one_id(node.${info.field()}.${key_field})
}

// update_one_id starts the update of the row with the key `id`.
pub fn (q ${q}) update_one_id(id ${key}) ${uo} {
	return ${uo}{
		graph: q.graph
		data:  vgraph.MutationData{
			op:    .update_one
			table: \'${t.name}\'
			key:   id.str()
		}
	}
}

// update starts the update of this row.
pub fn (n ${n}) update() ${uo} {
	return n.graph.${t.name}().update_one(n)
}')
	update_setters := setters_of(info, infos, false)!
	write_setters(mut b, uo, update_setters)
	b.writeln('
// save updates the row and its edges, in one transaction, and returns it, read
// back, or a `NotFoundError`.
pub fn (b ${uo}) save() !${n} {
	b.exec()!
	return b.graph.${t.name}_by_keys([b.data.key])![0]
}

// exec updates the row and its edges, in one transaction, or returns a
// `NotFoundError`.
pub fn (b ${uo}) exec() ! {
	if !b.graph.client.update_one(b.data)! {
		return NotFoundError{
			table: \'${t.name}\'
		}
	}
}')

	// update
	up := info.update()
	b.writeln('
// ${up} builds the update of the `${t.name}` rows that match its conditions,
// and of their edges. Start one with `Graph.${t.name}().update()`.
pub struct ${up} {
	graph Graph
pub:
	data vgraph.MutationData
}

// update starts the update of the rows that match the query\'s conditions; its
// order, limit and offset don\'t apply.
pub fn (q ${q}) update() ${up} {
	return ${up}{
		graph: q.graph
		data:  vgraph.MutationData{
			op:    .update
			table: \'${t.name}\'
			conds: q.query.conds.clone()
		}
	}
}

// where keeps the rows that match every one of `conds`.
pub fn (b ${up}) where(conds ...load.Cond) ${up} {
	return ${up}{
		...b
		data: b.data.with_conds(conds)
	}
}')
	write_predicates(mut b, t, up, false)
	write_setters(mut b, up, update_setters)
	b.writeln('
// exec updates the rows and their edges, in one transaction, and returns how
// many there were.
pub fn (b ${up}) exec() !int {
	return b.graph.client.update(b.data)
}')

	// delete one, delete
	do := info.delete_one()
	de := info.delete()
	b.writeln('
// ${do} builds the delete of one `${t.name}` row. Start one with
// `Graph.${t.name}().delete_one(node)` or `delete_one_id(id)`.
pub struct ${do} {
	graph Graph
pub:
	data vgraph.MutationData
}

// delete_one starts the delete of the row of `node`.
pub fn (q ${q}) delete_one(node ${n}) ${do} {
	return q.delete_one_id(node.${info.field()}.${key_field})
}

// delete_one_id starts the delete of the row with the key `id`.
pub fn (q ${q}) delete_one_id(id ${key}) ${do} {
	return ${do}{
		graph: q.graph
		data:  vgraph.MutationData{
			op:    .delete_one
			table: \'${t.name}\'
			key:   id.str()
		}
	}
}

// exec deletes the row, with its join table rows, in one transaction, or
// returns a `NotFoundError`.
pub fn (b ${do}) exec() ! {
	if !b.graph.client.delete_one(b.data)! {
		return NotFoundError{
			table: \'${t.name}\'
		}
	}
}

// ${de} builds the delete of the `${t.name}` rows that match its conditions.
// Start one with `Graph.${t.name}().delete()`.
pub struct ${de} {
	graph Graph
pub:
	data vgraph.MutationData
}

// delete starts the delete of the rows that match the query\'s conditions; its
// order, limit and offset don\'t apply.
pub fn (q ${q}) delete() ${de} {
	return ${de}{
		graph: q.graph
		data:  vgraph.MutationData{
			op:    .delete
			table: \'${t.name}\'
			conds: q.query.conds.clone()
		}
	}
}

// where keeps the rows that match every one of `conds`.
pub fn (b ${de}) where(conds ...load.Cond) ${de} {
	return ${de}{
		...b
		data: b.data.with_conds(conds)
	}
}')
	write_predicates(mut b, t, de, false)
	b.writeln('
// exec deletes the rows, with their join table rows, in one transaction, and
// returns how many there were.
pub fn (b ${de}) exec() !int {
	return b.graph.client.delete(b.data)
}

// ${t.name}_by_keys returns the rows with the keys `keys`, in their order.
fn (g Graph) ${t.name}_by_keys(keys []string) ![]${n} {
	rows := g.${t.name}().where(load.in_keys(\'${t.key}\', keys, .${key})).all()!
	mut by_key := map[string]${n}{}
	for row in rows {
		by_key[row.${info.field()}.${key_field}.str()] = row
	}
	mut found := []${n}{cap: keys.len}
	for key in keys {
		found << by_key[key] or {
			return NotFoundError{
				table: \'${t.name}\'
			}
		}
	}
	return found
}')
	return b.str()
}

// write_conflict writes the upsert methods of a create builder, or of a bulk
// one, which applies them to each of its builders.
fn write_conflict(mut b strings.Builder, typ string) {
	bulk := typ.ends_with('Bulk')
	for name, doc in {
		'update_new_values': 'the stored row takes the values of the create, but for immutable ones'
		'ignore':            'the stored row stays as it is, and `save` returns it'
		'do_nothing':        'the stored row stays as it is, and `save` leaves it out'
	} {
		action := name
		if bulk {
			b.writeln('
// ${name} sets what a conflict on `on_conflict_columns` does: ${doc}.
// It needs a vgraph driver.
pub fn (b ${typ}) ${name}() ${typ} {
	return ${typ}{
		...b
		builders: b.builders.map(it.${name}())
	}
}')
		} else {
			b.writeln('
// ${name} sets what a conflict on `on_conflict_columns` does: ${doc}.
// It needs a vgraph driver.
pub fn (b ${typ}) ${name}() ${typ} {
	return ${typ}{
		...b
		data: b.data.with_conflict([], .${action})
	}
}')
		}
	}
	if bulk {
		b.writeln('
// on_conflict_columns makes each create an upsert, when a row conflicts with a
// stored one on `columns`, which a unique index or the key must cover.
pub fn (b ${typ}) on_conflict_columns(columns ...string) ${typ} {
	return ${typ}{
		...b
		builders: b.builders.map(it.on_conflict_columns(...columns))
	}
}')
	} else {
		b.writeln('
// on_conflict_columns makes the create an upsert, when its row conflicts with
// a stored one on `columns`, which a unique index or the key must cover.
// Unless another method says otherwise, a conflict still fails.
pub fn (b ${typ}) on_conflict_columns(columns ...string) ${typ} {
	return ${typ}{
		...b
		data: b.data.with_conflict(columns, b.data.on_conflict)
	}
}')
	}
}
