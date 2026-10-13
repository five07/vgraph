module models

import db.sqlite
import time
import app
import users.models as user_models

struct Fixture {
	db      sqlite.DB
	store   ArticleStore
	users   user_models.UserStore
	user_id int
}

fn setup() !Fixture {
	db := app.connect(app.Config{})!
	sql db {
		create table user_models.User
		create table Article
	}!
	users := user_models.UserStore.new(db)
	user := users.insert(name: 'Ada', email: 'ada@x')!
	return Fixture{
		db:      db
		store:   ArticleStore.new(db)
		users:   users
		user_id: user.id
	}
}

fn test_insert_and_find() {
	f := setup()!
	a := f.store.insert(f.user_id, title: ' Hello ', summary: ' short ', body: 'V is great.')!
	assert app.valid_slug(a.slug)
	assert a.user_id == f.user_id
	assert a.title == 'Hello'
	assert a.summary == 'short'
	assert a.body == 'V is great.'
	assert a.published_at == none
	assert f.store.find(a.slug)! == a
	assert f.store.id_of(a.slug)! == a.id
	assert f.store.find_all()!.map(it.slug) == [a.slug]

	b := f.store.insert(f.user_id, title: 'b', body: 'b', published: true)!
	published_at := b.published_at or { panic('expected a publication time') }
	assert published_at == b.created_at
}

fn test_insert_validates() {
	f := setup()!
	cases := {
		'an article needs a title':             ArticleUpdate{
			title: ' '
			body:  'b'
		}
		'an article needs a body':              ArticleUpdate{
			title: 't'
			body:  ' \n'
		}
		'the title is longer than 200 bytes':   ArticleUpdate{
			title: 'x'.repeat(201)
			body:  'b'
		}
		'the summary is longer than 500 bytes': ArticleUpdate{
			title:   't'
			summary: 'x'.repeat(501)
			body:    'b'
		}
		'the body is longer than 20000 bytes':  ArticleUpdate{
			title: 't'
			body:  'x'.repeat(20_001)
		}
	}
	for want, fields in cases {
		f.store.insert(f.user_id, fields) or {
			assert err is app.ValidationError
			assert err.msg() == want
			continue
		}
		assert false, 'expected `${want}`'
	}
	assert f.store.find_all()!.len == 0
}

// The database itself rejects an article whose author doesn't exist.
fn test_foreign_key_rejects_a_missing_user() {
	f := setup()!
	f.store.insert(999, title: 't', body: 'b') or {
		assert err is app.BadReferenceError
		assert err.msg() == 'user not found'
		return
	}
	assert false, 'expected the foreign key to reject user 999'
}

// An article without an author can't be stored, even by hand-written SQL.
fn test_user_id_is_not_null() {
	f := setup()!
	f.db.exec_param_many("INSERT INTO articles (slug, user_id, title, summary, body, created_at, updated_at) VALUES ('s', NULL, 't', '', 'b', 0, 0)",
		[]string{}) or {
		assert err.msg().starts_with('NOT NULL constraint failed: articles.user_id')
		return
	}
	assert false, 'expected NOT NULL to reject a missing user_id'
}

fn test_publishing() {
	f := setup()!
	a := f.store.insert(f.user_id, title: 't', body: 'b')!
	published := f.store.patch(a.slug, published: true)!
	first := published.published_at or { panic('expected a publication time') }

	time.sleep(1100 * time.millisecond)
	// publishing again, or editing a published article, keeps the first time
	again := f.store.patch(a.slug, title: 'new', published: true)!
	assert again.published_at or { panic('still published') } == first
	edited := f.store.patch(a.slug, body: 'new body')!
	assert edited.published_at or { panic('still published') } == first
	assert edited.title == 'new'
	assert edited.updated_at.unix() > a.updated_at.unix()

	unpublished := f.store.patch(a.slug, published: false)!
	assert unpublished.published_at == none
	// PUT replaces everything, so leaving out `published` unpublishes
	republished := f.store.replace(a.slug, title: 't', body: 'b', published: true)!
	assert republished.published_at != none
	replaced := f.store.replace(a.slug, title: 't2', body: 'b2')!
	assert replaced.published_at == none
	assert replaced.summary == ''
	assert replaced.created_at == a.created_at
	assert replaced.user_id == a.user_id
}

fn test_soft_delete() {
	f := setup()!
	a := f.store.insert(f.user_id, title: 'a', body: 'a')!
	b := f.store.insert(f.user_id, title: 'b', body: 'b')!
	f.store.soft_delete(a.slug)!
	assert f.store.find_all()!.map(it.slug) == [b.slug]
	for attempt in [
		fn [f, a] () ! {
			f.store.find(a.slug)!
		},
		fn [f, a] () ! {
			f.store.soft_delete(a.slug)!
		},
		fn [f, a] () ! {
			f.store.patch(a.slug, title: 'z')!
		},
		fn [f, a] () ! {
			f.store.id_of(a.slug)!
		},
	] {
		attempt() or {
			assert err is app.NotFoundError
			assert err.msg() == 'article not found'
			continue
		}
		assert false, 'a deleted article should be missing'
	}
}

fn test_find_rejects_bad_slugs() {
	f := setup()!
	f.store.insert(f.user_id, title: 't', body: 'b')!
	for slug in ['', 'nope', app.new_slug()] {
		f.store.find(slug) or {
			assert err is app.NotFoundError
			continue
		}
		assert false, 'found `${slug}`'
	}
}
