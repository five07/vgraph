module models

import orm
import time
import app

// ArticleStore reads and writes `Article` rows through any ORM adapter.
// Deleting an article only marks it deleted: every method treats a deleted
// article as missing. Records that refer to it still show its slug: see
// `vgraph/load`.
pub struct ArticleStore {
	db orm.Connection
}

// ArticleStore.new returns a store that uses the connection `db`.
pub fn ArticleStore.new(db orm.Connection) ArticleStore {
	return ArticleStore{
		db: db
	}
}

// find_all returns every article, oldest first.
pub fn (s ArticleStore) find_all() ![]Article {
	return sql s.db {
		select from Article where deleted_at is none order by id
	}!
}

// find_by_user returns the articles by the user with the id `author_id`, oldest
// first.
pub fn (s ArticleStore) find_by_user(author_id int) ![]Article {
	return sql s.db {
		select from Article where user_id == author_id && deleted_at is none order by id
	}!
}

// find returns the article with the slug `article_slug`.
pub fn (s ArticleStore) find(article_slug string) !Article {
	if !app.valid_slug(article_slug) {
		return not_found()
	}
	rows := sql s.db {
		select from Article where slug == article_slug && deleted_at is none limit 1
	}!
	if rows.len == 0 {
		return not_found()
	}
	return rows[0]
}

// id_of returns the id of the article with the slug `article_slug`, for
// records that refer to an article.
pub fn (s ArticleStore) id_of(article_slug string) !int {
	return s.find(article_slug)!.id
}

// insert validates and stores a new article by the user with the id
// `user_id`, and returns it.
pub fn (s ArticleStore) insert(user_id int, fields ArticleUpdate) !Article {
	clean := fields.normalized()
	clean.validate() or {
		return app.ValidationError{
			message: err.msg()
		}
	}
	now := time.now()
	article := Article{
		slug:         app.new_slug()
		user_id:      user_id
		title:        clean.title
		summary:      clean.summary
		body:         clean.body
		published_at: if clean.published { ?time.Time(now) } else { none }
		created_at:   now
		updated_at:   now
	}
	sql s.db {
		insert article into Article
	} or { return write_error(err) }
	// Read back by slug, not by the id the insert returns, which another
	// thread's insert can change (see `UserStore.insert`).
	return s.find(article.slug)
}

// replace sets every writable field of the article with the slug
// `article_slug` from `fields`, and returns the article. Publishing keeps the
// first publication time; unpublishing clears it.
pub fn (s ArticleStore) replace(article_slug string, fields ArticleUpdate) !Article {
	article := s.find(article_slug)!
	clean := fields.normalized()
	clean.validate() or {
		return app.ValidationError{
			message: err.msg()
		}
	}
	now := time.now()
	mut published_at := ?time.Time(none)
	if clean.published {
		published_at = article.published_at or { now }
	}
	sql s.db {
		update Article set title = clean.title, summary = clean.summary, body = clean.body,
		published_at = published_at, updated_at = now where id == article.id
	} or { return write_error(err) }
	return s.find_by_id(article.id)
}

// patch sets the fields that `patch` has on the article with the slug
// `article_slug`, and returns the article.
pub fn (s ArticleStore) patch(article_slug string, patch ArticlePatch) !Article {
	article := s.find(article_slug)!
	return s.replace(article_slug, ArticleUpdate{
		title:     patch.title or { article.title }
		summary:   patch.summary or { article.summary }
		body:      patch.body or { article.body }
		published: patch.published or { article.published_at != none }
	})
}

// soft_delete marks the article with the slug `article_slug` deleted.
pub fn (s ArticleStore) soft_delete(article_slug string) ! {
	article := s.find(article_slug)!
	now := time.now()
	sql s.db {
		update Article set deleted_at = now where id == article.id
	}!
}

// find_by_id returns the article with the id `article_id`, deleted or not.
fn (s ArticleStore) find_by_id(article_id int) !Article {
	rows := sql s.db {
		select from Article where id == article_id limit 1
	}!
	if rows.len == 0 {
		return not_found()
	}
	return rows[0]
}

// write_error turns the database error `err`, from writing an article, into
// an error fit for clients.
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
		message: 'article not found'
	}
}
