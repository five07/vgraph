module articles

import net.http
import orm
import veb
import app
import vgraph.load
import comments
import comments.models as comment_models
import articles.models as article_models
import users.models as user_models

// owner_type is what comments on articles store as their `owner_type`.
const owner_type = comment_models.owner_type[article_models.Article]()

// Handler serves the article endpoints; the app mounts it at `/articles`.
pub struct Handler {
	db       orm.Connection
	store    article_models.ArticleStore
	users    user_models.UserStore
	comments comments.Service
}

// Handler.new returns the article handler, reading and writing articles
// through `store`, their authors through `users`, and their comments through
// `comment_service`. It loads the authors of listed articles through `db`.
pub fn Handler.new(db orm.Connection, store article_models.ArticleStore, users user_models.UserStore, comment_service comments.Service) &Handler {
	return &Handler{
		db:       db
		store:    store
		users:    users
		comments: comment_service
	}
}

// list returns every article.
@['/'; get]
pub fn (h &Handler) list(mut ctx app.Context) veb.Result {
	list := h.store.find_all() or { return app.fail(mut ctx, err) }
	views := h.views(list) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, views)
}

// show returns the article with the slug `slug`.
@['/:slug'; get]
pub fn (h &Handler) show(mut ctx app.Context, slug string) veb.Result {
	article := h.store.find(slug) or { return app.fail(mut ctx, err) }
	return render_one(h, mut ctx, .ok, article)
}

// create stores the article in the body, by the user named by its `user_slug`.
@['/'; post]
pub fn (h &Handler) create(mut ctx app.Context) veb.Result {
	input := app.decode_body[article_models.ArticleInput](ctx) or {
		return app.fail(mut ctx, err)
	}
	if input.user_slug == '' {
		return app.render_error(mut ctx, .bad_request, 'an article needs a `user_slug`')
	}
	user_id := h.users.reference_id(input.user_slug) or { return app.fail(mut ctx, err) }
	article := h.store.insert(user_id, input.fields()) or { return app.fail(mut ctx, err) }
	return render_one(h, mut ctx, .created, article)
}

// replace sets every writable field of the article with the slug `slug` from
// the body.
@['/:slug'; put]
pub fn (h &Handler) replace(mut ctx app.Context, slug string) veb.Result {
	update := app.decode_body[article_models.ArticleUpdate](ctx) or {
		return app.fail(mut ctx, err)
	}
	article := h.store.replace(slug, update) or { return app.fail(mut ctx, err) }
	return render_one(h, mut ctx, .ok, article)
}

// patch sets the fields in the body on the article with the slug `slug`.
@['/:slug'; patch]
pub fn (h &Handler) patch(mut ctx app.Context, slug string) veb.Result {
	patch := app.decode_body[article_models.ArticlePatch](ctx) or {
		return app.fail(mut ctx, err)
	}
	article := h.store.patch(slug, patch) or { return app.fail(mut ctx, err) }
	return render_one(h, mut ctx, .ok, article)
}

// delete marks the article with the slug `slug` deleted.
@['/:slug'; delete]
pub fn (h &Handler) delete(mut ctx app.Context, slug string) veb.Result {
	h.store.soft_delete(slug) or { return app.fail(mut ctx, err) }
	return ctx.no_content()
}

// list_comments returns the comments on the article with the slug `slug`,
// oldest first.
@['/:slug/comments'; get]
pub fn (h &Handler) list_comments(mut ctx app.Context, slug string) veb.Result {
	views := h.comments.list_on(owner_type, slug) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, views)
}

// create_comment stores the comment in the body on the article with the slug
// `slug`.
@['/:slug/comments'; post]
pub fn (h &Handler) create_comment(mut ctx app.Context, slug string) veb.Result {
	input := app.decode_body[comment_models.OwnedCommentInput](ctx) or {
		return app.fail(mut ctx, err)
	}
	view := h.comments.create_on(owner_type, slug, input) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .created, view)
}

// render_one writes `article` with the status `status`. It is a plain
// function, not a `Handler` method: veb serves every Handler method that takes
// a Context and returns veb.Result, private ones included.
fn render_one(h &Handler, mut ctx app.Context, status http.Status, article article_models.Article) veb.Result {
	views := h.views([article]) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, status, views[0])
}

// views returns `list` as the API returns it, looking up the authors' slugs
// in one query.
fn (h &Handler) views(list []article_models.Article) ![]article_models.ArticleView {
	authors := load.load_one[article_models.Article, user_models.User](h.db, list, 'user_id')!
	mut views := []article_models.ArticleView{cap: list.len}
	for record in list {
		views << record.view(if a := authors[record.user_id] { a.slug } else { '' })
	}
	return views
}
