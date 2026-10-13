module models

import app

fn new_store() !UserStore {
	db := app.connect(app.Config{})!
	create_tables(db)!
	return UserStore.new(db)
}

fn test_insert_and_find() {
	s := new_store()!
	user := s.insert(name: '  Ada ', email: ' Ada@Example.COM ')!
	assert user.id > 0
	assert app.valid_slug(user.slug)
	assert user.name == 'Ada'
	assert user.email == 'ada@example.com'
	assert user.created_at == user.updated_at
	assert s.find(user.slug)! == user
	assert s.id_of(user.slug)! == user.id
	assert s.find_all()!.map(it.slug) == [user.slug]
}

fn test_insert_validates() {
	s := new_store()!
	cases := {
		'a user needs a name':                UserInput{
			name:  ' '
			email: 'a@b'
		}
		'a user needs an email':              UserInput{
			name: 'a'
		}
		'the email needs an `@`':             UserInput{
			name:  'a'
			email: 'ab'
		}
		'the name is longer than 100 bytes':  UserInput{
			name:  'x'.repeat(101)
			email: 'a@b'
		}
		'the email is longer than 254 bytes': UserInput{
			name:  'a'
			email: 'a@' + 'b'.repeat(253)
		}
	}
	for want, input in cases {
		s.insert(input) or {
			assert err is app.ValidationError
			assert err.msg() == want
			continue
		}
		assert false, 'expected `${want}`'
	}
	assert s.find_all()!.len == 0
}

fn test_duplicate_email_is_a_conflict() {
	s := new_store()!
	s.insert(name: 'a', email: 'a@x')!
	other := s.insert(name: 'b', email: 'b@x')!
	for attempt in [
		fn [s] () ! {
			s.insert(name: 'c', email: 'A@X')!
		},
		fn [s, other] () ! {
			s.replace(other.slug, name: 'b', email: 'a@x')!
		},
		fn [s, other] () ! {
			s.patch(other.slug, email: 'a@x')!
		},
	] {
		attempt() or {
			assert err is app.ConflictError
			assert err.msg() == 'the email `a@x` is already taken'
			continue
		}
		assert false, 'expected a conflict'
	}
}

fn test_replace_and_patch() {
	s := new_store()!
	user := s.insert(name: 'a', email: 'a@x')!
	replaced := s.replace(user.slug, name: 'b', email: 'b@x')!
	assert replaced.id == user.id
	assert replaced.slug == user.slug
	assert replaced.name == 'b' && replaced.email == 'b@x'
	assert replaced.created_at == user.created_at

	patched := s.patch(user.slug, name: 'c')!
	assert patched.name == 'c'
	assert patched.email == 'b@x'

	s.replace(user.slug, name: 'd') or {
		assert err.msg() == 'a user needs an email'
		return
	}
	assert false, 'replace needs every field'
}

fn test_soft_delete() {
	s := new_store()!
	a := s.insert(name: 'a', email: 'a@x')!
	b := s.insert(name: 'b', email: 'b@x')!
	s.soft_delete(a.slug)!
	assert s.find_all()!.map(it.slug) == [b.slug]
	for attempt in [
		fn [s, a] () ! {
			s.find(a.slug)!
		},
		fn [s, a] () ! {
			s.soft_delete(a.slug)!
		},
		fn [s, a] () ! {
			s.patch(a.slug, name: 'z')!
		},
	] {
		attempt() or {
			assert err is app.NotFoundError
			continue
		}
		assert false, 'a deleted user should be missing'
	}
	// a deleted user keeps its email
	mut taken := false
	s.insert(name: 'c', email: 'a@x') or { taken = err is app.ConflictError }
	assert taken
}

fn test_find_rejects_bad_slugs() {
	s := new_store()!
	s.insert(name: 'a', email: 'a@x')!
	for slug in ['', 'nope', app.new_slug(), "' OR 1=1 --"] {
		s.find(slug) or {
			assert err is app.NotFoundError
			assert err.msg() == 'user not found'
			continue
		}
		assert false, 'found `${slug}`'
	}
}

fn test_reference_id() {
	s := new_store()!
	user := s.insert(name: 'a', email: 'a@x')!
	gone := s.insert(name: 'b', email: 'b@x')!
	s.soft_delete(gone.slug)!
	assert s.reference_id(user.slug)! == user.id
	for slug in [gone.slug, app.new_slug(), 'nope'] {
		s.reference_id(slug) or {
			assert err is app.BadReferenceError
			assert err.msg() == 'user `${slug}` not found'
			continue
		}
		assert false, 'expected a bad reference for `${slug}`'
	}
}

fn test_count_all_includes_deleted_users() {
	s := new_store()!
	assert s.count_all()! == 0
	user := s.insert(name: 'a', email: 'a@x')!
	s.soft_delete(user.slug)!
	assert s.find_all()!.len == 0
	assert s.count_all()! == 1
}
