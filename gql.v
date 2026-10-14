module vgraph

import graphql
import orm

// GraphQL options, as entgql's annotations, and the transaction of a GraphQL
// request's mutations.

// GraphqlMutation is a mutation the GraphQL schema has for a table.
pub enum GraphqlMutation {
	create // create<Type>(input: Create<Type>Input!): <Type>!
	update // update<Type>(id: ID!, input: Update<Type>Input!): <Type>!
	delete // delete<Type>(id: ID!): ID!
}

// GraphqlSkip is a part of the GraphQL schema a field can be left out of, as
// entgql's `Skip` modes.
pub enum GraphqlSkip {
	object       // the field of the object type
	where        // the predicates of the WhereInput
	order        // the value of the OrderField enum
	create_input // the field of the Create<Type>Input
	update_input // the fields of the Update<Type>Input
}

// GraphqlTable gives a table's GraphQL options, as entgql's annotations. A
// struct gives them in a `graphql()` method, beside `edges()`.
pub struct GraphqlTable {
pub:
	// type_name names the object type; the struct's name when empty
	type_name string
	// query_field names the root field that lists the table; the table's name,
	// in camelCase, when empty, and no root field when `-`
	query_field string
	// node: the type implements `Node`, and `node` and `nodes` find its rows by
	// id. Its key must be an `i64` serial key with global ids (`global_ids`).
	node bool
	// relay: lists of the table, at the root and on edges, are Relay
	// connections, with cursors, rather than lists with `limit` and `offset`
	relay bool
	// mutations: the mutations the schema has for the table
	mutations []GraphqlMutation = [GraphqlMutation.create, .update, .delete]
	// directives are printed on the object type as written, such as
	// `@key(fields: "id")`
	directives []string
	// default_page: the size of a page of the table's lists and connections,
	// at the root and on edges, when a request gives none (`limit`, or `first`
	// and `last`); `GraphqlOptions.default_page` when 0
	default_page int
	// max_page: the most rows such a page may ask for; a request for more is
	// an error, and a request for no size gets this many when there is no
	// default. `GraphqlOptions.max_page` when 0
	max_page int
}

// GraphqlOptions are the options of the generated `Graph.graphql`, for every
// table whose `graphql()` doesn't set its own: the default and largest page
// sizes of lists and connections. 0 is no bound.
@[params]
pub struct GraphqlOptions {
pub:
	default_page int
	max_page     int
}

// page_sizes returns the page sizes of each table's lists and connections:
// its own `default_page` and `max_page`, or those of `opts`. It reports a size
// below zero, or a default past the maximum.
pub fn (s Schema) page_sizes(opts GraphqlOptions) !map[string]graphql.PageSize {
	graphql.PageSize{
		default_size: opts.default_page
		max_size:     opts.max_page
	}.check() or { return error('GraphqlOptions: ${err.msg()}') }
	mut sizes := map[string]graphql.PageSize{}
	for t in s.tables() {
		size := graphql.PageSize{
			default_size: if t.graphql.default_page > 0 {
				t.graphql.default_page
			} else {
				opts.default_page
			}
			max_size:     if t.graphql.max_page > 0 { t.graphql.max_page } else { opts.max_page }
		}
		size.check() or { return error('`${t.name}`: ${err.msg()}') }
		sizes[t.name] = size
	}
	return sizes
}

// Graphql is implemented by structs that give GraphQL options. vgraph finds
// the method through reflection, so declaring it is enough.
pub interface Graphql {
	graphql() GraphqlTable
}

// TxContext is the context of a GraphQL request's mutations in a
// transaction: the request's own context, and the client in the transaction.
// A client's `with_ctx` takes it apart, so the generated resolvers run in the
// transaction, and hooks and privacy rules see the request's context.
pub struct TxContext {
pub:
	ctx    graphql.Context
	client Client
}

// GraphqlTransaction runs a GraphQL request's mutations in one transaction of
// `client`, as entgql's `Transactioner` does. The generated server sets it
// when the client can begin a transaction.
pub struct GraphqlTransaction {
pub:
	client Client
}

// begin starts the transaction, and returns the context the mutations run
// with: a `TxContext`.
pub fn (t GraphqlTransaction) begin(ctx graphql.Context) !graphql.Context {
	return TxContext{
		ctx:    ctx
		client: t.client.with_ctx(ctx).begin()!
	}
}

// commit commits the transaction `begin` started.
pub fn (t GraphqlTransaction) commit(ctx graphql.Context) ! {
	if ctx is TxContext {
		ctx.client.commit()!
	}
}

// rollback rolls back the transaction `begin` started.
pub fn (t GraphqlTransaction) rollback(ctx graphql.Context) ! {
	if ctx is TxContext {
		ctx.client.rollback()!
	}
}

// can_begin reports whether the client can begin a transaction: it has a
// driver or an `orm.TransactionalConnection`, or runs in one already.
pub fn (c Client) can_begin() bool {
	return c.in_tx || c.conn is Driver || c.conn is orm.TransactionalConnection
}
