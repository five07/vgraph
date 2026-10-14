// Package sqlite is vgraph's driver for SQLite: it wraps a `db.sqlite`
// connection, so vgraph's writes can run the SQL that `orm.Connection` can't
// express (`RETURNING`, upserts). Pass it where the connection would go:
// `graph.Graph.new(sqlite.new(db))`. Every ORM call goes to `db`.
module sqlite

import db.sqlite as sq
import orm
import sync

// Driver is a SQLite connection that vgraph can run its own SQL on. It
// implements `vgraph.Driver`, `vgraph.TxConnection` and
// `orm.TransactionalConnection`.
//
// SQLite has one transaction per connection, so threads that share a driver
// take turns: a transaction begun while another is open waits for it to end.
// Statements outside a transaction don't wait, and see what an open one has
// written.
@[heap]
pub struct Driver {
mut:
	db      sq.DB
	in_tx   bool
	tx_lock &sync.Mutex = sync.new_mutex()
}

// new returns a driver that runs on `db`.
pub fn new(db sq.DB) &Driver {
	return &Driver{
		db:      db
		tx_lock: sync.new_mutex()
	}
}

// db returns the connection the driver runs on.
pub fn (d &Driver) db() sq.DB {
	return d.db
}

// dialect reports the SQL the driver runs.
pub fn (d &Driver) dialect() orm.SQLDialect {
	return .sqlite
}

// exec_params runs `query`, binding `params` as text to its `?` placeholders.
// SQLite converts them to each column's type. A null cell is returned as ''.
pub fn (mut d Driver) exec_params(query string, params []string) ![][]?string {
	rows := d.db.exec_param_many(query, params) or { return without_sql(err) }
	return rows.map(it.vals.map(?string(it)))
}

// begin_tx starts a transaction on the same connection, and returns a driver
// that commits or rolls it back. SQLite has one transaction per connection.
pub fn (mut d Driver) begin_tx() !orm.Connection {
	d.tx_lock.lock()
	d.db.begin() or {
		d.tx_lock.unlock()
		return err
	}
	return &Driver{
		db:      d.db
		in_tx:   true
		tx_lock: d.tx_lock
	}
}

// commit_tx commits the transaction that `begin_tx` started.
pub fn (mut d Driver) commit_tx() ! {
	if !d.in_tx {
		return error('vgraph sqlite: no transaction to commit')
	}
	d.in_tx = false
	defer {
		d.tx_lock.unlock()
	}
	d.db.commit() or {
		// a commit that fails leaves nothing open
		d.db.rollback() or {}
		return err
	}
}

// rollback_tx rolls back the transaction that `begin_tx` started.
pub fn (mut d Driver) rollback_tx() ! {
	if !d.in_tx {
		return error('vgraph sqlite: no transaction to roll back')
	}
	d.in_tx = false
	defer {
		d.tx_lock.unlock()
	}
	d.db.rollback()!
}

// without_sql returns `err` without the statement that `db.sqlite` adds to
// its messages, which can hold values: SQLite's own message, and its code,
// reach the caller, and through GraphQL, the client.
fn without_sql(err IError) IError {
	code := err.code()
	marker := ' (${code}) ('
	msg := err.msg()
	if code != 0 && msg.contains(marker) {
		return error_with_code(msg.all_before(marker), code)
	}
	return err
}

// The ORM's calls, passed to `db`.

// select runs the ORM's select on the wrapped connection.
pub fn (mut d Driver) select(config orm.SelectConfig, data orm.QueryData, where orm.QueryData) ![][]orm.Primitive {
	return d.db.select(config, data, where) or { return without_sql(err) }
}

// insert runs the ORM's insert on the wrapped connection.
pub fn (mut d Driver) insert(table orm.Table, data orm.QueryData) ! {
	d.db.insert(table, data) or { return without_sql(err) }
}

// update runs the ORM's update on the wrapped connection.
pub fn (mut d Driver) update(table orm.Table, data orm.QueryData, where orm.QueryData) ! {
	d.db.update(table, data, where) or { return without_sql(err) }
}

// delete runs the ORM's delete on the wrapped connection.
pub fn (mut d Driver) delete(table orm.Table, where orm.QueryData) ! {
	d.db.delete(table, where) or { return without_sql(err) }
}

// create runs the ORM's create table on the wrapped connection.
pub fn (mut d Driver) create(table orm.Table, fields []orm.TableField) ! {
	d.db.create(table, fields)!
}

// drop runs the ORM's drop table on the wrapped connection.
pub fn (mut d Driver) drop(table orm.Table) ! {
	d.db.drop(table)!
}

// last_id returns the wrapped connection's last inserted id.
pub fn (mut d Driver) last_id() int {
	return d.db.last_id()
}

// execute runs `query`, without parameters, on the wrapped connection.
pub fn (mut d Driver) execute(query string) ![]orm.Row {
	return d.db.execute(query)
}

// orm_begin starts the ORM's transaction on the wrapped connection.
// Like `begin_tx`, it waits for another thread's transaction to end.
pub fn (mut d Driver) orm_begin() ! {
	d.tx_lock.lock()
	d.db.orm_begin() or {
		d.tx_lock.unlock()
		return err
	}
}

// orm_commit commits the ORM's transaction on the wrapped connection.
pub fn (mut d Driver) orm_commit() ! {
	d.db.orm_commit()!
	d.tx_lock.unlock()
}

// orm_rollback rolls back the ORM's transaction on the wrapped connection.
pub fn (mut d Driver) orm_rollback() ! {
	defer {
		d.tx_lock.unlock()
	}
	d.db.orm_rollback()!
}

// orm_savepoint sets a savepoint on the wrapped connection.
pub fn (mut d Driver) orm_savepoint(name string) ! {
	d.db.orm_savepoint(name)!
}

// orm_rollback_to rolls back to a savepoint on the wrapped connection.
pub fn (mut d Driver) orm_rollback_to(name string) ! {
	d.db.orm_rollback_to(name)!
}

// orm_release_savepoint releases a savepoint on the wrapped connection.
pub fn (mut d Driver) orm_release_savepoint(name string) ! {
	d.db.orm_release_savepoint(name)!
}
