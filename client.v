module vgraph

import load
import orm

// Client loads edges declared in a checked schema, over any ORM connection.
pub struct Client {
pub:
	conn   orm.Connection
	schema Schema
}

// Client.new checks `schema`, and returns a client that loads its edges through
// `conn`.
pub fn Client.new(conn orm.Connection, schema Schema) !Client {
	schema.validate()!
	return Client{
		conn:   conn
		schema: schema
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
