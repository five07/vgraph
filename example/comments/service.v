module comments

import graph
import app
import comments.models as comment_models
import users.models as user_models

// Service holds the comment operations that more than one handler needs: the
// comment handler, and the handlers of the records comments are on. Its
// methods return values, not veb.Result, so veb doesn't serve them as routes.
pub struct Service {
	graph  graph.Graph
	store  comment_models.CommentStore
	users  user_models.UserStore
	owners map[string]Owner
}

// Service.new returns a service that keeps comments in `store`, their authors
// in `users`, and allows comments only on the kinds of records in `owners`,
// keyed by `owner_type`. It loads related records through `g`.
pub fn Service.new(g graph.Graph, store comment_models.CommentStore, users user_models.UserStore, owners map[string]Owner) Service {
	return Service{
		graph:  g
		store:  store
		users:  users
		owners: owners
	}
}

// list_on returns the comments on the record of the type `owner_type` with
// the slug `owner_slug`, oldest first. A missing or deleted record gives a
// `NotFoundError`.
pub fn (s Service) list_on(owner_type string, owner_slug string) ![]comment_models.CommentView {
	owner := s.owner(owner_type)!
	owner_id := owner.id_of(owner_slug)!
	return s.views(s.store.find_by_owner(owner_type, owner_id)!)
}

// create stores the comment `input`, and returns it. The owner is named in
// the body, so a missing or deleted owner is a bad reference.
pub fn (s Service) create(input comment_models.CommentInput) !comment_models.CommentView {
	if input.user_slug == '' {
		return missing_user()
	}
	if input.owner_type == '' || input.owner_slug == '' {
		return app.ValidationError{
			message: 'a comment needs an `owner_type` and an `owner_slug`'
		}
	}
	owner := s.owner(input.owner_type)!
	owner_id := owner.id_of(input.owner_slug) or {
		if err is app.NotFoundError {
			return app.BadReferenceError{
				message: '${input.owner_type} `${input.owner_slug}` not found'
			}
		}
		return err
	}
	return s.insert(input.owner_type, owner_id, input.user_slug, input.parent_slug, input.body)
}

// create_on stores the comment `input` on the record of the type
// `owner_type` with the slug `owner_slug`, and returns it. The owner is named
// in the path, so a missing or deleted owner gives a `NotFoundError`.
pub fn (s Service) create_on(owner_type string, owner_slug string, input comment_models.OwnedCommentInput) !comment_models.CommentView {
	owner := s.owner(owner_type)!
	owner_id := owner.id_of(owner_slug)!
	if input.user_slug == '' {
		return missing_user()
	}
	return s.insert(owner_type, owner_id, input.user_slug, input.parent_slug, input.body)
}

// list_by_user returns the comments by the user with the id `user_id`,
// oldest first.
pub fn (s Service) list_by_user(user_id int) ![]comment_models.CommentView {
	return s.views(s.store.find_by_user(user_id)!)
}

// insert stores a comment by the user `user_slug` on the record of the type
// `owner_type` with the id `owner_id`, which the caller has checked.
fn (s Service) insert(owner_type string, owner_id int, user_slug string, parent_slug string, body string) !comment_models.CommentView {
	user_id := s.users.reference_id(user_slug)!
	comment := s.store.insert(
		user_id:     user_id
		owner_type:  owner_type
		owner_id:    owner_id
		parent_slug: parent_slug
		body:        body
	)!
	return s.view(comment)
}

// view returns `comment` as the API returns it.
pub fn (s Service) view(comment comment_models.Comment) !comment_models.CommentView {
	return s.views([comment])![0]
}

// views returns `list` as the API returns it. It loads the authors, the
// parents and the owners of each type in one query each, not one per comment.
pub fn (s Service) views(list []comment_models.Comment) ![]comment_models.CommentView {
	nodes := s.graph.comments().with_author().with_parent().with_article().with_post().nodes(list)!
	mut views := []comment_models.CommentView{cap: list.len}
	for n in nodes {
		owner := if a := n.article {
			a.article.slug
		} else if p := n.post {
			p.post.slug
		} else {
			''
		}
		views << n.comment.view(
			user:   if u := n.author { u.user.slug } else { '' }
			owner:  owner
			parent: if n.comment.parent_id != none {
				if p := n.parent { p.comment.slug } else { '' }
			} else {
				none
			}
		)
	}
	return views
}

// owner returns the kind of record named by `owner_type`.
fn (s Service) owner(owner_type string) !Owner {
	return s.owners[owner_type] or {
		mut known := s.owners.keys()
		known.sort()
		return app.ValidationError{
			message: '`owner_type` must be one of: ${known.join(', ')}'
		}
	}
}

fn missing_user() IError {
	return app.ValidationError{
		message: 'a comment needs a `user_slug`'
	}
}
