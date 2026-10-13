module vgraph

import graphql
import load
import orm

// Client loads edges declared in a checked schema, and writes rows, over any
// ORM connection.
pub struct Client {
pub:
	conn   orm.Connection
	schema Schema
	// ctx is the app's value for the queries and writes of this client, set
	// with `with_ctx`.
	ctx graphql.Context = NoContext{}
	// in_tx: the client runs inside a transaction (`begin`).
	in_tx bool
	// skipped: the names of the hooks and interceptors it leaves out (`skip`)
	skipped []string
	// privileged: it skips privacy rules; bypassed: interceptors too
	privileged bool
	bypassed   bool
mut:
	owns_tx  bool
	registry &Registry = &Registry{}
	txstate  &TxState  = unsafe { nil }
}

// TxState holds what runs once a transaction ends.
@[heap]
struct TxState {
mut:
	commits   []fn ()
	rollbacks []fn ()
}

// NoContext is the context of a client that `with_ctx` hasn't given one.
pub struct NoContext {}

// Client.new checks `schema`, and returns a client that loads its edges through
// `conn`. When `conn` is a `Driver`, writes use it.
pub fn Client.new(conn orm.Connection, schema Schema) !Client {
	schema.validate()!
	return Client{
		conn:     conn
		schema:   schema
		registry: &Registry{}
	}
}

// with_ctx returns a client whose queries and writes carry `ctx`, a value the
// app defines (its user, its request), to hooks and privacy rules. It is a
// `graphql.Context`, so the GraphQL server passes each request's context on:
// V can't convert one interface into another, so vgraph and its GraphQL module
// share the one type.
pub fn (c Client) with_ctx(ctx graphql.Context) Client {
	return Client{
		...c
		ctx: ctx
	}
}

// begin starts a transaction, and returns the client that runs in it. Inside a
// transaction already, it returns a client in the same one, whose `commit` and
// `rollback` leave it to the outer client.
pub fn (c Client) begin() !Client {
	if c.in_tx {
		return Client{
			...c
			owns_tx: false
		}
	}
	if c.conn is Driver {
		mut d := c.conn as Driver
		inner := d.begin_tx()!
		return Client{
			...c
			conn:    inner
			in_tx:   true
			owns_tx: true
			txstate: &TxState{}
		}
	}
	if c.conn is orm.TransactionalConnection {
		mut t := c.conn as orm.TransactionalConnection
		t.orm_begin()!
		return Client{
			...c
			in_tx:   true
			owns_tx: true
			txstate: &TxState{}
		}
	}
	return error('this connection runs no transactions: pass a vgraph driver (five07.vgraph.sqlite or five07.vgraph.pg), or an orm.TransactionalConnection')
}

// commit commits the transaction that `begin` started, then runs what
// `on_commit` registered.
pub fn (c Client) commit() ! {
	if !c.owns_tx {
		return
	}
	if c.in_tx {
		if c.conn is TxConnection {
			mut t := c.conn as TxConnection
			t.commit_tx()!
		} else if c.conn is orm.TransactionalConnection {
			mut t := c.conn as orm.TransactionalConnection
			t.orm_commit()!
		}
	}
	if !isnil(c.txstate) {
		for f in c.txstate.commits {
			f()
		}
	}
}

// rollback rolls back the transaction that `begin` started, then runs what
// `on_rollback` registered.
pub fn (c Client) rollback() ! {
	if !c.owns_tx {
		return
	}
	defer {
		if !isnil(c.txstate) {
			for f in c.txstate.rollbacks {
				f()
			}
		}
	}
	if c.in_tx {
		if c.conn is TxConnection {
			mut t := c.conn as TxConnection
			t.rollback_tx()!
		} else if c.conn is orm.TransactionalConnection {
			mut t := c.conn as orm.TransactionalConnection
			t.orm_rollback()!
		}
	}
}

// on_commit runs `f` once the client's transaction commits; outside one, at
// once.
pub fn (c Client) on_commit(f fn ()) {
	if isnil(c.txstate) {
		f()
		return
	}
	mut state := c.txstate
	state.commits << f
}

// on_rollback runs `f` if the client's transaction rolls back; outside one,
// never.
pub fn (c Client) on_rollback(f fn ()) {
	if isnil(c.txstate) {
		return
	}
	mut state := c.txstate
	state.rollbacks << f
}

// atomic returns a client in a transaction when the connection can run one.
// Otherwise it returns `c`, whose statements then run one by one, with its own
// callbacks for `on_commit` and `on_rollback`.
fn (c Client) atomic() !Client {
	if c.in_tx || c.conn is Driver || c.conn is orm.TransactionalConnection {
		return c.begin()
	}
	return Client{
		...c
		owns_tx: true
		txstate: &TxState{}
	}
}

// load_one follows the many_to_one edge `edge` of `C` from each of `children`,
// and returns the `P` records reached, keyed by their primary key's string form
// (`'3'`, or a UUID), in one query.
pub fn (c Client) load_one[C, P](children []C, edge string) !map[string]P {
	e := c.edge_between(load.table_name[C](), edge, load.table_name[P]())!
	if e.kind != .many_to_one {
		return error('`${load.table_name[C]()}.${edge}` is ${e.kind}; use `load_many`')
	}
	return load.load_one[C, P](c.conn, children, e.column,
		type_col: e.type_col
		type_val: e.type_val
		soft_del: e.soft_del
		query:    c.prepare_query(e.to, load.Query{})!
	)
}

// load_many follows the one_to_many, one_to_one or many_to_many edge `edge` of
// `P` from each of `parents`, and returns the `C` records reached, keyed by the
// parent's primary key's string form: one query, or two through a join table. A
// one_to_one edge gives each parent at most one record.
pub fn (c Client) load_many[P, C](parents []P, edge string) !map[string][]C {
	e := c.edge_between(load.table_name[P](), edge, load.table_name[C]())!
	opts := load.Options{
		type_col: e.type_col
		type_val: e.type_val
		soft_del: e.soft_del
		query:    c.prepare_query(e.to, load.Query{})!
	}
	return match e.kind {
		.one_to_many, .one_to_one { load.load_many[P, C](c.conn, parents, e.column, opts)! }
		.many_to_many {
			load.load_through[P, C](c.conn, parents, e.through, e.column, e.through_to, opts)!
		}
		.many_to_one { error('`${load.table_name[P]()}.${edge}` is many_to_one; use `load_one`') }
	}
}

fn (c Client) edge_between(from string, name string, to string) !Edge {
	e := c.schema.edge(from, name)!
	if e.to != to {
		return error('`${from}.${name}` leads to `${e.to}`, not `${to}`')
	}
	return e
}
