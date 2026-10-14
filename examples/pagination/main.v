module main

// A GraphQL server on an in-memory SQLite database of 40 authors and 300
// books: `v run .`, then send the queries in README.md to
// http://localhost:8080/graphql (or the port in `PORT`).
import veb
import db.sqlite
import net.http
import os
import five07.vgraph.graphql
import five07.vgraph.sqlite as vsqlite
import catalog
import graph

pub struct Context {
	veb.Context
}

pub struct App {
	gql &graphql.Server = unsafe { nil }
}

fn main() {
	mut db := sqlite.connect(':memory:') or { panic(err) }
	mut api := new_app(mut db) or {
		eprintln('startup: ${err}')
		exit(1)
	}
	port := (os.getenv_opt('PORT') or { '8080' }).int()
	veb.run_at[App, Context](mut api, port: port) or {
		eprintln('server: ${err}')
		exit(1)
	}
}

// new_app migrates and seeds `db`, and returns the app that serves its
// GraphQL schema. It reads through vgraph's SQLite driver, which runs what
// the ORM can't: connections ordered by a field, and pages per parent cut by
// a window function.
fn new_app(mut db sqlite.DB) !&App {
	catalog.migrate(mut db, .sqlite, 'schema_migrations')!
	g := graph.Graph.new(vsqlite.new(db))!
	catalog.seed(g)!
	return &App{
		gql: g.graphql(graph.Resolvers{})!
	}
}

// serve_graphql answers GraphQL requests by GET or POST.
@['/graphql'; get; post]
pub fn (a &App) serve_graphql(mut ctx Context) veb.Result {
	res := a.gql.handle(graphql.HttpRequest{
		method:       ctx.req.method.str()
		content_type: ctx.req.header.get(.content_type) or { '' }
		accept:       ctx.req.header.get(.accept) or { '' }
		query_string: if ctx.req.url.contains('?') { ctx.req.url.all_after('?') } else { '' }
		body:         ctx.req.data
	}, unsafe { nil })
	for key, value in res.headers {
		ctx.set_custom_header(key, value) or {}
	}
	ctx.res.set_status(http.status_from_int(res.status))
	return ctx.send_response_to_client(res.content_type, res.body)
}
