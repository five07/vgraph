module load

import orm

// Statements holds what a CountingConnection has run.
@[heap]
pub struct Statements {
pub mut:
	selects []string // the table of each select, in order
}

// CountingConnection wraps an orm.Connection and records each select it runs, so
// tests can assert how many queries a load makes.
pub struct CountingConnection {
pub mut:
	inner orm.Connection
	log   &Statements = &Statements{}
}

pub fn (mut c CountingConnection) select(config orm.SelectConfig, data orm.QueryData, where orm.QueryData) ![][]orm.Primitive {
	c.log.selects << config.table.name
	return c.inner.select(config, data, where)
}

pub fn (mut c CountingConnection) insert(table orm.Table, data orm.QueryData) ! {
	c.inner.insert(table, data)!
}

pub fn (mut c CountingConnection) update(table orm.Table, data orm.QueryData, where orm.QueryData) ! {
	c.inner.update(table, data, where)!
}

pub fn (mut c CountingConnection) delete(table orm.Table, where orm.QueryData) ! {
	c.inner.delete(table, where)!
}

pub fn (mut c CountingConnection) create(table orm.Table, fields []orm.TableField) ! {
	c.inner.create(table, fields)!
}

pub fn (mut c CountingConnection) drop(table orm.Table) ! {
	c.inner.drop(table)!
}

pub fn (mut c CountingConnection) last_id() int {
	return c.inner.last_id()
}

pub fn (mut c CountingConnection) execute(query string) ![]orm.Row {
	return c.inner.execute(query)
}
