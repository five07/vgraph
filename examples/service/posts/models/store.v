module models

import orm
import time
import app

// PostStore reads and writes `Post` rows through any ORM adapter. Deleting a
// post only marks it deleted: every method treats a deleted post as missing.
// Records that refer to it still show its slug: see `vgraph/load`.
pub struct PostStore {
	db orm.Connection
}

// PostStore.new returns a store that uses the connection `db`.
pub fn PostStore.new(db orm.Connection) PostStore {
	return PostStore{
		db: db
	}
}

// find_all returns every post, oldest first.
pub fn (s PostStore) find_all() ![]Post {
	return sql s.db {
		select from Post where deleted_at is none order by id
	}!
}

// find_by_user returns the posts by the user with the id `author_id`, oldest
// first.
pub fn (s PostStore) find_by_user(author_id int) ![]Post {
	return sql s.db {
		select from Post where user_id == author_id && deleted_at is none order by id
	}!
}

// find returns the post with the slug `post_slug`.
pub fn (s PostStore) find(post_slug string) !Post {
	if !app.valid_slug(post_slug) {
		return not_found()
	}
	rows := sql s.db {
		select from Post where slug == post_slug && deleted_at is none limit 1
	}!
	if rows.len == 0 {
		return not_found()
	}
	return rows[0]
}

// id_of returns the id of the post with the slug `post_slug`, for records
// that refer to a post.
pub fn (s PostStore) id_of(post_slug string) !int {
	return s.find(post_slug)!.id
}

// insert validates and stores a new post by the user with the id `user_id`,
// and returns it.
pub fn (s PostStore) insert(user_id int, fields PostUpdate) !Post {
	fields.validate() or {
		return app.ValidationError{
			message: err.msg()
		}
	}
	now := time.now()
	post := Post{
		slug:       app.new_slug()
		user_id:    user_id
		body:       fields.body
		created_at: now
		updated_at: now
	}
	sql s.db {
		insert post into Post
	} or { return write_error(err) }
	// Read back by slug, not by the id the insert returns, which another
	// thread's insert can change (see `UserStore.insert`).
	return s.find(post.slug)
}

// replace sets every writable field of the post with the slug `post_slug`
// from `fields`, and returns the post.
pub fn (s PostStore) replace(post_slug string, fields PostUpdate) !Post {
	post := s.find(post_slug)!
	fields.validate() or {
		return app.ValidationError{
			message: err.msg()
		}
	}
	now := time.now()
	// Don't name a variable `update` here: inside `sql` it is read as the
	// keyword, and the write silently does nothing.
	sql s.db {
		update Post set body = fields.body, updated_at = now where id == post.id
	} or { return write_error(err) }
	return s.find_by_id(post.id)
}

// patch sets the fields that `patch` has on the post with the slug
// `post_slug`, and returns the post.
pub fn (s PostStore) patch(post_slug string, patch PostPatch) !Post {
	post := s.find(post_slug)!
	return s.replace(post_slug, PostUpdate{
		body: patch.body or { post.body }
	})
}

// soft_delete marks the post with the slug `post_slug` deleted.
pub fn (s PostStore) soft_delete(post_slug string) ! {
	post := s.find(post_slug)!
	now := time.now()
	sql s.db {
		update Post set deleted_at = now where id == post.id
	}!
}

// find_by_id returns the post with the id `post_id`, deleted or not.
fn (s PostStore) find_by_id(post_id int) !Post {
	rows := sql s.db {
		select from Post where id == post_id limit 1
	}!
	if rows.len == 0 {
		return not_found()
	}
	return rows[0]
}

// write_error turns the database error `err`, from writing a post, into an
// error fit for clients.
fn write_error(err IError) IError {
	if kind := app.constraint(err) {
		if kind == .foreign_key {
			return app.BadReferenceError{
				message: 'user not found'
			}
		}
	}
	return err
}

fn not_found() IError {
	return app.NotFoundError{
		message: 'post not found'
	}
}
