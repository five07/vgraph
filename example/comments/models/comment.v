module models

import orm
import time

const max_body_len = 5_000

// Comment is a comment by a user on another record, its owner: `owner_type`
// is the owner's struct name (`'Article'`, `'Post'`), and `owner_id` its id.
// The owner can be in any table, so the database can't check it with a
// foreign key; the API checks it before writing. A reply has the id of the
// comment it answers in `parent_id`, which must have the same owner.
@[table: 'comments']
pub struct Comment {
pub:
	id   int    @[primary; sql: serial]
	slug string @[unique]
	// `sql_type` adds the NOT NULL that the ORM leaves off `references` columns.
	user_id    int @[references: 'users(id)'; sql_type: 'INTEGER NOT NULL']
	owner_type string
	owner_id   int
	parent_id  ?int @[references: 'comments(id)']
	body       string
	created_at time.Time
	updated_at time.Time
	deleted_at ?time.Time
}

// owner_type returns what comments on a `T` store as their `owner_type`: the
// struct name of `T`, without its module (`Article`).
pub fn owner_type[T]() string {
	return T.name.all_after_last('.')
}

// CommentInput is the body of `POST /comments`. `owner_type` and `owner_slug`
// name the record commented on; `parent_slug`, when set, names the comment
// answered. None of these, nor `user_slug`, can be changed afterwards.
pub struct CommentInput {
pub:
	user_slug   string
	owner_type  string
	owner_slug  string
	parent_slug string
	body        string
}

// OwnedCommentInput is the body of `POST /articles/:slug/comments` and
// `POST /posts/:slug/comments`: a comment whose owner the path names.
pub struct OwnedCommentInput {
pub:
	user_slug   string
	parent_slug string
	body        string
}

// NewComment is a comment about to be stored, with its references resolved
// to ids, apart from the parent, which the store resolves itself.
pub struct NewComment {
pub:
	user_id     int
	owner_type  string
	owner_id    int
	parent_slug string
	body        string
}

// CommentUpdate is the body of `PUT /comments/:slug`: every writable field.
pub struct CommentUpdate {
pub:
	body string
}

// CommentPatch is the body of `PATCH /comments/:slug`: only the fields it has
// are changed.
pub struct CommentPatch {
pub:
	body ?string
}

// CommentView is a comment as the API returns it. `parent_slug` is left out
// of a comment that isn't a reply.
pub struct CommentView {
pub:
	slug        string
	user_slug   string
	owner_type  string
	owner_slug  string
	parent_slug ?string
	body        string
	created_at  string
	updated_at  string
}

// Slugs are the slugs a comment's view shows in place of its ids.
pub struct Slugs {
pub:
	user   string
	owner  string
	parent ?string
}

// view returns `c` as the API returns it, with the slugs of the records it
// refers to.
pub fn (c Comment) view(slugs Slugs) CommentView {
	return CommentView{
		slug:        c.slug
		user_slug:   slugs.user
		owner_type:  c.owner_type
		owner_slug:  slugs.owner
		parent_slug: slugs.parent
		body:        c.body
		created_at:  c.created_at.format_rfc3339()
		updated_at:  c.updated_at.format_rfc3339()
	}
}

// validate checks that `fields` can be stored.
fn (fields CommentUpdate) validate() ! {
	if fields.body.trim_space() == '' {
		return error('a comment needs a body')
	}
	if fields.body.len > max_body_len {
		return error('the body is longer than ${max_body_len} bytes')
	}
}

// create_tables creates the tables of this module's models, and the index
// that finds the comments on a record. The `users` table has to exist first.
pub fn create_tables(db orm.Connection) ! {
	sql db {
		create table Comment
	}!
	// Not the ORM's `@[index]`: for SQLite it puts CREATE INDEX after CREATE
	// TABLE in one string, and SQLite runs only the first statement of it.
	mut conn := db
	conn.execute('CREATE INDEX IF NOT EXISTS idx_comments_owner ON comments (owner_type, owner_id)')!
}
