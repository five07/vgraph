// Package pg is vgraph's driver for PostgreSQL: it wraps a `db.pg` pool,
// connection or transaction, so vgraph's writes can run the SQL that
// `orm.Connection` can't express (`RETURNING`, upserts). Pass it where the
// connection would go: `graph.Graph.new(pg.pool(db))`. Every ORM call goes to
// the wrapped value.
//
// vgraph's transactions run at PostgreSQL's default level, READ COMMITTED.
module pg

import db.pg as dbpg
import orm

const read_committed = dbpg.PQTransactionParam{
	transaction_level: .read_committed
}

// rows_text returns a result's rows, each cell as text or `none` for null.
fn rows_text(rows []dbpg.Row) [][]?string {
	return rows.map(it.vals)
}

// Pool is a PostgreSQL pool that vgraph can run its own SQL on. A
// transaction takes one connection from the pool until it ends.
@[heap]
pub struct Pool {
mut:
	db &dbpg.DB
}

// pool returns a driver that runs on the pool `db`, from `pg.connect`.
pub fn pool(db &dbpg.DB) &Pool {
	return &Pool{
		db: unsafe { db }
	}
}

// dialect reports the SQL the driver runs.
pub fn (p &Pool) dialect() orm.SQLDialect {
	return .pg
}

// exec_params runs `query` with `params` in place of its placeholders, and returns its rows as text.
pub fn (mut p Pool) exec_params(query string, params []string) ![][]?string {
	return rows_text(p.db.exec_param_many(query, params)!)
}

// begin_tx takes a connection from the pool, starts a transaction on it, and
// returns a driver for it.
pub fn (mut p Pool) begin_tx() !orm.Connection {
	return &Tx{
		tx: p.db.begin(read_committed)!
	}
}

// select runs the ORM's select on the wrapped connection.
pub fn (mut p Pool) select(config orm.SelectConfig, data orm.QueryData, where orm.QueryData) ![][]orm.Primitive {
	return p.db.select(config, data, where)
}

// insert runs the ORM's insert on the wrapped connection.
pub fn (mut p Pool) insert(table orm.Table, data orm.QueryData) ! {
	p.db.insert(table, data)!
}

// update runs the ORM's update on the wrapped connection.
pub fn (mut p Pool) update(table orm.Table, data orm.QueryData, where orm.QueryData) ! {
	p.db.update(table, data, where)!
}

// delete runs the ORM's delete on the wrapped connection.
pub fn (mut p Pool) delete(table orm.Table, where orm.QueryData) ! {
	p.db.delete(table, where)!
}

// create runs the ORM's create table on the wrapped connection.
pub fn (mut p Pool) create(table orm.Table, fields []orm.TableField) ! {
	p.db.create(table, fields)!
}

// drop runs the ORM's drop table on the wrapped connection.
pub fn (mut p Pool) drop(table orm.Table) ! {
	p.db.drop(table)!
}

// last_id returns the wrapped connection's last inserted id.
pub fn (mut p Pool) last_id() int {
	return p.db.last_id()
}

// execute runs `query`, without parameters, on the wrapped connection.
pub fn (mut p Pool) execute(query string) ![]orm.Row {
	return p.db.execute(query)
}

// Conn is a single PostgreSQL connection that vgraph can run its own SQL on,
// as `pg.connect_direct` returns, and as `v.migrations` needs.
@[heap]
pub struct Conn {
mut:
	conn  &dbpg.Conn
	in_tx bool
}

// direct returns a driver that runs on the connection `conn`.
pub fn direct(conn &dbpg.Conn) &Conn {
	return &Conn{
		conn: unsafe { conn }
	}
}

// dialect reports the SQL the driver runs.
pub fn (c &Conn) dialect() orm.SQLDialect {
	return .pg
}

// exec_params runs `query` with `params` in place of its placeholders, and returns its rows as text.
pub fn (mut c Conn) exec_params(query string, params []string) ![][]?string {
	return rows_text(c.conn.exec_param_many(query, params)!)
}

// begin_tx starts a transaction on the connection, and returns a driver that
// commits or rolls it back.
pub fn (mut c Conn) begin_tx() !orm.Connection {
	c.conn.begin_on_conn(read_committed)!
	return &Conn{
		conn:  c.conn
		in_tx: true
	}
}

// commit_tx commits the transaction that `begin_tx` started.
pub fn (mut c Conn) commit_tx() ! {
	if !c.in_tx {
		return error('vgraph pg: no transaction to commit')
	}
	c.conn.orm_commit()!
	c.in_tx = false
}

// rollback_tx rolls back the transaction that `begin_tx` started.
pub fn (mut c Conn) rollback_tx() ! {
	if !c.in_tx {
		return error('vgraph pg: no transaction to roll back')
	}
	c.conn.orm_rollback()!
	c.in_tx = false
}

