module vgraph

import load
import orm

// Op is what a mutation does.
pub enum Op {
	create
	update_one
	update
	delete_one
	delete
}

// OnConflict is what a create does when its row conflicts with one stored
// (an upsert), on the columns its builder's `on_conflict_columns` names.
pub enum OnConflict {
	fail              // the create fails: no upsert
	update_new_values // the stored row takes the create's values, but for immutable ones
	ignore            // the stored row stays, and its key is returned
	do_nothing        // the stored row stays, and no key is returned
}

// Mutation is a write before it runs, as hooks see it: the columns it sets,
// and the edges it changes. Columns are named as in the database, and keys
// are in their string form. `MutationData` implements it, and so does each
// generated mutation, which embeds one.
pub interface Mutation {
	operation() Op
	table_name() string
	// changed_columns returns the columns the write sets, null included.
	changed_columns() []string
	// field_value returns the value the write sets `column` to, or `none`.
	field_value(column string) ?orm.Primitive
	added_ids(edge string) []string
	removed_ids(edge string) []string
	edge_cleared(edge string) bool
	// key returns the key of the row a `*_one` write is to, or of the row a
	// create stored, once the create has run; else ''.
	key() string
	// keys returns the keys of the rows the write reaches, read in its
	// transaction; a create has its key once it has run.
	keys() ![]string
	// old_field returns the stored value of `column`, `orm.Null{}` for null,
	// before an update_one or delete_one: one select of the row, kept for the
	// next call.
mut:
	old_field(column string) !orm.Primitive
	set_field_value(column string, value orm.Primitive)
	clear_field_value(column string)
	add_ids(edge string, ids ...string)
	remove_ids(edge string, ids ...string)
	clear_edge(edge string)
	// where narrows the rows an update or delete reaches.
	where(conds ...load.Cond)
	// set_op changes what the write does, such as a delete into an update.
	set_op(op Op)
	// on_commit runs `f` once the write's transaction commits, or once the
	// write succeeds when it has no transaction.
	on_commit(f fn ())
	// on_rollback runs `f` if the write's transaction rolls back, or the write
	// fails when it has no transaction.
	on_rollback(f fn ())
}

// MutationData is a write: what the generated builders collect, and what
// `Client.create`, `update` and `delete` run. Builders copy it on each change
// (`clone`), so a builder can be reused.
pub struct MutationData {
pub mut:
	op     Op
	table  string
	values map[string]orm.Primitive // by column; `orm.Null{}` sets null
	adds   map[string]orm.Primitive // update: added to the column's value
	// edges: keys added and removed, by edge name, and edges cleared
	added   map[string][]string
	removed map[string][]string
	cleared []string
	// update and delete: the rows; update_one and delete_one: the row's key
	conds   []load.Cond
	row_key string
	// create: the upsert
	conflict_columns []string
	on_conflict      OnConflict
mut:
	// set when the write runs: its client, in its transaction
	client   ?Client
	old      ?map[string]orm.Primitive
	affected int
}

// operation returns what the write does.
pub fn (m MutationData) operation() Op {
	return m.op
}

// table_name returns the table the write is to.
pub fn (m MutationData) table_name() string {
	return m.table
}

// changed_columns returns the columns the write sets, null included.
pub fn (m MutationData) changed_columns() []string {
	return m.values.keys()
}

// field_value returns the value the write sets `column` to, or `none`.
pub fn (m MutationData) field_value(column string) ?orm.Primitive {
	return m.values[column] or { return none }
}

// added_ids returns the keys the write adds to `edge`.
pub fn (m MutationData) added_ids(edge string) []string {
	return m.added[edge] or { [] }
}

// removed_ids returns the keys the write removes from `edge`.
pub fn (m MutationData) removed_ids(edge string) []string {
	return m.removed[edge] or { [] }
}

// edge_cleared reports whether the write removes every target of `edge`.
pub fn (m MutationData) edge_cleared(edge string) bool {
	return edge in m.cleared
}

// set_field_value makes the write set `column` to `value`.
pub fn (mut m MutationData) set_field_value(column string, value orm.Primitive) {
	m.values[column] = value
}

// clear_field_value makes the write set `column` to null.
pub fn (mut m MutationData) clear_field_value(column string) {
	m.values[column] = orm.Null{}
}

// key returns the key of the row a `*_one` write is to, or of the row a create
// stored, once it has run.
pub fn (m MutationData) key() string {
	return m.row_key
}

// keys returns the keys of the rows the write reaches, read in its
// transaction.
pub fn (m MutationData) keys() ![]string {
	if m.op in [.create, .update_one, .delete_one] {
		return if m.row_key == '' { []string{} } else { [m.row_key] }
	}
	c := m.client or { return error("`${m.table}`: the write isn't running") }
	return c.select_keys(c.schema.table(m.table)!, m.conds)
}

