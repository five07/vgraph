module models

import time
import five07.vgraph

const max_name_len = 100
const max_email_len = 254

// User is someone who writes articles, posts and comments.
@[table: 'users']
pub struct User {
pub:
	id         int    @[primary; sql: serial]
	slug       string @[unique]
	name       string
	email      string @[unique]
	created_at time.Time
	updated_at time.Time
	deleted_at ?time.Time
}

// edges declares a user's articles, posts and comments, deleted ones left out.
pub fn (u User) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:     'articles'
			kind:     .one_to_many
			to:       'articles'
			column:   'user_id'
			soft_del: 'deleted_at'
		},
		vgraph.Edge{
			name:     'posts'
			kind:     .one_to_many
			to:       'posts'
			column:   'user_id'
			soft_del: 'deleted_at'
		},
		vgraph.Edge{
			name:     'comments'
			kind:     .one_to_many
			to:       'comments'
			column:   'user_id'
			soft_del: 'deleted_at'
		},
	]
}

// UserInput is the body of `POST /users` and `PUT /users/:slug`.
pub struct UserInput {
pub:
	name  string
	email string
}

// UserPatch is the body of `PATCH /users/:slug`: only the fields it has are
// changed.
pub struct UserPatch {
pub:
	name  ?string
	email ?string
}

// UserView is a user as the API returns it.
pub struct UserView {
pub:
	slug       string
	name       string
	email      string
	created_at string
	updated_at string
}

// view returns `u` as the API returns it.
pub fn (u User) view() UserView {
	return UserView{
		slug:       u.slug
		name:       u.name
		email:      u.email
		created_at: u.created_at.format_rfc3339()
		updated_at: u.updated_at.format_rfc3339()
	}
}

// normalized returns `input` with its name trimmed, and its email trimmed and
// lowercased, so that emails differing only in case count as the same.
fn (input UserInput) normalized() UserInput {
	return UserInput{
		name:  input.name.trim_space()
		email: input.email.trim_space().to_lower()
	}
}

// validate checks that `input` can be stored. It expects a normalized input.
fn (input UserInput) validate() ! {
	if input.name == '' {
		return error('a user needs a name')
	}
	if input.name.len > max_name_len {
		return error('the name is longer than ${max_name_len} bytes')
	}
	if input.email == '' {
		return error('a user needs an email')
	}
	if !input.email.contains('@') {
		return error('the email needs an `@`')
	}
	if input.email.len > max_email_len {
		return error('the email is longer than ${max_email_len} bytes')
	}
}