// select runs the ORM's select on the wrapped connection.
pub fn (mut c Conn) select(config orm.SelectConfig, data orm.QueryData, where orm.QueryData) ![][]orm.Primitive {
	return c.conn.select(config, data, where)
}

// insert runs the ORM's insert on the wrapped connection.
pub fn (mut c Conn) insert(table orm.Table, data orm.QueryData) ! {
	c.conn.insert(table, data)!
}

// update runs the ORM's update on the wrapped connection.
pub fn (mut c Conn) update(table orm.Table, data orm.QueryData, where orm.QueryData) ! {
	c.conn.update(table, data, where)!
}

// delete runs the ORM's delete on the wrapped connection.
pub fn (mut c Conn) delete(table orm.Table, where orm.QueryData) ! {
	c.conn.delete(table, where)!
}

// create runs the ORM's create table on the wrapped connection.
pub fn (mut c Conn) create(table orm.Table, fields []orm.TableField) ! {
	c.conn.create(table, fields)!
}

// drop runs the ORM's drop table on the wrapped connection.
pub fn (mut c Conn) drop(table orm.Table) ! {
	c.conn.drop(table)!
}

// last_id returns the wrapped connection's last inserted id.
pub fn (mut c Conn) last_id() int {
	return c.conn.last_id()
}

// execute runs `query`, without parameters, on the wrapped connection.
pub fn (mut c Conn) execute(query string) ![]orm.Row {
	return c.conn.execute(query)
}

// orm_begin starts the ORM's transaction on the wrapped connection.
pub fn (mut c Conn) orm_begin() ! {
	c.conn.orm_begin()!
}

// orm_commit commits the ORM's transaction on the wrapped connection.
pub fn (mut c Conn) orm_commit() ! {
	c.conn.orm_commit()!
}

// orm_rollback rolls back the ORM's transaction on the wrapped connection.
pub fn (mut c Conn) orm_rollback() ! {
	c.conn.orm_rollback()!
}

// orm_savepoint sets a savepoint on the wrapped connection.
pub fn (mut c Conn) orm_savepoint(name string) ! {
	c.conn.orm_savepoint(name)!
}

// orm_rollback_to rolls back to a savepoint on the wrapped connection.
pub fn (mut c Conn) orm_rollback_to(name string) ! {
	c.conn.orm_rollback_to(name)!
}

// orm_release_savepoint releases a savepoint on the wrapped connection.
pub fn (mut c Conn) orm_release_savepoint(name string) ! {
	c.conn.orm_release_savepoint(name)!
}

// Tx is a transaction on one connection of a pool, from `Pool.begin_tx`.
@[heap]
pub struct Tx {
mut:
	tx &dbpg.Tx
}

// dialect reports the SQL the driver runs.
pub fn (t &Tx) dialect() orm.SQLDialect {
	return .pg
}

// exec_params runs `query` with `params` in place of its placeholders, and returns its rows as text.
pub fn (mut t Tx) exec_params(query string, params []string) ![][]?string {
	return rows_text(t.tx.exec_param_many(query, params)!)
}

// begin_tx starts a transaction, and returns the driver that runs in it.
pub fn (mut t Tx) begin_tx() !orm.Connection {
	return error('vgraph pg: a transaction is running already')
}

// commit_tx commits the transaction that `begin_tx` started.
pub fn (mut t Tx) commit_tx() ! {
	t.tx.commit()!
}

// rollback_tx rolls back the transaction that `begin_tx` started.
pub fn (mut t Tx) rollback_tx() ! {
	t.tx.rollback()!
}

// select runs the ORM's select on the wrapped connection.
pub fn (mut t Tx) select(config orm.SelectConfig, data orm.QueryData, where orm.QueryData) ![][]orm.Primitive {
	return t.tx.select(config, data, where)
}

// insert runs the ORM's insert on the wrapped connection.
pub fn (mut t Tx) insert(table orm.Table, data orm.QueryData) ! {
	t.tx.insert(table, data)!
}

// update runs the ORM's update on the wrapped connection.
pub fn (mut t Tx) update(table orm.Table, data orm.QueryData, where orm.QueryData) ! {
	t.tx.update(table, data, where)!
}

// delete runs the ORM's delete on the wrapped connection.
pub fn (mut t Tx) delete(table orm.Table, where orm.QueryData) ! {
	t.tx.delete(table, where)!
}

// create runs the ORM's create table on the wrapped connection.
pub fn (mut t Tx) create(table orm.Table, fields []orm.TableField) ! {
	t.tx.create(table, fields)!
}

// drop runs the ORM's drop table on the wrapped connection.
pub fn (mut t Tx) drop(table orm.Table) ! {
	t.tx.drop(table)!
}

// last_id returns the wrapped connection's last inserted id.
pub fn (mut t Tx) last_id() int {
	return t.tx.last_id()
}

// execute runs `query`, without parameters, on the wrapped connection.
pub fn (mut t Tx) execute(query string) ![]orm.Row {
	return t.tx.execute(query)
}
