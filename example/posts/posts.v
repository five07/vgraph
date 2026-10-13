module posts

import net.http
import veb
import graph
import app
import comments
import comments.models as comment_models
import posts.models as post_models
import users.models as user_models

// owner_type is what comments on posts store as their `owner_type`.
const owner_type = comment_models.owner_type[post_models.Post]()

// Handler serves the post endpoints; the app mounts it at `/posts`.
pub struct Handler {
	graph    graph.Graph
	store    post_models.PostStore
	users    user_models.UserStore
	comments comments.Service
}

// Handler.new returns the post handler, reading and writing posts through
// `store`, their authors through `users`, and their comments through
// `comment_service`. It loads the authors of listed posts through `g`.
pub fn Handler.new(g graph.Graph, store post_models.PostStore, users user_models.UserStore, comment_service comments.Service) &Handler {
	return &Handler{
		graph:    g
		store:    store
		users:    users
		comments: comment_service
	}
}

// list returns every post.
@['/'; get]
pub fn (h &Handler) list(mut ctx app.Context) veb.Result {
	list := h.store.find_all() or { return app.fail(mut ctx, err) }
	views := h.views(list) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, views)
}

// show returns the post with the slug `slug`.
@['/:slug'; get]
pub fn (h &Handler) show(mut ctx app.Context, slug string) veb.Result {
	post := h.store.find(slug) or { return app.fail(mut ctx, err) }
	return render_one(h, mut ctx, .ok, post)
}

// create stores the post in the body, by the user named by its `user_slug`.
@['/'; post]
pub fn (h &Handler) create(mut ctx app.Context) veb.Result {
	input := app.decode_body[post_models.PostInput](ctx) or { return app.fail(mut ctx, err) }
	if input.user_slug == '' {
		return app.render_error(mut ctx, .bad_request, 'a post needs a `user_slug`')
	}
	user_id := h.users.reference_id(input.user_slug) or { return app.fail(mut ctx, err) }
	post := h.store.insert(user_id, input.fields()) or { return app.fail(mut ctx, err) }
	return render_one(h, mut ctx, .created, post)
}

// replace sets every writable field of the post with the slug `slug` from the
// body.
@['/:slug'; put]
pub fn (h &Handler) replace(mut ctx app.Context, slug string) veb.Result {
	update := app.decode_body[post_models.PostUpdate](ctx) or { return app.fail(mut ctx, err) }
	post := h.store.replace(slug, update) or { return app.fail(mut ctx, err) }
	return render_one(h, mut ctx, .ok, post)
}

// patch sets the fields in the body on the post with the slug `slug`.
@['/:slug'; patch]
pub fn (h &Handler) patch(mut ctx app.Context, slug string) veb.Result {
	patch := app.decode_body[post_models.PostPatch](ctx) or { return app.fail(mut ctx, err) }
	post := h.store.patch(slug, patch) or { return app.fail(mut ctx, err) }
	return render_one(h, mut ctx, .ok, post)
}

// delete marks the post with the slug `slug` deleted.
@['/:slug'; delete]
pub fn (h &Handler) delete(mut ctx app.Context, slug string) veb.Result {
	h.store.soft_delete(slug) or { return app.fail(mut ctx, err) }
	return ctx.no_content()
}

// list_comments returns the comments on the post with the slug `slug`,
// oldest first.
@['/:slug/comments'; get]
pub fn (h &Handler) list_comments(mut ctx app.Context, slug string) veb.Result {
	views := h.comments.list_on(owner_type, slug) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, views)
}

// create_comment stores the comment in the body on the post with the slug
// `slug`.
@['/:slug/comments'; post]
pub fn (h &Handler) create_comment(mut ctx app.Context, slug string) veb.Result {
	input := app.decode_body[comment_models.OwnedCommentInput](ctx) or {
		return app.fail(mut ctx, err)
	}
	view := h.comments.create_on(owner_type, slug, input) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .created, view)
}

// render_one writes `post` with the status `status`. It is a plain function,
// not a `Handler` method: veb serves every Handler method that takes a
// Context and returns veb.Result, private ones included.
fn render_one(h &Handler, mut ctx app.Context, status http.Status, post post_models.Post) veb.Result {
	views := h.views([post]) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, status, views[0])
}

// views returns `list` as the API returns it, looking up the authors' slugs
// in one query.
fn (h &Handler) views(list []post_models.Post) ![]post_models.PostView {
	nodes := h.graph.posts().with_author().nodes(list)!
	mut views := []post_models.PostView{cap: list.len}
	for n in nodes {
		views << n.post.view(if a := n.author { a.user.slug } else { '' })
	}
	return views
}
