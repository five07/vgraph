module models

import db.sqlite
import app
import users.models as user_models

struct Fixture {
	db      sqlite.DB
	store   CommentStore
	user_id int
}

fn setup() !Fixture {
	db := app.connect(app.Config{})!
	user_models.create_tables(db)!
	create_tables(db)!
	user := user_models.UserStore.new(db).insert(name: 'Ada', email: 'ada@x')!
	return Fixture{
		db:      db
		store:   CommentStore.new(db)
		user_id: user.id
	}
}

// on returns a new comment by the fixture's user on `owner_type` `owner_id`.
fn (f Fixture) on(owner_type string, owner_id int, body string) NewComment {
	return NewComment{
		user_id:    f.user_id
		owner_type: owner_type
		owner_id:   owner_id
		body:       body
	}
}

struct Article {}

fn test_owner_type() {
	assert owner_type[Article]() == 'Article'
	assert owner_type[user_models.User]() == 'User'
}

fn test_insert_and_find() {
	f := setup()!
	c := f.store.insert(f.on('Article', 1, 'hello'))!
	assert app.valid_slug(c.slug)
	assert c.user_id == f.user_id
	assert c.owner_type == 'Article' && c.owner_id == 1
	assert c.parent_id == none
	assert f.store.find(c.slug)! == c
	assert f.store.find_all()!.map(it.slug) == [c.slug]
}

// Comments are found by owner type and id together: Article 1 and Post 1 are
// different owners.
fn test_find_by_owner() {
	f := setup()!
	a1 := f.store.insert(f.on('Article', 1, 'a1'))!
	p1 := f.store.insert(f.on('Post', 1, 'p1'))!
	a2 := f.store.insert(f.on('Article', 2, 'a2'))!
	a1b := f.store.insert(f.on('Article', 1, 'a1b'))!
	assert f.store.find_by_owner('Article', 1)!.map(it.slug) == [a1.slug, a1b.slug]
	assert f.store.find_by_owner('Post', 1)!.map(it.slug) == [p1.slug]
	assert f.store.find_by_owner('Article', 2)!.map(it.slug) == [a2.slug]
	assert f.store.find_by_owner('Post', 2)!.len == 0
	f.store.soft_delete(a1.slug)!
	assert f.store.find_by_owner('Article', 1)!.map(it.slug) == [a1b.slug]
}

fn test_create_tables_again() {
	f := setup()!
	// creating the tables again, as every startup does, is fine
	create_tables(f.db)!
}

fn test_replies() {
	f := setup()!
	root := f.store.insert(f.on('Article', 1, 'root'))!
	reply := f.store.insert(NewComment{
		...f.on('Article', 1, 'reply')
		parent_slug: root.slug
	})!
	assert reply.parent_id or { 0 } == root.id
	// a reply to a reply
	deeper := f.store.insert(NewComment{
		...f.on('Article', 1, 'deeper')
		parent_slug: reply.slug
	})!
	assert deeper.parent_id or { 0 } == reply.id

	elsewhere := [f.on('Article', 2, 'x'), f.on('Post', 1, 'x')]
	for new in elsewhere {
		f.store.insert(NewComment{ ...new, parent_slug: root.slug }) or {
			assert err is app.ValidationError
			assert err.msg() == 'a reply must be on the same ${new.owner_type} as its parent comment'
			continue
		}
		assert false, 'a reply on another owner should be rejected'
	}

	missing := app.new_slug()
	f.store.soft_delete(reply.slug)!
	for parent in [missing, reply.slug, 'nope'] {
		f.store.insert(NewComment{ ...f.on('Article', 1, 'x'), parent_slug: parent }) or {
			assert err is app.BadReferenceError
			assert err.msg() == 'parent comment `${parent}` not found'
			continue
		}
		assert false, 'a reply to `${parent}` should be rejected'
	}
	// deleting a comment keeps its replies, which still know their parent
	kept := f.store.find(deeper.slug)!
	assert kept.parent_id or { 0 } == reply.id
}

fn test_database_constraints() {
	f := setup()!
	f.store.insert(NewComment{ ...f.on('Article', 1, 'x'), user_id: 999 }) or {
		assert err is app.BadReferenceError
		mut rejected := []string{}
		for stmt in [
			"INSERT INTO comments (slug, user_id, owner_type, owner_id, parent_id, body, created_at, updated_at) VALUES ('a', NULL, 'Article', 1, NULL, 'b', 0, 0)",
			"INSERT INTO comments (slug, user_id, owner_type, owner_id, parent_id, body, created_at, updated_at) VALUES ('b', ${f.user_id}, 'Article', 1, 999, 'b', 0, 0)",
		] {
			f.db.exec_param_many(stmt, []string{}) or { rejected << err.msg().all_before(' (') }
		}
		assert rejected == ['NOT NULL constraint failed: comments.user_id',
			'FOREIGN KEY constraint failed']
		return
	}
	assert false, 'expected the foreign key to reject user 999'
}

fn test_validation_replace_patch() {
	f := setup()!
	for body, want in {
		' ':               'a comment needs a body'
		'x'.repeat(5_001): 'the body is longer than 5000 bytes'
	} {
		f.store.insert(f.on('Article', 1, body)) or {
			assert err is app.ValidationError
			assert err.msg() == want
			continue
		}
		assert false, 'expected `${want}`'
	}
	c := f.store.insert(f.on('Post', 3, 'first'))!
	replaced := f.store.replace(c.slug, body: 'second')!
	assert replaced.body == 'second'
	assert replaced.owner_type == 'Post' && replaced.owner_id == 3
	assert f.store.patch(c.slug, body: 'third')!.body == 'third'
	assert f.store.patch(c.slug, CommentPatch{})!.body == 'third'
	f.store.soft_delete(c.slug)!
	f.store.patch(c.slug, body: 'x') or {
		assert err is app.NotFoundError
		return
	}
	assert false, 'a deleted comment should be missing'
}
