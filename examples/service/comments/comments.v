module comments

import net.http
import veb
import app
import comments.models as comment_models

// Handler serves the comment endpoints; the app mounts it at `/comments`.
pub struct Handler {
	service Service
	store   comment_models.CommentStore
}

// Handler.new returns the comment handler, built on `service`.
pub fn Handler.new(service Service) &Handler {
	return &Handler{
		service: service
		store:   service.store
	}
}

// list returns every comment, or with `?owner_type=Article&owner_slug=...`
// only the comments on that record.
@['/'; get]
pub fn (h &Handler) list(mut ctx app.Context) veb.Result {
	owner_type := ctx.query['owner_type'] or { '' }
	owner_slug := ctx.query['owner_slug'] or { '' }
	if owner_type != '' || owner_slug != '' {
		if owner_type == '' || owner_slug == '' {
			return app.render_error(mut ctx, .bad_request, 'filter by both `owner_type` and `owner_slug`')
		}
		views := h.service.list_on(owner_type, owner_slug) or { return app.fail(mut ctx, err) }
		return app.render(mut ctx, .ok, views)
	}
	list := h.store.find_all() or { return app.fail(mut ctx, err) }
	views := h.service.views(list) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .ok, views)
}

// show returns the comment with the slug `slug`.
@['/:slug'; get]
pub fn (h &Handler) show(mut ctx app.Context, slug string) veb.Result {
	comment := h.store.find(slug) or { return app.fail(mut ctx, err) }
	return render_one(h, mut ctx, .ok, comment)
}

// create stores the comment in the body, on the record named by its
// `owner_type` and `owner_slug`.
@['/'; post]
pub fn (h &Handler) create(mut ctx app.Context) veb.Result {
	input := app.decode_body[comment_models.CommentInput](ctx) or {
		return app.fail(mut ctx, err)
	}
	view := h.service.create(input) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, .created, view)
}

// replace sets every writable field of the comment with the slug `slug` from
// the body.
@['/:slug'; put]
pub fn (h &Handler) replace(mut ctx app.Context, slug string) veb.Result {
	fields := app.decode_body[comment_models.CommentUpdate](ctx) or {
		return app.fail(mut ctx, err)
	}
	comment := h.store.replace(slug, fields) or { return app.fail(mut ctx, err) }
	return render_one(h, mut ctx, .ok, comment)
}

// patch sets the fields in the body on the comment with the slug `slug`.
@['/:slug'; patch]
pub fn (h &Handler) patch(mut ctx app.Context, slug string) veb.Result {
	patch := app.decode_body[comment_models.CommentPatch](ctx) or {
		return app.fail(mut ctx, err)
	}
	comment := h.store.patch(slug, patch) or { return app.fail(mut ctx, err) }
	return render_one(h, mut ctx, .ok, comment)
}

// delete marks the comment with the slug `slug` deleted. Its replies are kept.
@['/:slug'; delete]
pub fn (h &Handler) delete(mut ctx app.Context, slug string) veb.Result {
	h.store.soft_delete(slug) or { return app.fail(mut ctx, err) }
	return ctx.no_content()
}

// render_one writes `comment` with the status `status`. It is a plain
// function, not a `Handler` method: veb serves every Handler method that
// takes a Context and returns veb.Result, private ones included.
fn render_one(h &Handler, mut ctx app.Context, status http.Status, comment comment_models.Comment) veb.Result {
	view := h.service.view(comment) or { return app.fail(mut ctx, err) }
	return app.render(mut ctx, status, view)
}
