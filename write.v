module vgraph

import load
import orm
import time

// Writes. The generated builders collect a `MutationData` and run it here. A
// write and its edge writes run in one transaction when the connection can run
// one (`Client.begin`); inside a transaction already, they join it.

type Row = map[string]orm.Primitive

// create inserts the row `m` describes, with its edges, and returns its key in
// its string form, or '' when the row conflicted and `m` says `do_nothing`.
pub fn (c Client) create(m MutationData) !string {
	return c.create_bulk([m])![0]
}

// create_bulk inserts the rows `ms` describe, all of one table, with their
// edges, in one transaction, and returns their keys in order, '' for a row
// left out by `do_nothing`. With a PostgreSQL driver, rows that set the same
// columns go in one statement.
pub fn (c Client) create_bulk(ms []MutationData) ![]string {
	if ms.len == 0 {
		return []string{}
	}
	t := c.schema.table(ms[0].table)!
	options := c.schema.options(t.name)
	mut rows := []Row{cap: ms.len}
	for m in ms {
		if m.table != t.name {
			return error('create_bulk: `${m.table}` and `${t.name}` rows are mixed')
		}
		rows << prepare_create(t, options, m)!
	}
	tc := c.atomic()!
	keys := tc.create_rows(t, rows, ms) or {
		tc.rollback() or {}
		return err
	}
	tc.commit()!
	return keys
}

fn (c Client) create_rows(t Table, rows []Row, ms []MutationData) ![]string {
	keys := c.insert_rows(t, rows, ms[0])!
	for i, m in ms {
		if keys[i] != '' {
			c.write_edges(t, keys[i], m)!
		}
	}
	return keys
}

// update_one updates the row whose key is `m.key`, with its edges, and
// reports whether there was one.
pub fn (c Client) update_one(m MutationData) !bool {
	t := c.schema.table(m.table)!
	return c.update(MutationData{
		...m
		conds: [load.in_keys(t.key, [m.key], key_type(t)!)]
	})! > 0
}

// update updates the rows that match `m.conds`, with their edges, and returns
// how many there were. It reads their keys first, in the same transaction.
pub fn (c Client) update(m MutationData) !int {
	t := c.schema.table(m.table)!
	set := prepare_update(t, c.schema.options(t.name), m)!
	tc := c.atomic()!
	count := tc.update_rows(t, set, m) or {
		tc.rollback() or {}
		return err
	}
	tc.commit()!
	return count
}

fn (c Client) update_rows(t Table, set Row, m MutationData) !int {
	keys := c.select_keys(t, m.conds)!
	if keys.len == 0 {
		return 0
	}
	if set.len > 0 {
		where := load.where_data([load.in_keys(t.key, keys, key_type(t)!)]) or { return 0 }
		mut conn := c.conn
		conn.update(orm.Table{ name: t.name }, query_data(set), where)!
	}
	for key in keys {
		c.write_edges(t, key, m)!
	}
	return keys.len
}

// delete_one deletes the row whose key is `m.key`, and reports whether there
// was one.
pub fn (c Client) delete_one(m MutationData) !bool {
	t := c.schema.table(m.table)!
	return c.delete(MutationData{
		...m
		conds: [load.in_keys(t.key, [m.key], key_type(t)!)]
	})! > 0
}

// delete deletes the rows that match `m.conds`, and returns how many there
// were. The join table rows of the table's many_to_many edges go with them;
// rows of other tables that hold their keys stay.
pub fn (c Client) delete(m MutationData) !int {
	t := c.schema.table(m.table)!
	tc := c.atomic()!
	count := tc.delete_rows(t, m) or {
		tc.rollback() or {}
		return err
	}
	tc.commit()!
	return count
}

fn (c Client) delete_rows(t Table, m MutationData) !int {
	keys := c.select_keys(t, m.conds)!
	if keys.len == 0 {
		return 0
	}
	typ := key_type(t)!
	mut conn := c.conn
	for e in t.edges {
		if e.kind == .many_to_many {
			where := load.where_data([load.in_keys(e.column, keys, typ)]) or { continue }
			conn.delete(orm.Table{ name: e.through }, where)!
		}
	}
	where := load.where_data([load.in_keys(t.key, keys, typ)]) or { return 0 }
	conn.delete(orm.Table{ name: t.name }, where)!
	return keys.len
}

