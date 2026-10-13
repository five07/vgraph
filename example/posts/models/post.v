module models

import orm
import time

const max_body_len = 2_000

// Post is a short piece of writing by a user, like a status update.
@[table: 'posts']
pub struct Post {
pub:
	id   int    @[primary; sql: serial]
	slug string @[unique]
	// `sql_type` adds the NOT NULL that the ORM leaves off `references` columns.
	user_id    int @[references: 'users(id)'; sql_type: 'INTEGER NOT NULL']
	body       string
	created_at time.Time
	updated_at time.Time
	deleted_at ?time.Time
}

// PostInput is the body of `POST /posts`. `user_slug` names the author, and
// can't be changed afterwards.
pub struct PostInput {
pub:
	user_slug string
	body      string
}

// fields returns the writable fields of `input`, without its author.
pub fn (input PostInput) fields() PostUpdate {
	return PostUpdate{
		body: input.body
	}
}

// PostUpdate is the body of `PUT /posts/:slug`: every writable field.
pub struct PostUpdate {
pub:
	body string
}

// PostPatch is the body of `PATCH /posts/:slug`: only the fields it has are
// changed.
pub struct PostPatch {
pub:
	body ?string
}

// PostView is a post as the API returns it.
pub struct PostView {
pub:
	slug       string
	user_slug  string
	body       string
	created_at string
	updated_at string
}

// view returns `p` as the API returns it; `user_slug` is the slug of its author.
pub fn (p Post) view(user_slug string) PostView {
	return PostView{
		slug:       p.slug
		user_slug:  user_slug
		body:       p.body
		created_at: p.created_at.format_rfc3339()
		updated_at: p.updated_at.format_rfc3339()
	}
}

// validate checks that `fields` can be stored.
fn (fields PostUpdate) validate() ! {
	if fields.body.trim_space() == '' {
		return error('a post needs a body')
	}
	if fields.body.len > max_body_len {
		return error('the body is longer than ${max_body_len} bytes')
	}
}

// create_tables creates the tables of this module's models. The `users`
// table has to exist first.
pub fn create_tables(db orm.Connection) ! {
	sql db {
		create table Post
	}!
}
