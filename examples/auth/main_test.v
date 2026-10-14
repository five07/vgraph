module main

// Each rule, over HTTP: a request as no one, as a member and as an admin,
// with tokens from `login`. Each test runs its own app, seeded with Ada (an
// admin) and Bob (a member), whose post 1 is published and post 2 a draft.
import db.sqlite
import net
import net.http
import os
import time
import veb
import five07.vgraph.graphql
import auth

const test_secret = 'the tests sign tokens with this key'

// start runs a seeded app on a free port, and returns its base URL once it
// answers.
fn start() !string {
	// bcrypt's lowest cost: the default takes a while per hash
	os.setenv('BCRYPT_COST', '4', true)
	mut api := new_app(Config{
		secret: test_secret
	})!
	port := free_port()!
	spawn veb.run_at[App, Context](mut api,
		port:                 port
		family:               .ip
		host:                 '127.0.0.1'
		show_startup_message: false
	)
	base := 'http://127.0.0.1:${port}'
	for _ in 0 .. 100 {
		http.get('${base}/graphql?query=%7B__typename%7D') or {
			time.sleep(20 * time.millisecond)
			continue
		}
		return base
	}
	return error('the app did not start on port ${port}')
}

fn free_port() !int {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer {
		l.close() or {}
	}
	return int(l.addr()!.port()!)
}

// post sends `query` with the token `token` ('' for none), and returns the
// status and the body.
fn post(base string, token string, query string) !(int, string) {
	mut header := http.new_header(key: .content_type, value: 'application/json')
	if token != '' {
		header.add(.authorization, 'Bearer ${token}')
	}
	res := http.fetch(
		url:    '${base}/graphql'
		method: .post
		data:   graphql.Value({
			'query': graphql.Value(query)
		}).json()
		header: header
	)!
	return res.status_code, res.body
}

// run sends `query` as `token`, and returns its data, or its errors as one.
fn run(base string, token string, query string) !graphql.Value {
	status, body := post(base, token, query)!
	assert status == 200, body
	res := graphql.parse_json(body)!
	if errors := res.as_map()['errors'] {
		return error(errors.as_list().map(at(it, 'message').as_string()).join('\n'))
	}
	return at(res, 'data')
}

// fails sends `query` as `token`, and returns its error.
fn fails(base string, token string, query string) string {
	run(base, token, query) or { return err.msg() }
	return 'no error'
}

fn at(v graphql.Value, keys ...string) graphql.Value {
	mut cur := v
	for k in keys {
		cur = cur.as_map()[k] or { graphql.null }
	}
	return cur
}

fn login(base string, email string, password string) !string {
	return at(run(base, '', 'mutation { login(email: "${email}", password: "${password}") }')!,
		'login').as_string()
}

// titles returns the titles of the posts `token` can read.
fn titles(base string, token string) ![]string {
	conn := at(run(base, token, '{ posts(orderBy: {field: ID}) { edges { node { title } } } }')!,
		'posts')
	return at(conn, 'edges').as_list().map(at(it, 'node', 'title').as_string())
}

const denied_update = 'privacy: update_one of `posts` denied'

fn test_login() {
	base := start()!
	token := login(base, 'bob@example.com', 'bob-password')!
	claims := auth.verify(token, test_secret.bytes(), time.now())!
	assert claims.sub == 2 && !claims.admin
	assert claims.exp - claims.iat == 3600
	assert auth.verify(login(base, 'ada@example.com', 'ada-password')!, test_secret.bytes(),
		time.now())!.admin
	// a wrong password and an unknown email look the same
	assert fails(base, '', 'mutation { login(email: "bob@example.com", password: "nope") }') == 'wrong email or password'
	assert fails(base, '', 'mutation { login(email: "eve@example.com", password: "bob-password") }') == 'wrong email or password'
	assert at(run(base, token, '{ me { id name } }')!, 'me').json() == '{"id":"2","name":"Bob"}'
}

