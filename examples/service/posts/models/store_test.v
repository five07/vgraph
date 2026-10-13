module models

import db.sqlite
import app
import users.models as user_models

struct Fixture {
	db      sqlite.DB
	store   PostStore
	user_id int
}

fn setup() !Fixture {
	db := app.connect(app.Config{})!
	user_models.create_tables(db)!
	create_tables(db)!
	user := user_models.UserStore.new(db).insert(name: 'Ada', email: 'ada@x')!
	return Fixture{
		db:      db
		store:   PostStore.new(db)
		user_id: user.id
	}
}

fn test_insert_find_replace_patch() {
	f := setup()!
	p := f.store.insert(f.user_id, body: 'hello')!
	assert app.valid_slug(p.slug)
	assert p.user_id == f.user_id
	assert p.body == 'hello'
	assert f.store.find(p.slug)! == p
	assert f.store.id_of(p.slug)! == p.id
	assert f.store.find_all()!.map(it.slug) == [p.slug]

	replaced := f.store.replace(p.slug, body: 'replaced')!
	assert replaced.body == 'replaced'
	assert replaced.created_at == p.created_at
	assert f.store.patch(p.slug, body: 'patched')!.body == 'patched'
	// an empty patch changes nothing
	assert f.store.patch(p.slug, PostPatch{})!.body == 'patched'
}

fn test_validation() {
	f := setup()!
	for body, want in {
		'':                'a post needs a body'
		' \n':             'a post needs a body'
		'x'.repeat(2_001): 'the body is longer than 2000 bytes'
	} {
		f.store.insert(f.user_id, body: body) or {
			assert err is app.ValidationError
			assert err.msg() == want
			continue
		}
		assert false, 'expected `${want}`'
	}
	assert f.store.insert(f.user_id, body: 'x'.repeat(2_000))!.body.len == 2_000
}

fn test_user_references() {
	f := setup()!
	f.store.insert(999, body: 'b') or {
		assert err is app.BadReferenceError
		mut null_rejected := false
		f.db.exec_param_many("INSERT INTO posts (slug, user_id, body, created_at, updated_at) VALUES ('s', NULL, 'b', 0, 0)",
			[]string{}) or { null_rejected = err.msg().starts_with('NOT NULL constraint failed') }
		assert null_rejected
		return
	}
	assert false, 'expected the foreign key to reject user 999'
}

fn test_soft_delete() {
	f := setup()!
	a := f.store.insert(f.user_id, body: 'a')!
	b := f.store.insert(f.user_id, body: 'b')!
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
			f.store.replace(a.slug, body: 'z')!
		},
	] {
		attempt() or {
			assert err is app.NotFoundError
			assert err.msg() == 'post not found'
			continue
		}
		assert false, 'a deleted post should be missing'
	}
}
