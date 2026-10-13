module main

import veb
import db.sqlite
import orm
import five07.vgraph
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
	db sqlite.DB
}

// new_app opens the database named by `cfg`, creates any missing tables,
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
	// in dependency order: articles, posts and comments refer to users
	user_models.create_tables(conn)!
	article_models.create_tables(conn)!
	post_models.create_tables(conn)!
	comment_models.create_tables(conn)!

	mut schema := vgraph.Schema{}
	schema.add[user_models.User]()!
	schema.add[article_models.Article]()!
	schema.add[post_models.Post]()!
	schema.add[comment_models.Comment]()!
	graph := vgraph.Client.new(conn, schema)!

	user_store := user_models.UserStore.new(conn)
	article_store := article_models.ArticleStore.new(conn)
	post_store := post_models.PostStore.new(conn)
	comment_store := comment_models.CommentStore.new(conn)
	// The kinds of records that take comments, keyed by `owner_type`.
	comment_service := comments.Service.new(graph, comment_store, user_store, {
		comment_models.owner_type[article_models.Article](): comments.Owner{
			id_of:    fn [article_store] (slug string) !int {
				return article_store.id_of(slug)
			}
			slugs_on: fn [graph] (list []comment_models.Comment) !map[int]string {
				return owner_slugs[article_models.Article](graph, list, 'article')
			}
		}
		comment_models.owner_type[post_models.Post]():       comments.Owner{
			id_of:    fn [post_store] (slug string) !int {
				return post_store.id_of(slug)
			}
			slugs_on: fn [graph] (list []comment_models.Comment) !map[int]string {
				return owner_slugs[post_models.Post](graph, list, 'post')
			}
		}
	})

	if cfg.seed {
		seed(user_store, article_store, post_store, comment_store)!
	}

	mut api := &App{
		db: db
	}
	mut user_handler := users.Handler.new(user_store, article_store, post_store, comment_service)
	api.register_controller[users.Handler, app.Context]('/users', mut user_handler)!
	mut article_handler := articles.Handler.new(graph, article_store, user_store, comment_service)
	api.register_controller[articles.Handler, app.Context]('/articles', mut article_handler)!
	mut post_handler := posts.Handler.new(graph, post_store, user_store, comment_service)
	api.register_controller[posts.Handler, app.Context]('/posts', mut post_handler)!
	mut comment_handler := comments.Handler.new(comment_service)
	api.register_controller[comments.Handler, app.Context]('/comments', mut comment_handler)!
	return api
}

// owner_slugs returns the slugs of the `T` records that the comments in `list`
// are on, keyed by id, in one query: `edge` is the comment's polymorphic edge to
// a `T`, such as `article`.
fn owner_slugs[T](graph vgraph.Client, list []comment_models.Comment, edge string) !map[int]string {
	owners := graph.load_one[comment_models.Comment, T](list, edge)!
	mut slugs := map[int]string{}
	for id, owner in owners {
		slugs[id] = owner.slug
	}
	return slugs
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