// A token that doesn't verify is a 401 before the request runs; no token is
// the anonymous viewer.
fn test_tokens() {
	base := start()!
	expired := auth.issue(2, false, time.hour, time.now().add(-2 * time.hour), test_secret.bytes())
	forged := auth.issue(2, true, time.hour, time.now(), 'another key, also 32 bytes long'.bytes())
	for token, message in {
		expired:     'token expired'
		forged:      'invalid signature'
		'not.a.jwt': 'malformed token'
	} {
		status, body := post(base, token, '{ me { name } }')!
		assert status == 401
		assert body == '{"errors":[{"message":"${message}"}]}'
	}
	res := http.fetch(
		url:    '${base}/graphql?query=%7Bme%7Bname%7D%7D'
		header: http.new_header(key: .authorization, value: 'Basic Ym9iOnB3')
	)!
	assert res.status_code == 401
	assert res.header.get_custom('WWW-Authenticate') or { '' } == 'Bearer error="invalid_token"'
	assert at(run(base, '', '{ me { name } }')!, 'me').json() == 'null'
}

// Anyone reads published posts, a member their own drafts too, an admin
// everything; and a post's author is open to all.
fn test_reading_posts() {
	base := start()!
	bob := login(base, 'bob@example.com', 'bob-password')!
	ada := login(base, 'ada@example.com', 'ada-password')!
	run(base, '', 'mutation { createUser(input: {name: "Cy", email: "cy@example.com", password: "cy-password"}) { id } }')!
	cy := login(base, 'cy@example.com', 'cy-password')!
	assert titles(base, '')! == ['Hello']
	assert titles(base, cy)! == ['Hello']
	assert titles(base, bob)! == ['Hello', 'Draft']
	assert titles(base, ada)! == ['Hello', 'Draft']
	// counts and edges follow the same rule
	assert at(run(base, cy, '{ users(orderBy: {field: ID}) { name posts { totalCount edges { node { title } } } } }')!,
		'users').json() == '[{"name":"Ada","posts":{"totalCount":0,"edges":[]}},{"name":"Bob","posts":{"totalCount":1,"edges":[{"node":{"title":"Hello"}}]}},{"name":"Cy","posts":{"totalCount":0,"edges":[]}}]'
	assert at(run(base, bob, '{ posts { totalCount } }')!, 'posts', 'totalCount').as_int() == 2
	assert at(run(base, '', '{ posts { edges { node { author { name } } } } }')!, 'posts').json() == '{"edges":[{"node":{"author":{"name":"Bob"}}}]}'
	// the email and the password hash are never in the schema
	assert fails(base, ada, '{ users { email } }').starts_with('Cannot query field "email" on type "User".')
	assert fails(base, ada, '{ users { password } }').starts_with('Cannot query field "password" on type "User".')
}

// Only a logged-in user creates a post. The `set_author` hook makes a member
// its author, and lets an admin post as anyone.
fn test_creating_posts() {
	base := start()!
	bob := login(base, 'bob@example.com', 'bob-password')!
	ada := login(base, 'ada@example.com', 'ada-password')!
	create := 'mutation { createPost(input: {title: "New", body: "x"AUTHOR}) { title author { name } } }'
	assert fails(base, '', create.replace('AUTHOR', '')) == 'privacy: create of `posts` denied'
	// a member: the author is the member, and can't be anyone else
	assert at(run(base, bob, create.replace('AUTHOR', ''))!, 'createPost').json() == '{"title":"New","author":{"name":"Bob"}}'
	assert fails(base, bob, create.replace('AUTHOR', ', authorID: "1"')) == '`posts.author_id`: only an admin can post as another user'
	assert at(run(base, bob, create.replace('AUTHOR', ', authorID: "2"'))!, 'createPost', 'author',
		'name').as_string() == 'Bob'
	// an admin: themselves, or anyone
	assert at(run(base, ada, create.replace('AUTHOR', ''))!, 'createPost', 'author', 'name').as_string() == 'Ada'
	assert at(run(base, ada, create.replace('AUTHOR', ', authorID: "2"'))!, 'createPost', 'author',
		'name').as_string() == 'Bob'
}