// prepare_create returns the row `m` inserts: its values, then the defaults of
// the columns it leaves unset. It reports a required column left unset, and
// runs every check.
fn prepare_create(t Table, options map[string]Field, m MutationData) !Row {
	if m.adds.len > 0 {
		return error("`${t.name}`: a create can't add to a column")
	}
	mut row := Row{}
	for name, value in m.values {
		t.column(name) or { return error('`${t.name}` has no column `${name}`') }
		row[name] = value
	}
	for column in t.columns {
		if column.name in row {
			continue
		}
		o := options[column.field] or {
			Field{
				name: column.field
			}
		}
		if default := o.default {
			row[column.name] = default()
		} else if o.default_now {
			row[column.name] = now()
		} else if !column.optional {
			return ValidationError{
				table:   t.name
				field:   column.name
				message: 'is required'
			}
		}
	}
	check_values(t, options, row)!
	return row
}

// prepare_update returns the columns `m` sets on each row: its values, its
// additions, then the update defaults of the columns it leaves unset. It
// reports a column that may not change, and runs every check.
fn prepare_update(t Table, options map[string]Field, m MutationData) !Row {
	mut set := Row{}
	for name, value in m.values {
		column := t.column(name) or { return error('`${t.name}` has no column `${name}`') }
		if name == t.key {
			return ValidationError{
				table:   t.name
				field:   name
				message: "is the key, which can't change"
			}
		}
		if column.immutable {
			return ValidationError{
				table:   t.name
				field:   name
				message: 'is immutable'
			}
		}
		set[name] = value
	}
	check_values(t, options, set)!
	for name, delta in m.adds {
		column := t.column(name) or { return error('`${t.name}` has no column `${name}`') }
		if name in set {
			return error('`${t.name}.${name}` is both set and added to')
		}
		if column.typ.trim_left('?') !in ['int', 'i64', 'f64'] || column.immutable
			|| name == t.key {
			return ValidationError{
				table:   t.name
				field:   name
				message: "can't be added to"
			}
		}
		set[name] = orm.InfixType{
			name:     name
			operator: .add
			right:    delta
		}
	}
	for column in t.columns {
		if column.name in set {
			continue
		}
		o := options[column.field] or { continue }
		if default := o.update_default {
			set[column.name] = default()
		} else if o.update_now {
			set[column.name] = now()
		}
	}
	return set
}

// check_values checks each value of `row` against its column's type and
// options.
fn check_values(t Table, options map[string]Field, row Row) ! {
	for name, value in row {
		column := t.column(name) or { return error('`${t.name}` has no column `${name}`') }
		if value is orm.Null {
			if !column.nullable {
				return ValidationError{
					table:   t.name
					field:   name
					message: "can't be null"
				}
			}
			continue
		}
		if !fits(column, value) {
			return ValidationError{
				table:   t.name
				field:   name
				message: 'is ${column.typ.trim_left('?')}, not ${value.type_name()}'
			}
		}
		if o := options[column.field] {
			o.check(t.name, name, value)!
		}
	}
}

// fits reports whether `value` has the type of `column`.
fn fits(column Column, value orm.Primitive) bool {
	return match column.typ.trim_left('?') {
		'int' { value is int }
		'i64' { value is i64 || value is int }
		'f64' { value is f64 }
		'bool' { value is bool }
		'string' { value is string }
		'time.Time' { value is time.Time }
		else { true }
	}
}

// insert_rows inserts `rows` and returns their keys. A driver returns them
// (`RETURNING`); without one, a key is the one the row sets, or `last_id()`.
fn (c Client) insert_rows(t Table, rows []Row, m MutationData) ![]string {
	if c.conn is Driver {
		mut d := c.conn as Driver
		// PostgreSQL returns a multi-row insert's rows in order; SQLite doesn't
		// promise to, and a row left out by `do_nothing` returns nothing
		if d.dialect() == .pg && m.on_conflict != .do_nothing && same_columns(rows) {
			return insert_returning(mut d, t, rows, m)
		}
		mut keys := []string{cap: rows.len}
		for row in rows {
			returned := insert_returning(mut d, t, [row], m)!
			keys << if returned.len > 0 { returned[0] } else { '' }
		}
		return keys
	}
	if m.conflict_columns.len > 0 {
		return error('`${t.name}`: an upsert needs a vgraph driver (five07.vgraph.sqlite or five07.vgraph.pg)')
	}
	key := t.column(t.key) or { return error('`${t.name}` has no key column `${t.key}`') }
	mut conn := c.conn
	mut keys := []string{cap: rows.len}
	for row in rows {
		conn.insert(orm.Table{ name: t.name }, query_data(row))!
		if value := row[t.key] {
			keys << key_text(value)
		} else if key.kind in [.int, .i64] {
			keys << conn.last_id().str()
		} else {
			return error('`${t.name}`: a create must set the key `${t.key}`')
		}
	}
	return keys
}

