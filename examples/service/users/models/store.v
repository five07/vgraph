module models

import orm
import time
import app

// UserStore reads and writes `User` rows through any ORM adapter. Deleting a
// user only marks it deleted: every method treats a deleted user as missing.
// Records that refer to it still show its slug: see `vgraph/load`.
pub struct UserStore {
	db orm.Connection
}

// UserStore.new returns a store that uses the connection `db`.
pub fn UserStore.new(db orm.Connection) UserStore {
	return UserStore{
		db: db
	}
}

// find_all returns every user, oldest first.
pub fn (s UserStore) find_all() ![]User {
	return sql s.db {
		select from User where deleted_at is none order by id
	}!
}

// count_all returns how many users there are, deleted ones included.
pub fn (s UserStore) count_all() !int {
	return sql s.db {
		select count from User
	}!
}

// find returns the user with the slug `user_slug`.
pub fn (s UserStore) find(user_slug string) !User {
	if !app.valid_slug(user_slug) {
		return not_found()
	}
	rows := sql s.db {
		select from User where slug == user_slug && deleted_at is none limit 1
	}!
	if rows.len == 0 {
		return not_found()
	}
	return rows[0]
}

// id_of returns the id of the user with the slug `slug`, for records that
// refer to a user.
pub fn (s UserStore) id_of(slug string) !int {
	return s.find(slug)!.id
}

// reference_id returns the id of the user with the slug `user_slug`, for a
// record about to refer to them. A missing or deleted user is the client's
// mistake in the body, so it gives a `BadReferenceError`, not a 404.
pub fn (s UserStore) reference_id(user_slug string) !int {
	return s.id_of(user_slug) or {
		if err is app.NotFoundError {
			return app.BadReferenceError{
				message: 'user `${user_slug}` not found'
			}
		}
		return err
	}
}

// insert validates and stores a new user, and returns it.
pub fn (s UserStore) insert(input UserInput) !User {
	clean := input.normalized()
	clean.validate() or {
		return app.ValidationError{
			message: err.msg()
		}
	}
	now := time.now()
	user := User{
		slug:       app.new_slug()
		name:       clean.name
		email:      clean.email
		created_at: now
		updated_at: now
	}
	sql s.db {
		insert user into User
	} or { return s.write_error(err, clean.email) }
	// Read back by slug, not by the id the insert returns: the ORM gets that
	// id from `last_insert_rowid()` in a separate call, which another thread's
	// insert on the shared connection can change in between.
	return s.find(user.slug)
}

// replace sets every field of the user with the slug `slug` from `input`, and
// returns the user.
pub fn (s UserStore) replace(slug string, input UserInput) !User {
	user := s.find(slug)!
	clean := input.normalized()
	clean.validate() or {
		return app.ValidationError{
			message: err.msg()
		}
	}
	now := time.now()
	sql s.db {
		update User set name = clean.name, email = clean.email, updated_at = now
		where id == user.id
	} or { return s.write_error(err, clean.email) }
	return s.find_by_id(user.id)
}

// patch sets the fields that `patch` has on the user with the slug `slug`,
// and returns the user.
pub fn (s UserStore) patch(slug string, patch UserPatch) !User {
	user := s.find(slug)!
	return s.replace(slug, UserInput{
		name:  patch.name or { user.name }
		email: patch.email or { user.email }
	})
}

// soft_delete marks the user with the slug `slug` deleted.
pub fn (s UserStore) soft_delete(slug string) ! {
	user := s.find(slug)!
	now := time.now()
	sql s.db {
		update User set deleted_at = now where id == user.id
	}!
}

// find_by_id returns the user with the id `user_id`, deleted or not.
fn (s UserStore) find_by_id(user_id int) !User {
	rows := sql s.db {
		select from User where id == user_id limit 1
	}!
	if rows.len == 0 {
		return not_found()
	}
	return rows[0]
}

// write_error turns the database error `err`, from writing a user with the
// email `email`, into an error fit for clients.
fn (s UserStore) write_error(err IError, email string) IError {
	if kind := app.constraint(err) {
		if kind == .unique {
			return app.ConflictError{
				message: 'the email `${email}` is already taken'
			}
		}
	}
	return err
}

fn not_found() IError {
	return app.NotFoundError{
		message: 'user not found'
	}
}
