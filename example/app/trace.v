module app

import orm
import sync

// QueryLog holds the selects a `CountingConnection` has run, one entry each, such
// as `users where id IN`. It is shared by the threads that serve requests.
@[heap]
pub struct QueryLog {
mut:
	mu      &sync.Mutex = sync.new_mutex()
	selects []string
}

// selects returns the selects run since the last `clear`, in order.
pub fn (mut l QueryLog) selects() []string {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return l.selects.clone()
}

// clear forgets every select run so far.
pub fn (mut l QueryLog) clear() {
	l.mu.lock()
	l.selects.clear()
	l.mu.unlock()
}

fn (mut l QueryLog) add(entry string) {
	l.mu.lock()
	l.selects << entry
	l.mu.unlock()
}

// CountingConnection runs every query on `inner`, and records each select in
// `log`, so tests can check how many queries an endpoint makes.
pub struct CountingConnection {
pub mut:
	inner orm.Connection
	log   &QueryLog = &QueryLog{}
}

pub fn (mut c CountingConnection) select(config orm.SelectConfig, data orm.QueryData, where orm.QueryData) ![][]orm.Primitive {
	mut conditions := []string{}
	for i, field in where.fields {
		kind := if i < where.kinds.len { where.kinds[i].str() } else { '?' }
		conditions << '${field} ${kind}'
	}
	c.log.add('${config.table.name} where ${conditions.join(', ')}'.trim_string_right(' where '))
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