fn same_columns(rows []Row) bool {
	first := rows[0].keys()
	return first.len > 0 && rows.all(it.keys() == first)
}

// insert_returning inserts `rows`, which set the same columns, in one
// statement, and returns the keys it reports.
fn insert_returning(mut d Driver, t Table, rows []Row, m MutationData) ![]string {
	columns := rows[0].keys()
	mut p := Params{
		dialect: d.dialect()
	}
	mut sql := 'INSERT INTO ${quote(t.name)}'
	if columns.len == 0 {
		sql += ' DEFAULT VALUES'
	} else {
		mut tuples := []string{cap: rows.len}
		for row in rows {
			mut cells := []string{cap: columns.len}
			for name in columns {
				cells << p.add(row[name] or { orm.Null{} })!
			}
			tuples << '(${cells.join(', ')})'
		}
		sql += ' (${columns.map(quote(it)).join(', ')}) VALUES ${tuples.join(', ')}'
	}
	sql += conflict_clause(t, columns, m)!
	sql += ' RETURNING ${quote(t.key)}'
	result := d.exec_params(sql, p.values)!
	return result.map(if it.len > 0 { it[0] or { '' } } else { '' })
}

// conflict_clause returns the `ON CONFLICT` clause of an upsert, or ''.
fn conflict_clause(t Table, columns []string, m MutationData) !string {
	if m.conflict_columns.len == 0 {
		if m.on_conflict != .fail {
			return error('`${t.name}`: an upsert needs `on_conflict_columns`')
		}
		return ''
	}
	for name in m.conflict_columns {
		t.column(name) or { return error('`${t.name}` has no column `${name}`') }
	}
	target := ' ON CONFLICT (${m.conflict_columns.map(quote(it)).join(', ')})'
	keep := m.conflict_columns[0]
	ignore := '${target} DO UPDATE SET ${quote(keep)} = ${quote(t.name)}.${quote(keep)}'
	return match m.on_conflict {
		.fail {
			target
		}
		.do_nothing {
			'${target} DO NOTHING'
		}
		.ignore {
			ignore
		}
		.update_new_values {
			mut changed := []string{}
			for name in columns {
				column := t.column(name) or { continue }
				if name != t.key && name !in m.conflict_columns && !column.immutable {
					changed << '${quote(name)} = excluded.${quote(name)}'
				}
			}
			if changed.len == 0 { ignore } else { '${target} DO UPDATE SET ${changed.join(', ')}' }
		}
	}
}

// write_edges writes the edge changes of `m` for the row with the key `key`:
// clears, then removals, then additions.
fn (c Client) write_edges(t Table, key string, m MutationData) ! {
	mut conn := c.conn
	typ := key_type(t)!
	for name in m.cleared {
		e := c.schema.edge(t.name, name)!
		match e.kind {
			.one_to_many, .one_to_one {
				target := c.schema.table(e.to)!
				mut conds := [load.in_keys(e.column, [key], typ)]
				conds << type_conds(e)
				c.set_null(target, e, conds)!
			}
			.many_to_many {
				if where := load.where_data([load.in_keys(e.column, [key], typ)]) {
					conn.delete(orm.Table{ name: e.through }, where)!
				}
			}
			.many_to_one {
				c.set_null(t, e, [load.in_keys(t.key, [key], typ)])!
			}
		}
	}
	for name, ids in m.removed {
		if ids.len == 0 {
			continue
		}
		e := c.schema.edge(t.name, name)!
		target := c.schema.table(e.to)!
		match e.kind {
			.one_to_many, .one_to_one {
				mut conds := [load.in_keys(target.key, ids, key_type(target)!),
					load.in_keys(e.column, [key], typ)]
				conds << type_conds(e)
				c.set_null(target, e, conds)!
			}
			.many_to_many {
				if where := load.where_data([load.in_keys(e.column, [key], typ),
					load.in_keys(e.through_to, ids, key_type(target)!)])
				{
					conn.delete(orm.Table{ name: e.through }, where)!
				}
			}
			.many_to_one {
				return error('`${t.name}.${name}` is many_to_one: clear it, or set another')
			}
		}
	}
	for name, ids in m.added {
		if ids.len == 0 {
			continue
		}
		e := c.schema.edge(t.name, name)!
		target := c.schema.table(e.to)!
		target_typ := key_type(target)!
		match e.kind {
			.one_to_many, .one_to_one {
				if e.kind == .one_to_one && ids.len > 1 {
					return error('`${t.name}.${name}` is one_to_one: set one target, not ${ids.len}')
				}
				mut set := Row{}
				set[e.column] = key_value(key, typ)
				if e.type_col != '' {
					set[e.type_col] = e.type_val
				}
				if where := load.where_data([load.in_keys(target.key, ids, target_typ)]) {
					conn.update(orm.Table{ name: target.name }, query_data(set), where)!
				}
			}
			.many_to_many {
				mut data := orm.QueryData{
					fields:     [e.column, e.through_to]
					batch_rows: ids.len
				}
				for id in ids {
					data.data << key_value(key, typ)
					data.data << key_value(id, target_typ)
				}
				conn.insert(orm.Table{ name: e.through }, data)!
			}
			.many_to_one {
				if ids.len != 1 {
					return error('`${t.name}.${name}` is many_to_one: set one target, not ${ids.len}')
				}
				mut set := Row{}
				set[e.column] = key_value(ids[0], target_typ)
				if e.type_col != '' {
					set[e.type_col] = e.type_val
				}
				where := load.where_data([load.in_keys(t.key, [key], typ)]) or { continue }
				conn.update(orm.Table{ name: t.name }, query_data(set), where)!
			}
		}
	}
}

