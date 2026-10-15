module main

import context
import veb
import db.sqlite
import net.http
import five07.vgraph
import five07.vgraph.graphql
import five07.vgraph.sqlite as vsqlite
import five07.otel.propagation
import graph
import migrations
// `app.Context` is written out in this module: importing `Context` by name
// makes V 0.5.2 generate C for veb's generics against a `main.Context`.
import app

pub struct App {
	db  sqlite.DB
	gql &graphql.Server = unsafe { nil }
	// propagator reads the caller's trace from a request's headers: W3C
	// `traceparent`, `tracestate` and `baggage`
	propagator propagation.TextMapPropagator = propagation.default_propagator()
}

// new_app opens the database named by `cfg`, runs any pending migrations, and
// loads the example data when `cfg.seed` is set and there are no users yet.
// `opts` give the graph its tracer provider.
fn new_app(cfg app.Config, opts vgraph.ClientOptions) !&App {
	return new_app_on(cfg, app.connect(cfg)!, opts)
}

// new_app_on builds the app on the open database `db`, with the graph's
// telemetry `opts`; migrations aren't traced.
fn new_app_on(cfg app.Config, db sqlite.DB, opts vgraph.ClientOptions) !&App {
	// the tables, the indexes their edges need and the ranges of their global
	// ids, through v.migrations
	mut migrator_db := db
	mut migrator := migrations.new(mut migrator_db)!
	migrator.migrate()!

	// the client `vgraph gen` writes into `graph/`, on vgraph's SQLite driver,
	// which runs the SQL the ORM can't: connections ordered by any field, and
	// nested pages cut by the database
	//
	// with a tracer provider in `opts`, it records the spans of each model's
	// level (`otel()` in `models/`), and one per statement
	g := graph.Graph.new(vsqlite.new(db), opts)!
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
// POST, as the GraphQL over HTTP spec describes. A request that carries a
// `traceparent` continues the caller's trace: its operation's span is a child
// of the caller's, and every span of the request is in that trace.
@['/graphql'; get; post]
pub fn (a &App) serve_graphql(mut ctx app.Context) veb.Result {
	header := ctx.req.header
	parent := a.propagator.extract(context.background(), propagation.GetterCarrier{
		get_fn: fn [header] (key string) ?string {
			return header.get_custom(key) or { return none }
		}
	})
	res := a.gql.handle(graphql.HttpRequest{
		method:       ctx.req.method.str()
		content_type: ctx.req.header.get(.content_type) or { '' }
		accept:       ctx.req.header.get(.accept) or { '' }
		query_string: if ctx.req.url.contains('?') { ctx.req.url.all_after('?') } else { '' }
		body:         ctx.req.data
	}, parent)
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
