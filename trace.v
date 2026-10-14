module vgraph

import orm
import time

// TraceKind is what a traced statement did.
pub enum TraceKind {
	select
	insert
	update
	delete
	ddl // create or drop table
	raw // a statement the app or a driver wrote as SQL
	begin
	commit
	rollback
}

// TraceEvent reports one statement. It carries no values: no parameters, and no
// error message, which a database can fill with them. `statement` is set only for
// the SQL vgraph writes itself (`Driver.exec_params`), with its placeholders.
pub struct TraceEvent {
pub:
	kind      TraceKind
	table     string
	statement string
	duration  time.Duration
	failed    bool
}

// Tracer receives the events of a traced connection.
pub type Tracer = fn (e TraceEvent)

// trace returns `conn`, reporting each statement it runs to `f`. It keeps what
// `conn` is: a driver stays a driver, and a transactional connection stays one.
pub fn trace(conn orm.Connection, f Tracer) orm.Connection {
	if conn is Driver {
		return &TracedDriver{
			TracedTx: TracedTx{
				Traced: Traced{
					inner: conn
					f:     f
				}
			}
		}
	}
	if conn is orm.TransactionalConnection {
		return &TracedTx{
			Traced: Traced{
				inner: conn
				f:     f
			}
		}
	}
	return &Traced{
		inner: conn
		f:     f
	}
}

// Traced is a connection that reports its statements.
@[heap]
pub struct Traced {
mut:
	inner orm.Connection
	f     Tracer @[required]
}

fn (t &Traced) emit(kind TraceKind, table string, statement string, start time.Time, failed bool) {
	t.f(TraceEvent{
		kind:      kind
		table:     table
		statement: statement
		duration:  time.since(start)
		failed:    failed
	})
}

// select runs and reports the ORM's select.
pub fn (mut t Traced) select(config orm.SelectConfig, data orm.QueryData, where orm.QueryData) ![][]orm.Primitive {
	start := time.now()
	rows := t.inner.select(config, data, where) or {
		t.emit(.select, config.table.name, '', start, true)
		return err
	}
	t.emit(.select, config.table.name, '', start, false)
	return rows
}

// insert runs and reports the ORM's insert.
pub fn (mut t Traced) insert(table orm.Table, data orm.QueryData) ! {
	start := time.now()
	t.inner.insert(table, data) or {
		t.emit(.insert, table.name, '', start, true)
		return err
	}
	t.emit(.insert, table.name, '', start, false)
}

// update runs and reports the ORM's update.
pub fn (mut t Traced) update(table orm.Table, data orm.QueryData, where orm.QueryData) ! {
	start := time.now()
	t.inner.update(table, data, where) or {
		t.emit(.update, table.name, '', start, true)
		return err
	}
	t.emit(.update, table.name, '', start, false)
}

// delete runs and reports the ORM's delete.
pub fn (mut t Traced) delete(table orm.Table, where orm.QueryData) ! {
	start := time.now()
	t.inner.delete(table, where) or {
		t.emit(.delete, table.name, '', start, true)
		return err
	}
	t.emit(.delete, table.name, '', start, false)
}

// create runs and reports the ORM's create table.
pub fn (mut t Traced) create(table orm.Table, fields []orm.TableField) ! {
	start := time.now()
	t.inner.create(table, fields) or {
		t.emit(.ddl, table.name, '', start, true)
		return err
	}
	t.emit(.ddl, table.name, '', start, false)
}

// drop runs and reports the ORM's drop table.
pub fn (mut t Traced) drop(table orm.Table) ! {
	start := time.now()
	t.inner.drop(table) or {
		t.emit(.ddl, table.name, '', start, true)
		return err
	}
	t.emit(.ddl, table.name, '', start, false)
}

// last_id returns the wrapped connection's last inserted id.
pub fn (mut t Traced) last_id() int {
	return t.inner.last_id()
}