// old_field returns the stored value of `column`, `orm.Null{}` for null, of the
// row an update_one or delete_one is to: one select of the row, kept for the
// next call.
pub fn (mut m MutationData) old_field(column string) !orm.Primitive {
	if m.op !in [.update_one, .delete_one] {
		return error('`${m.table}`: old values are only read for update_one and delete_one, not ${m.op}')
	}
	if old := m.old {
		return old[column] or { return error('`${m.table}` has no column `${column}`') }
	}
	c := m.client or { return error("`${m.table}`: the write isn't running") }
	t := c.schema.table(m.table)!
	row := c.select_row(t, m.row_key)!
	m.old = row
	return row[column] or { return error('`${m.table}` has no column `${column}`') }
}

// add_ids adds the targets with the keys `ids` to `edge`.
pub fn (mut m MutationData) add_ids(edge string, ids ...string) {
	mut list := m.added[edge] or { []string{} }
	list << ids
	m.added[edge] = list
}

// remove_ids removes the targets with the keys `ids` from `edge`.
pub fn (mut m MutationData) remove_ids(edge string, ids ...string) {
	mut list := m.removed[edge] or { []string{} }
	list << ids
	m.removed[edge] = list
}

// clear_edge removes every target of `edge`, before any are added.
pub fn (mut m MutationData) clear_edge(edge string) {
	if edge !in m.cleared {
		m.cleared << edge
	}
}

// where narrows the rows an update or delete reaches.
pub fn (mut m MutationData) where(conds ...load.Cond) {
	m.conds << conds
}

// set_op changes what the write does, such as a delete into an update.
pub fn (mut m MutationData) set_op(op Op) {
	m.op = op
}

// on_commit runs `f` once the write's transaction commits.
pub fn (mut m MutationData) on_commit(f fn ()) {
	if c := m.client {
		c.on_commit(f)
	}
}

// on_rollback runs `f` if the write's transaction rolls back.
pub fn (mut m MutationData) on_rollback(f fn ()) {
	if c := m.client {
		c.on_rollback(f)
	}
}

// clone returns a copy of `m` that shares nothing with it.
pub fn (m MutationData) clone() MutationData {
	mut added := map[string][]string{}
	for edge, ids in m.added {
		added[edge] = ids.clone()
	}
	mut removed := map[string][]string{}
	for edge, ids in m.removed {
		removed[edge] = ids.clone()
	}
	return MutationData{
		...m
		values:           m.values.clone()
		adds:             m.adds.clone()
		added:            added
		removed:          removed
		cleared:          m.cleared.clone()
		conds:            m.conds.clone()
		conflict_columns: m.conflict_columns.clone()
	}
}

// with_value returns a copy of `m` that sets `column` to `value`.
pub fn (m MutationData) with_value(column string, value orm.Primitive) MutationData {
	mut next := m.clone()
	next.values[column] = value
	return next
}

// with_add returns a copy of `m` that adds `delta` to `column`.
pub fn (m MutationData) with_add(column string, delta orm.Primitive) MutationData {
	mut next := m.clone()
	next.adds[column] = delta
	return next
}

// with_added returns a copy of `m` that adds the targets with the keys `ids` to
// `edge`.
pub fn (m MutationData) with_added(edge string, ids []string) MutationData {
	mut next := m.clone()
	mut list := next.added[edge] or { []string{} }
	list << ids
	next.added[edge] = list
	return next
}

// with_removed returns a copy of `m` that removes the targets with the keys
// `ids` from `edge`.
pub fn (m MutationData) with_removed(edge string, ids []string) MutationData {
	mut next := m.clone()
	mut list := next.removed[edge] or { []string{} }
	list << ids
	next.removed[edge] = list
	return next
}

// with_cleared returns a copy of `m` that removes every target of `edge`,
// before it adds any.
pub fn (m MutationData) with_cleared(edge string) MutationData {
	mut next := m.clone()
	if edge !in next.cleared {
		next.cleared << edge
	}
	return next
}

// with_conds returns a copy of `m` that also needs `conds` of its rows.
pub fn (m MutationData) with_conds(conds []load.Cond) MutationData {
	mut next := m.clone()
	next.conds << conds
	return next
}

// with_conflict returns a copy of `m` that upserts on `columns`.
pub fn (m MutationData) with_conflict(columns []string, action OnConflict) MutationData {
	mut next := m.clone()
	if columns.len > 0 {
		next.conflict_columns = columns.clone()
	}
	next.on_conflict = action
	return next
}
