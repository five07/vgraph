// Package models holds the example's users and posts, with the rules of who
// may read and write what: privacy policies decide whether an operation runs
// at all, and hooks change a write by who makes it. Each gets the request's
// viewer (`auth.Viewer`) as its context.
module models

import orm
import time
import five07.vgraph
import five07.vgraph.graphql
import five07.vgraph.load
import auth

// User can log in with their email and password. An admin may do anything.
@[table: 'users']
pub struct User {
pub:
	id         i64 @[primary; sql: serial]
	name       string
	email      string
	password   string
	admin      bool
	created_at time.Time
}

// edges declares a user's posts.
pub fn (u User) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'posts'
			kind:   .one_to_many
			to:     'posts'
			column: 'author_id'
		},
	]
}

// fields makes the email and the password hash `sensitive`, so GraphQL never
// returns them, though the inputs take them, and makes an account a member
// unless an admin says otherwise.
pub fn (u User) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:      'name'
			not_empty: true
			max_len:   100
		},
		vgraph.Field{
			name:      'email'
			unique:    true
			sensitive: true
			pattern:   r'^[^@\s]+@[^@\s]+$'
		},
		vgraph.Field{
			name:      'password'
			sensitive: true
		},
		vgraph.Field{
			name:    'admin'
			default: fn () orm.Primitive {
				return false
			}
		},
		vgraph.Field{
			name:            'created_at'
			default_now:     true
			immutable:       true
			graphql_skip_in: [.create_input]
		},
	]
}

// hooks hashes a new password, and lets only an admin grant or take away
// `admin`: the same write runs for an admin and fails for a member.
pub fn (u User) hooks() []vgraph.Hook {
	return [hash_password, admin_only]
}

// hash_password replaces the password a write sets with its bcrypt hash,
// after checking its length, which the field's own checks can't: they run
// after the hooks, on the hash.
const hash_password = vgraph.Hook{
	name: 'hash_password'
	on:   [.create, .update_one, .update]
	run:  fn (next vgraph.Mutate) vgraph.Mutate {
		return fn [next] (ctx graphql.Context, mut m vgraph.Mutation) ! {
			if value := m.field_value('password') {
				password := if value is string { value } else { '' }
				if password.len < 8 {
					return vgraph.ValidationError{
						table:   'users'
						field:   'password'
						message: 'is shorter than 8 bytes'
					}
				}
				m.set_field_value('password', auth.hash_password(password)!)
			}
			next(ctx, mut m)!
		}
	}
}

// admin_only refuses a write that sets `admin` to true, or changes it on an
// update, unless the viewer is an admin.
const admin_only = vgraph.Hook{
	name: 'admin_only'
	run:  fn (next vgraph.Mutate) vgraph.Mutate {
		return fn [next] (ctx graphql.Context, mut m vgraph.Mutation) ! {
			if value := m.field_value('admin') {
				granting := value is bool && value
				if (granting || m.operation() != .create) && !auth.viewer_of(ctx).admin {
					return vgraph.ValidationError{
						table:   'users'
						field:   'admin'
						message: 'only an admin can change it'
					}
				}
			}
			next(ctx, mut m)!
		}
	}
}

// policy lets anyone sign up, a user update their own account, and an admin
// do anything; reading users is open to all.
pub fn (u User) policy() vgraph.Policy {
	return vgraph.Policy{
		mutation: [allow_admin, user_writes, vgraph.always_deny]
	}
}

fn user_writes(ctx graphql.Context, m vgraph.Mutation) !vgraph.Decision {
	viewer := auth.viewer_of(ctx)
	return match m.operation() {
		.create { .allow }
		.update_one {
			if !viewer.anonymous() && m.key() == viewer.id.str() { .allow } else { .deny }
		}
		else { .deny }
	}
}

// Post is a post by a user: a draft until it has a `published_at`.
@[table: 'posts']
pub struct Post {
pub:
	id           i64 @[primary; sql: serial]
	author_id    i64
	title        string
	body         string
	published_at ?time.Time
	created_at   time.Time
}

// edges declares a post's author, which doesn't change.
pub fn (p Post) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:      'author'
			kind:      .many_to_one
			to:        'users'
			column:    'author_id'
			immutable: true
		},
	]
}

// fields checks a post's title, and gives `author_id` a placeholder default,
// so the create input doesn't require it: the `set_author` hook decides it.
pub fn (p Post) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:      'title'
			not_empty: true
			max_len:   200
		},
		vgraph.Field{
			name:    'author_id'
			default: fn () orm.Primitive {
				return i64(0)
			}
		},
		vgraph.Field{
			name:            'created_at'
			default_now:     true
			immutable:       true
			graphql_skip_in: [.create_input]
		},
	]
}

// hooks sets a new post's author by who writes it.
pub fn (p Post) hooks() []vgraph.Hook {
	return [set_author]
}

// set_author makes a member the author of the posts they create, and refuses
// another author; an admin may post as anyone, and is the author when the
// create names none.
const set_author = vgraph.Hook{
	name: 'set_author'
	on:   [.create]
	run:  fn (next vgraph.Mutate) vgraph.Mutate {
		return fn [next] (ctx graphql.Context, mut m vgraph.Mutation) ! {
			viewer := auth.viewer_of(ctx)
			value := m.field_value('author_id') or { orm.Primitive(i64(0)) }
			author := if value is i64 { value } else { i64(0) }
			if author == 0 {
				m.set_field_value('author_id', viewer.id)
			} else if author != viewer.id && !viewer.admin {
				return vgraph.ValidationError{
					table:   'posts'
					field:   'author_id'
					message: 'only an admin can post as another user'
				}
			}
			next(ctx, mut m)!
		}
	}
}

// policy lets anyone read published posts, a member their own drafts too, and
// an admin everything. Only a logged-in user writes; who may change which
// post is the app's `owner_only` rule, which reads the posts.
pub fn (p Post) policy() vgraph.Policy {
	return vgraph.Policy{
		query:    [visible_posts]
		mutation: [allow_admin, deny_anonymous]
	}
}

fn visible_posts(ctx graphql.Context, _ string, mut q load.Query) !vgraph.Decision {
	viewer := auth.viewer_of(ctx)
	if viewer.admin {
		return .allow
	}
	q.conds << if viewer.anonymous() {
		load.is_not_null('published_at')
	} else {
		load.or(load.is_not_null('published_at'), load.eq('author_id', viewer.id))
	}
	return .skip
}

// allow_admin lets an admin make any write.
fn allow_admin(ctx graphql.Context, _ vgraph.Mutation) !vgraph.Decision {
	return if auth.viewer_of(ctx).admin { .allow } else { .skip }
}

fn deny_anonymous(ctx graphql.Context, _ vgraph.Mutation) !vgraph.Decision {
	return if auth.viewer_of(ctx).anonymous() { .deny } else { .skip }
}

// graphql makes lists of posts Relay connections.
pub fn (p Post) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		relay: true
	}
}
