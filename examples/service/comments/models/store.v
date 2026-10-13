module models

import orm
import time
import app

// CommentStore reads and writes `Comment` rows through any ORM adapter.
// Deleting a comment only marks it deleted: every method treats a deleted
// comment as missing. Its replies are kept, and still show its slug: see
// `vgraph/load`.
pub struct CommentStore {
	db orm.Connection
}

// CommentStore.new returns a store that uses the connection `db`.
pub fn CommentStore.new(db orm.Connection) CommentStore {
	return CommentStore{
		db: db
	}
}

// find_all returns every comment, oldest first.
pub fn (s CommentStore) find_all() ![]Comment {
	return sql s.db {
		select from Comment where deleted_at is none order by id
	}!
}

// find_by_owner returns the comments on the record of the type `type_name`
// with the id `record_id`, oldest first.
pub fn (s CommentStore) find_by_owner(type_name string, record_id int) ![]Comment {
	return sql s.db {
		select from Comment where owner_type == type_name && owner_id == record_id
		&& deleted_at is none order by id
	}!
}

// find_by_user returns the comments by the user with the id `author_id`, oldest
// first.
pub fn (s CommentStore) find_by_user(author_id int) ![]Comment {
	return sql s.db {
		select from Comment where user_id == author_id && deleted_at is none order by id
	}!
}

// find returns the comment with the slug `comment_slug`.
pub fn (s CommentStore) find(comment_slug string) !Comment {
	if !app.valid_slug(comment_slug) {
		return not_found()
	}
	rows := sql s.db {
		select from Comment where slug == comment_slug && deleted_at is none limit 1
	}!
	if rows.len == 0 {
		return not_found()
	}
	return rows[0]
}

// insert validates and stores the comment `new`, and returns it. Its parent,
// when it has one, must be a comment on the same owner.
pub fn (s CommentStore) insert(new NewComment) !Comment {
	fields := CommentUpdate{
		body: new.body
	}
	fields.validate() or {
		return app.ValidationError{
			message: err.msg()
		}
	}
	parent_id := s.parent_id(new)!
	now := time.now()
	comment := Comment{
		slug:       app.new_slug()
		user_id:    new.user_id
		owner_type: new.owner_type
		owner_id:   new.owner_id
		parent_id:  if parent_id > 0 { ?int(parent_id) } else { none }
		body:       new.body
		created_at: now
		updated_at: now
	}
	sql s.db {
		insert comment into Comment
	} or { return write_error(err) }
	// Read back by slug, not by the id the insert returns, which another
	// thread's insert can change (see `UserStore.insert`).
	return s.find(comment.slug)
}

// replace sets every writable field of the comment with the slug
// `comment_slug` from `fields`, and returns the comment.
pub fn (s CommentStore) replace(comment_slug string, fields CommentUpdate) !Comment {
	comment := s.find(comment_slug)!
	fields.validate() or {
		return app.ValidationError{
			message: err.msg()
		}
	}
	now := time.now()
	sql s.db {
		update Comment set body = fields.body, updated_at = now where id == comment.id
	} or { return write_error(err) }
	return s.find_by_id(comment.id)
}

// patch sets the fields that `patch` has on the comment with the slug
// `comment_slug`, and returns the comment.
pub fn (s CommentStore) patch(comment_slug string, patch CommentPatch) !Comment {
	comment := s.find(comment_slug)!
	return s.replace(comment_slug, CommentUpdate{
		body: patch.body or { comment.body }
	})
}

// soft_delete marks the comment with the slug `comment_slug` deleted.
pub fn (s CommentStore) soft_delete(comment_slug string) ! {
	comment := s.find(comment_slug)!
	now := time.now()
	sql s.db {
		update Comment set deleted_at = now where id == comment.id
	}!
}

// parent_id returns the id of the comment that `new` answers, or 0 when it
// answers none. The parent must exist, and be on the same owner.
fn (s CommentStore) parent_id(new NewComment) !int {
	if new.parent_slug == '' {
		return 0
	}
	parent := s.find(new.parent_slug) or {
		if err is app.NotFoundError {
			return app.BadReferenceError{
				message: 'parent comment `${new.parent_slug}` not found'
			}
		}
		return err
	}
	if parent.owner_type != new.owner_type || parent.owner_id != new.owner_id {
		return app.ValidationError{
			message: 'a reply must be on the same ${new.owner_type} as its parent comment'
		}
	}
	return parent.id
}

// find_by_id returns the comment with the id `comment_id`, deleted or not.
fn (s CommentStore) find_by_id(comment_id int) !Comment {
	rows := sql s.db {
		select from Comment where id == comment_id limit 1
	}!
	if rows.len == 0 {
		return not_found()
	}
	return rows[0]
}

// write_error turns the database error `err`, from writing a comment, into an
// error fit for clients.
fn write_error(err IError) IError {
	if kind := app.constraint(err) {
		if kind == .foreign_key {
			return app.BadReferenceError{
				message: 'user or parent comment not found'
			}
		}
	}
	return err
}

fn not_found() IError {
	return app.NotFoundError{
		message: 'comment not found'
	}
}
