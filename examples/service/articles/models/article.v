module models

import orm
import time
import five07.vgraph

const max_title_len = 200
const max_summary_len = 500
const max_body_len = 20_000

// Article is a long-form piece of writing by a user.
@[table: 'articles']
pub struct Article {
pub:
	id   int    @[primary; sql: serial]
	slug string @[unique]
	// `sql_type` adds the NOT NULL that the ORM leaves off `references` columns.
	user_id      int @[references: 'users(id)'; sql_type: 'INTEGER NOT NULL']
	title        string
	summary      string
	body         string
	published_at ?time.Time
	created_at   time.Time
	updated_at   time.Time
	deleted_at   ?time.Time
}

// edges declares an article's author, deleted or not, and its comments, deleted ones left
// out.
pub fn (a Article) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'author'
			kind:   .many_to_one
			to:     'users'
			column: 'user_id'
		},
		vgraph.Edge{
			name:     'comments'
			kind:     .one_to_many
			to:       'comments'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Article'
			soft_del: 'deleted_at'
		},
	]
}

// ArticleInput is the body of `POST /articles`. `user_slug` names the author,
// and can't be changed afterwards.
pub struct ArticleInput {
pub:
	user_slug string
	title     string
	summary   string
	body      string
	published bool
}

// fields returns the writable fields of `input`, without its author.
pub fn (input ArticleInput) fields() ArticleUpdate {
	return ArticleUpdate{
		title:     input.title
		summary:   input.summary
		body:      input.body
		published: input.published
	}
}

// ArticleUpdate is the body of `PUT /articles/:slug`: every writable field.
pub struct ArticleUpdate {
pub:
	title     string
	summary   string
	body      string
	published bool
}

// ArticlePatch is the body of `PATCH /articles/:slug`: only the fields it has
// are changed.
pub struct ArticlePatch {
pub:
	title     ?string
	summary   ?string
	body      ?string
	published ?bool
}

// ArticleView is an article as the API returns it. `published_at` is left out
// while the article is unpublished.
pub struct ArticleView {
pub:
	slug         string
	user_slug    string
	title        string
	summary      string
	body         string
	published_at ?string
	created_at   string
	updated_at   string
}

// view returns `a` as the API returns it; `user_slug` is the slug of its author.
pub fn (a Article) view(user_slug string) ArticleView {
	return ArticleView{
		slug:         a.slug
		user_slug:    user_slug
		title:        a.title
		summary:      a.summary
		body:         a.body
		published_at: if t := a.published_at { t.format_rfc3339() } else { none }
		created_at:   a.created_at.format_rfc3339()
		updated_at:   a.updated_at.format_rfc3339()
	}
}

// normalized returns `fields` with its title and summary trimmed.
fn (fields ArticleUpdate) normalized() ArticleUpdate {
	return ArticleUpdate{
		...fields
		title:   fields.title.trim_space()
		summary: fields.summary.trim_space()
	}
}

// validate checks that `fields` can be stored. It expects normalized fields.
fn (fields ArticleUpdate) validate() ! {
	if fields.title == '' {
		return error('an article needs a title')
	}
	if fields.title.len > max_title_len {
		return error('the title is longer than ${max_title_len} bytes')
	}
	if fields.summary.len > max_summary_len {
		return error('the summary is longer than ${max_summary_len} bytes')
	}
	if fields.body.trim_space() == '' {
		return error('an article needs a body')
	}
	if fields.body.len > max_body_len {
		return error('the body is longer than ${max_body_len} bytes')
	}
}

// create_tables creates the tables of this module's models. The `users`
// table has to exist first.
pub fn create_tables(db orm.Connection) ! {
	sql db {
		create table Article
	}!
}