// set_null sets the column of the edge `e`, which `table` holds, to null on
// the rows that match `conds`.
fn (c Client) set_null(table Table, e Edge, conds []load.Cond) ! {
	column := table.column(e.column) or {
		return error('`${table.name}` has no column `${e.column}`')
	}
	if !column.nullable {
		return error("`${table.name}.${e.column}` is not nullable, so `${e.name}` can't lose a target; delete it, or point it elsewhere")
	}
	mut set := Row{}
	set[e.column] = orm.Null{}
	where := load.where_data(conds) or { return }
	mut conn := c.conn
	conn.update(orm.Table{ name: table.name }, query_data(set), where)!
}

// type_conds returns the condition on a polymorphic edge's type, if it has
// one.
fn type_conds(e Edge) []load.Cond {
	return if e.type_col != '' { [load.eq(e.type_col, e.type_val)] } else { [] }
}

// select_keys returns the keys of the rows of `t` that match `conds`, as
// strings, in one query.
fn (c Client) select_keys(t Table, conds []load.Cond) ![]string {
	where := load.where_data(conds) or { return []string{} }
	typ := match key_type(t)! {
		.int { orm.type_idx['int'] }
		.i64 { orm.type_idx['i64'] }
		.string { orm.type_string }
	}
	config := orm.SelectConfig{
		table:        orm.Table{
			name: t.name
		}
		has_where:    where.fields.len > 0
		primary:      t.key
		fields:       [t.key]
		select_exprs: [t.key]
		types:        [typ]
	}
	mut conn := c.conn
	rows := conn.select(config, orm.QueryData{}, where)!
	return rows.map(key_text(it[0]))
}

// query_data returns `row` as the ORM's data for an insert or update.
fn query_data(row Row) orm.QueryData {
	mut data := orm.QueryData{}
	for name, value in row {
		data.fields << name
		data.data << value
		data.types << load.value_type(value)
	}
	return data
}

// key_type returns the type of `t`'s key.
fn key_type(t Table) !load.KeyType {
	column := t.column(t.key) or { return error('`${t.name}` has no key column `${t.key}`') }
	return match column.kind {
		.int { load.KeyType.int }
		.i64 { load.KeyType.i64 }
		.string { load.KeyType.string }
		.other {
			error('the key `${t.name}.${t.key}` is ${column.typ}; keys are int, i64 or string')
		}
	}
}

// key_value returns the key `key`, in its string form, as a value of `typ`.
fn key_value(key string, typ load.KeyType) orm.Primitive {
	return match typ {
		.int { orm.Primitive(key.int()) }
		.i64 { orm.Primitive(key.i64()) }
		.string { orm.Primitive(key) }
	}
}

// key_text returns a key's string form.
fn key_text(value orm.Primitive) string {
	return match value {
		int { value.str() }
		i64 { value.str() }
		string { value }
		else { '' }
	}
}