// Only the author updates or deletes a post, or an admin.
fn test_changing_posts() {
	base := start()!
	bob := login(base, 'bob@example.com', 'bob-password')!
	ada := login(base, 'ada@example.com', 'ada-password')!
	run(base, '', 'mutation { createUser(input: {name: "Cy", email: "cy@example.com", password: "cy-password"}) { id } }')!
	cy := login(base, 'cy@example.com', 'cy-password')!
	publish := 'mutation { updatePost(id: "2", input: {title: "TITLE"}) { title } }'
	assert fails(base, '', publish.replace('TITLE', 'Mine')) == denied_update
	// Cy can't change Bob's draft, which Cy can't even read, nor his post
	assert fails(base, cy, publish.replace('TITLE', 'Mine')) == denied_update
	assert fails(base, cy, 'mutation { updatePost(id: "1", input: {title: "Mine"}) { title } }') == denied_update
	assert fails(base, cy, 'mutation { deletePost(id: "1") }') == 'privacy: delete_one of `posts` denied'
	// Bob can, and so can Ada
	assert at(run(base, bob, publish.replace('TITLE', 'Ready'))!, 'updatePost', 'title').as_string() == 'Ready'
	assert at(run(base, ada, publish.replace('TITLE', 'Edited'))!, 'updatePost', 'title').as_string() == 'Edited'
	assert at(run(base, ada, 'mutation { deletePost(id: "1") }')!, 'deletePost').as_string() == '1'
	assert at(run(base, bob, 'mutation { deletePost(id: "2") }')!, 'deletePost').as_string() == '2'
	assert titles(base, ada)! == []string{}
}

// Anyone signs up; a user changes only their own account; and the
// `admin_only` hook lets only an admin grant `admin`.
fn test_users() {
	base := start()!
	bob := login(base, 'bob@example.com', 'bob-password')!
	ada := login(base, 'ada@example.com', 'ada-password')!
	signup := 'mutation { createUser(input: {name: "Cy", email: "cy@example.com", password: "PASSWORD"ADMIN}) { name admin } }'
	assert fails(base, '', signup.replace('PASSWORD', 'short').replace('ADMIN', '')) == '`users.password`: is shorter than 8 bytes'
	assert fails(base, bob, signup.replace('PASSWORD', 'cy-password').replace('ADMIN', ', admin: true')) == '`users.admin`: only an admin can change it'
	assert at(run(base, '', signup.replace('PASSWORD', 'cy-password').replace('ADMIN', ''))!,
		'createUser').json() == '{"name":"Cy","admin":false}'
	cy := login(base, 'cy@example.com', 'cy-password')!
	assert at(run(base, ada, signup.replace('Cy', 'Dee').replace('cy@', 'dee@').replace('PASSWORD',
		'dee-password').replace('ADMIN', ', admin: true'))!, 'createUser').json() == '{"name":"Dee","admin":true}'
	// a user changes their own account, but not their role, nor anyone else's
	assert at(run(base, cy, 'mutation { updateUser(id: "3", input: {name: "Cyd"}) { name } }')!,
		'updateUser', 'name').as_string() == 'Cyd'
	assert fails(base, cy, 'mutation { updateUser(id: "3", input: {admin: true}) { name } }') == '`users.admin`: only an admin can change it'
	assert fails(base, cy, 'mutation { updateUser(id: "2", input: {name: "Bobby"}) { name } }') == 'privacy: update_one of `users` denied'
	assert fails(base, '', 'mutation { updateUser(id: "3", input: {name: "Eve"}) { name } }') == 'privacy: update_one of `users` denied'
	// an admin changes anyone's, role and all, and deletes accounts
	assert at(run(base, ada, 'mutation { updateUser(id: "3", input: {admin: true}) { admin } }')!,
		'updateUser', 'admin').as_bool()
	assert fails(base, bob, 'mutation { deleteUser(id: "3") }') == 'privacy: delete_one of `users` denied'
	assert at(run(base, ada, 'mutation { deleteUser(id: "4") }')!, 'deleteUser').as_string() == '4'
	// a new password: the old one stops working
	run(base, cy, 'mutation { updateUser(id: "3", input: {password: "new-password"}) { name } }')!
	login(base, 'cy@example.com', 'new-password')!
	assert fails(base, '', 'mutation { login(email: "cy@example.com", password: "cy-password") }') == 'wrong email or password'
}

// The `hash_password` hook stores a bcrypt hash, never the password.
fn test_passwords_are_hashed() {
	path := os.join_path(os.vtmp_dir(), 'vgraph_auth_${os.getpid()}.db')
	defer {
		os.rm(path) or {}
	}
	os.setenv('BCRYPT_COST', '4', true)
	new_app(Config{
		secret:  test_secret
		db_path: path
	})!
	db := sqlite.connect(path)!
	stored := db.exec("SELECT password FROM users WHERE email = 'bob@example.com'")![0].vals[0]
	assert stored.starts_with('$2')
	assert stored != 'bob-password'
	assert auth.check_password('bob-password', stored)
}

fn test_config() {
	if _ := new_app(Config{ secret: 'short' }) {
		assert false
	} else {
		assert err.msg() == 'JWT_SECRET must be at least 32 bytes'
	}
}