// execute runs and reports a raw statement, without its SQL, which may hold
// values.
pub fn (mut t Traced) execute(query string) ![]orm.Row {
	start := time.now()
	rows := t.inner.execute(query) or {
		t.emit(.raw, '', '', start, true)
		return err
	}
	t.emit(.raw, '', '', start, false)
	return rows
}

// TracedTx is a traced connection that runs the ORM's transactions.
@[heap]
pub struct TracedTx {
	Traced
}

fn (mut t TracedTx) tx_call(kind TraceKind, f fn (mut c orm.TransactionalConnection) !) ! {
	mut c := t.inner as orm.TransactionalConnection
	start := time.now()
	f(mut c) or {
		t.emit(kind, '', '', start, true)
		return err
	}
	t.emit(kind, '', '', start, false)
}

// orm_begin starts and reports the ORM's transaction.
pub fn (mut t TracedTx) orm_begin() ! {
	t.tx_call(.begin, fn (mut c orm.TransactionalConnection) ! {
		c.orm_begin()!
	})!
}

// orm_commit commits and reports the ORM's transaction.
pub fn (mut t TracedTx) orm_commit() ! {
	t.tx_call(.commit, fn (mut c orm.TransactionalConnection) ! {
		c.orm_commit()!
	})!
}

// orm_rollback rolls back and reports the ORM's transaction.
pub fn (mut t TracedTx) orm_rollback() ! {
	t.tx_call(.rollback, fn (mut c orm.TransactionalConnection) ! {
		c.orm_rollback()!
	})!
}

// orm_savepoint sets a savepoint on the wrapped connection.
pub fn (mut t TracedTx) orm_savepoint(name string) ! {
	mut c := t.inner as orm.TransactionalConnection
	c.orm_savepoint(name)!
}

// orm_rollback_to rolls back to a savepoint on the wrapped connection.
pub fn (mut t TracedTx) orm_rollback_to(name string) ! {
	mut c := t.inner as orm.TransactionalConnection
	c.orm_rollback_to(name)!
}

// orm_release_savepoint releases a savepoint on the wrapped connection.
pub fn (mut t TracedTx) orm_release_savepoint(name string) ! {
	mut c := t.inner as orm.TransactionalConnection
	c.orm_release_savepoint(name)!
}

// TracedDriver is a traced vgraph driver: its own SQL is reported with its
// placeholders, and its transactions are traced too. It passes the ORM's
// transactions on to the driver, which must run them for them to be used.
@[heap]
pub struct TracedDriver {
	TracedTx
}

// dialect reports the SQL the wrapped driver runs.
pub fn (t &TracedDriver) dialect() orm.SQLDialect {
	d := t.inner as Driver
	return d.dialect()
}

// exec_params runs and reports the driver's own SQL, without its parameters.
pub fn (mut t TracedDriver) exec_params(query string, params []string) ![][]?string {
	mut d := t.inner as Driver
	start := time.now()
	rows := d.exec_params(query, params) or {
		t.emit(.raw, '', query, start, true)
		return err
	}
	t.emit(.raw, '', query, start, false)
	return rows
}

// begin_tx starts and reports a transaction, and returns its connection,
// traced.
pub fn (mut t TracedDriver) begin_tx() !orm.Connection {
	mut d := t.inner as Driver
	start := time.now()
	inner := d.begin_tx() or {
		t.emit(.begin, '', '', start, true)
		return err
	}
	t.emit(.begin, '', '', start, false)
	return trace(inner, t.f)
}

// commit_tx commits and reports the transaction `begin_tx` started.
pub fn (mut t TracedDriver) commit_tx() ! {
	mut c := t.inner as TxConnection
	start := time.now()
	c.commit_tx() or {
		t.emit(.commit, '', '', start, true)
		return err
	}
	t.emit(.commit, '', '', start, false)
}

// rollback_tx rolls back and reports the transaction `begin_tx` started.
pub fn (mut t TracedDriver) rollback_tx() ! {
	mut c := t.inner as TxConnection
	start := time.now()
	c.rollback_tx() or {
		t.emit(.rollback, '', '', start, true)
		return err
	}
	t.emit(.rollback, '', '', start, false)
}
