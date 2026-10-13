module main

import veb
import db.sqlite
import net.http
import orm
import five07.vgraph.graphql
import graph
import migrations
// `app.Context` is written out in this module: importing `Context` by name
// makes V 0.5.2 generate C for veb's generics against a `main.Context`.
import app
import articles
import articles.models as article_models
import comments
import comments.models as comment_models
import posts
import posts.models as post_models
import users
import users.models as user_models

pub struct App {
	veb.Controller
	db  sqlite.DB
	gql &graphql.Server = unsafe { nil }
}

// new_app opens the database named by `cfg`, runs any pending migrations,
// loads the example data when `cfg.seed` is set and there are no users yet,
// and mounts each model's controller.
fn new_app(cfg app.Config) !&App {
	db := app.connect(cfg)!
	return new_app_on(cfg, db, db)
}

// new_app_on builds the app on the open database `db`, and runs every store's
// queries through `conn`: `db` itself, or a wrapper such as the
// `app.CountingConnection` the tests use.
fn new_app_on(cfg app.Config, db sqlite.DB, conn orm.Connection) !&App {
	// the tables, and the indexes their edges need, through v.migrations. They
	// run on `db`, so that a counting `conn` logs only the app's own queries.
	mut migrator_db := db
	mut migrator := migrations.new(mut migrator_db)!
	migrator.migrate()!

	// the client `vgraph gen` writes into `graph/`, which checks the edges
	g := graph.Graph.new(conn)!

	user_store := user_models.UserStore.new(conn)
	article_store := article_models.ArticleStore.new(conn)
	post_store := post_models.PostStore.new(conn)
	comment_store := comment_models.CommentStore.new(conn)
	// The kinds of records that take comments, keyed by `owner_type`.
	comment_service := comments.Service.new(g, comment_store, user_store, {
		comment_models.owner_type[article_models.Article](): comments.Owner{
			id_of: fn [article_store] (slug string) !int {
				return article_store.id_of(slug)
			}
		}
		comment_models.owner_type[post_models.Post]():       comments.Owner{
			id_of: fn [post_store] (slug string) !int {
				return post_store.id_of(slug)
			}
		}
	})

	if cfg.seed {
		seed(user_store, article_store, post_store, comment_store)!
	}

	// GraphQL: the schema vgraph gen wrote, with the mutations of api.graphql,
	// which go through the same stores and services as the REST endpoints
	mut server := g.graphql(graph.Resolvers{
		graph:             g
		users:             user_store
		articles:          article_store
		posts:             post_store
		comments:          comment_store
		create_comment:    fn [comment_service] (input comment_models.CommentInput) !comment_models.Comment {
			return comment_service.create_row(input)
		}
		create_comment_on: fn [comment_service] (owner_type string, owner_slug string, input comment_models.OwnedCommentInput) !comment_models.Comment {
			return comment_service.create_on_row(owner_type, owner_slug, input)
		}
	})!
	// a request's mutations run in one transaction, rolled back if one fails
	server.transaction = SqliteTransaction{
		db: db
	}

	mut api := &App{
		db:  db
		gql: server
	}
	mut user_handler := users.Handler.new(user_store, article_store, post_store, comment_service)
	api.register_controller[users.Handler, app.Context]('/users', mut user_handler)!
	mut article_handler := articles.Handler.new(g, article_store, user_store, comment_service)
	api.register_controller[articles.Handler, app.Context]('/articles', mut article_handler)!
	mut post_handler := posts.Handler.new(g, post_store, user_store, comment_service)
	api.register_controller[posts.Handler, app.Context]('/posts', mut post_handler)!
	mut comment_handler := comments.Handler.new(comment_service)
	api.register_controller[comments.Handler, app.Context]('/comments', mut comment_handler)!
	return api
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
	}, unsafe { nil })
	for key, value in res.headers {
		ctx.set_custom_header(key, value) or {}
	}
	ctx.res.set_status(http.status_from_int(res.status))
	return ctx.send_response_to_client(res.content_type, res.body)
}

// SqliteTransaction runs a GraphQL request's mutations in one SQLite
// transaction.
struct SqliteTransaction {
mut:
	db sqlite.DB
}

fn (mut t SqliteTransaction) begin() ! {
	t.db.orm_begin()!
}

fn (mut t SqliteTransaction) commit() ! {
	t.db.orm_commit()!
}

fn (mut t SqliteTransaction) rollback() ! {
	t.db.orm_rollback()!
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
