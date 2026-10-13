module users

import veb
import app
import articles.models as article_models
import comments
import posts.models as post_models
import users.models as user_models

// Handler serves the user endpoints; the app mounts it at `/users`.
pub struct Handler {
	store    user_models.UserStore
	articles article_models.ArticleStore
	posts    post_models.PostStore
	comments comments.Service
}

// Handler.new returns the user handler, reading and writing users through
// `store`, and listing what they wrote through the other stores.
pub fn Handler.new(store user_models.UserStore, article_store article_models.ArticleStore, post_store post_models.PostStore, comment_service comments.Service) &Handler {
	return &Handler{
		store:    store
		articles: article_store
		posts:    post_store
		comments: comment_service
	}
}

// list returns every user.
@['/'; get]
pub fn (h &Handler) list(mut ctx app.Context) veb.Result {
	list := h.store.find_all() or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, list.map(it.view()))
}

// show returns the user with the slug `slug`.
@['/:slug'; get]
pub fn (h &Handler) show(mut ctx app.Context, slug string) veb.Result {
	user := h.store.find(slug) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, user.view())
}

// create stores the user in the body, and returns it.
@['/'; post]
pub fn (h &Handler) create(mut ctx app.Context) veb.Result {
	input := app.decode_body[user_models.UserInput](ctx) or { return app.fail(mut ctx, err) }
	user := h.store.insert(input) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .created, user.view())
}

// replace sets every field of the user with the slug `slug` from the body.
@['/:slug'; put]
pub fn (h &Handler) replace(mut ctx app.Context, slug string) veb.Result {
	input := app.decode_body[user_models.UserInput](ctx) or { return app.fail(mut ctx, err) }
	user := h.store.replace(slug, input) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, user.view())
}

// patch sets the fields in the body on the user with the slug `slug`.
@['/:slug'; patch]
pub fn (h &Handler) patch(mut ctx app.Context, slug string) veb.Result {
	patch := app.decode_body[user_models.UserPatch](ctx) or { return app.fail(mut ctx, err) }
	user := h.store.patch(slug, patch) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, user.view())
}

// delete marks the user with the slug `slug` deleted.
@['/:slug'; delete]
pub fn (h &Handler) delete(mut ctx app.Context, slug string) veb.Result {
	h.store.soft_delete(slug) or { return app.fail(mut ctx, err) }
	return ctx.no_content()
}

// list_articles returns the articles by the user with the slug `slug`, oldest
// first.
@['/:slug/articles'; get]
pub fn (h &Handler) list_articles(mut ctx app.Context, slug string) veb.Result {
	user := h.store.find(slug) or { return app.fail(mut ctx, err) }
	list := h.articles.find_by_user(user.id) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, list.map(it.view(user.slug)))
}

// list_posts returns the posts by the user with the slug `slug`, oldest first.
@['/:slug/posts'; get]
pub fn (h &Handler) list_posts(mut ctx app.Context, slug string) veb.Result {
	user := h.store.find(slug) or { return app.fail(mut ctx, err) }
	list := h.posts.find_by_user(user.id) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, list.map(it.view(user.slug)))
}

// list_comments returns the comments by the user with the slug `slug`, on
// any record, oldest first.
@['/:slug/comments'; get]
pub fn (h &Handler) list_comments(mut ctx app.Context, slug string) veb.Result {
	user := h.store.find(slug) or { return app.fail(mut ctx, err) }
	views := h.comments.list_by_user(user.id) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, views)
}
