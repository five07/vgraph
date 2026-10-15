module main

import context
import veb
import db.sqlite
import net.http
import orm
import five07.vgraph
import five07.vgraph.graphql
import five07.vgraph.sqlite as vsqlite
import graph
import migrations
// `app.Context` is written out in this module: importing `Context` by name
// makes V 0.5.2 generate C for veb's generics against a `main.Context`.
import app

pub struct App {
	db  sqlite.DB
	gql &graphql.Server = unsafe { nil }
}

// new_app opens the database named by `cfg`, runs any pending migrations, and
// loads the example data when `cfg.seed` is set and there are no users yet.
fn new_app(cfg app.Config) !&App {
	return new_app_on(cfg, app.connect(cfg)!, none)
}

// new_app_on builds the app on the open database `db`. When `tracer` is set,
// it receives every statement the graph runs, as the tests use it to count
// selects; migrations aren't traced.
fn new_app_on(cfg app.Config, db sqlite.DB, tracer ?vgraph.Tracer) !&App {
	// the tables, the indexes their edges need and the ranges of their global
	// ids, through v.migrations
	mut migrator_db := db
	mut migrator := migrations.new(mut migrator_db)!
	migrator.migrate()!

	// the client `vgraph gen` writes into `graph/`, on vgraph's SQLite driver,
	// which runs the SQL the ORM can't: connections ordered by any field, and
	// nested pages cut by the database
	driver := vsqlite.new(db)
	conn := if t := tracer { vgraph.trace(driver, t) } else { orm.Connection(driver) }
	g := graph.Graph.new(conn)!
	// the checks that read other tables: a comment's owner and parent
	register_comment_checks(g)

	if cfg.seed {
		seed(g)!
	}

	// GraphQL: the schema vgraph gen wrote. A request's mutations run in one
	// transaction, and the models' options and hooks check every write.
	return &App{
		db:  db
		gql: g.graphql(graph.Resolvers{})!
	}
}

// serve_graphql answers GraphQL requests: queries by GET or POST, mutations by
// POST, as the GraphQL over HTTP spec describes.
@['/graphql'; get; post]
pub fn (a &App) serve_graphql(mut ctx app.Context) veb.Result {
	res := a.gql.handle(graphql.HttpRequest{
		method:       ctx.req.method.str()
		content_type: ctx.req.header.get(.content_type) or { '' }
		accept:       ctx.req.header.get(.accept) or { '' }
		query_string: if ctx.req.url.contains('?') { ctx.req.url.all_after('?') } else { '' }
		body:         ctx.req.data
	}, context.background())
	for key, value in res.headers {
		ctx.set_custom_header(key, value) or {}
	}
	ctx.res.set_status(http.status_from_int(res.status))
	return ctx.send_response_to_client(res.content_type, res.body)
}

// HealthResponse is the body of `GET /health`.
struct HealthResponse {
	status string
}

// health reports whether the app can reach its database.
@['/health'; get]
pub fn (a &App) health(mut ctx app.Context) veb.Result {
	a.db.exec('SELECT 1') or {
		return app.render(mut ctx, .service_unavailable, HealthResponse{ status: 'database unavailable' })
	}
	return app.render(mut ctx, .ok, HealthResponse{ status: 'ok' })
}
