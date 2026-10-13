module main

import json2
import os
import net
import net.http
import time
import veb
import app
import articles.models as article_models
import comments.models as comment_models
import posts.models as post_models
import users.models as user_models
import five07.vgraph.graphql

// start runs a new app with an empty in-memory database on a free port, and
// returns its base URL once it answers.
fn start() !string {
	return start_with(seed: false)!
}

// start_with runs a new app with the settings `cfg` on a free port, and
// returns its base URL once it answers.
fn start_with(cfg app.Config) !string {
	port := free_port()!
	mut api := new_app(app.Config{ ...cfg, port: port })!
	spawn veb.run_at[App, app.Context](mut api,
		port:                 port
		family:               .ip
		host:                 '127.0.0.1'
		show_startup_message: false
	)
	base := 'http://127.0.0.1:${port}'
	for _ in 0 .. 100 {
		http.get('${base}/health') or {
			time.sleep(20 * time.millisecond)
			continue
		}
		return base
	}
	return error('the app did not start on port ${port}')
}

// free_port returns a TCP port that nothing is listening on.
fn free_port() !int {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer {
		l.close() or {}
	}
	return int(l.addr()!.port()!)
}

fn test_health() {
	base := start()!
	res := http.get('${base}/health')!
	assert res.status_code == 200
	assert (res.header.get(.content_type) or { '' }) == 'application/json'
	assert res.body == '{"status":"ok"}'
}

fn test_unknown_route_is_a_json_404() {
	base := start()!
	res := http.get('${base}/nope')!
	assert res.status_code == 404
	assert (res.header.get(.content_type) or { '' }) == 'application/json'
	assert res.body == '{"error":"not found"}'
}

// call sends a request with the JSON body `body`, which may be empty.
fn call(method http.Method, url string, body string) !http.Response {
	return http.fetch(
		url:    url
		method: method
		data:   body
		header: http.new_header(key: .content_type, value: 'application/json')
	)!
}

// create_user creates a user through the API, and returns it.
fn create_user(base string, name string, email string) !user_models.UserView {
	res := call(.post, '${base}/users', '{"name":"${name}","email":"${email}"}')!
	assert res.status_code == 201, res.body
	return json2.decode[user_models.UserView](res.body)!
}

fn test_users_crud() {
	base := start()!
	ada := create_user(base, 'Ada', 'Ada@Example.com')!
	assert app.valid_slug(ada.slug)
	assert ada.name == 'Ada'
	assert ada.email == 'ada@example.com'
	assert ada.created_at.ends_with('Z')
	bob := create_user(base, 'Bob', 'bob@example.com')!

	list := call(.get, '${base}/users', '')!
	assert list.status_code == 200
	assert json2.decode[[]user_models.UserView](list.body)!.map(it.slug) == [ada.slug, bob.slug]

	shown := call(.get, '${base}/users/${ada.slug}', '')!
	assert shown.status_code == 200
	assert json2.decode[user_models.UserView](shown.body)! == ada

	put := call(.put, '${base}/users/${ada.slug}', '{"name":"Ada L","email":"ada@l.com"}')!
	assert put.status_code == 200, put.body
	replaced := json2.decode[user_models.UserView](put.body)!
	assert replaced.slug == ada.slug
	assert replaced.name == 'Ada L' && replaced.email == 'ada@l.com'
	assert replaced.created_at == ada.created_at

	patch := call(.patch, '${base}/users/${ada.slug}', '{"name":"John"}')!
	assert patch.status_code == 200, patch.body
	patched := json2.decode[user_models.UserView](patch.body)!
	assert patched.name == 'John'
	assert patched.email == 'ada@l.com'

	del := call(.delete, '${base}/users/${ada.slug}', '')!
	assert del.status_code == 204
	assert del.body == ''
	for method in [http.Method.get, .put, .patch, .delete] {
		res := call(method, '${base}/users/${ada.slug}', '{"name":"x","email":"x@x"}')!
		assert res.status_code == 404, '${method} ${res.body}'
		assert res.body == '{"error":"user not found"}'
	}
	after := call(.get, '${base}/users', '')!
	assert json2.decode[[]user_models.UserView](after.body)!.map(it.slug) == [bob.slug]
}

fn test_users_errors() {
	base := start()!
	bob := create_user(base, 'Bob', 'bob@example.com')!
	cases := [
		// method, path, body, status, error
		[http.Method.post.str(), '/users', '{"name":"","email":"a@b"}', '400', 'a user needs a name'],
		['POST', '/users', '{"name":"a","email":"BOB@example.com"}', '409',
			'the email `bob@example.com` is already taken'],
		['POST', '/users', '{"name":"a","email":"a@b","id":7,"admin":true}', '400',
			'The following attribute(s) are not supported: [admin, id]'],
		['POST', '/users', 'not json', '400', 'invalid JSON body'],
		['POST', '/users', '[]', '400', 'invalid JSON body'],
		['POST', '/users', '', '400', 'invalid JSON body'],
		['PUT', '/users/${bob.slug}', '{"name":"Bob"}', '400', 'a user needs an email'],
		['PATCH', '/users/${bob.slug}', '{"nmae":"Bob"}', '400',
			'The following attribute(s) are not supported: [nmae]'],
		['GET', '/users/not-a-slug', '', '404', 'user not found'],
		['GET', '/users/${app.new_slug()}', '', '404', 'user not found'],
	]
	for c in cases {
		res := call(http.method_from_str(c[0]), '${base}${c[1]}', c[2])!
		assert '${res.status_code} ${res.body}' == '${c[3]} {"error":"${c[4]}"}', c.str()
	}
}

fn test_users_ignore_server_owned_keys() {
	base := start()!
	bob := create_user(base, 'Bob', 'bob@example.com')!
	body := '{"slug":"${app.new_slug()}","name":"Rob","email":"rob@example.com","created_at":"2000-01-01T00:00:00.000Z","updated_at":"x"}'
	for method in [http.Method.put, .patch] {
		res := call(method, '${base}/users/${bob.slug}', body)!
		assert res.status_code == 200, res.body
		got := json2.decode[user_models.UserView](res.body)!
		assert got.slug == bob.slug
		assert got.created_at == bob.created_at
		assert got.name == 'Rob'
	}
	res := call(.post, '${base}/users', '{"slug":"${bob.slug}","name":"Al","email":"al@example.com"}')!
	assert res.status_code == 201
	assert json2.decode[user_models.UserView](res.body)!.slug != bob.slug
}

// The app shares one SQLite connection between veb's request threads.
fn test_users_concurrent_requests() {
	base := start()!
	mut creates := []thread !user_models.UserView{}
	for i in 0 .. 50 {
		creates << spawn create_user(base, 'user ${i}', 'user${i}@example.com')
	}
	mut created := []user_models.UserView{}
	for i, t in creates {
		user := t.wait()!
		// each create returns its own user, not one another thread inserted
		assert user.email == 'user${i}@example.com'
		created << user
	}
	mut updates := []thread !http.Response{}
	for user in created {
		updates << spawn call(.patch, '${base}/users/${user.slug}', '{"name":"renamed ${user.email}"}')
		updates << spawn call(.get, '${base}/users/${user.slug}', '')
	}
	for t in updates {
		res := t.wait()!
		assert res.status_code == 200, res.body
	}
	res := call(.get, '${base}/users', '')!
	list := json2.decode[[]user_models.UserView](res.body)!
	assert list.len == 50
	for user in list {
		assert user.name == 'renamed ${user.email}'
	}
}

// create_article creates an article by `user` through the API, and returns it.
fn create_article(base string, user user_models.UserView, title string) !article_models.ArticleView {
	res := call(.post, '${base}/articles', '{"user_slug":"${user.slug}","title":"${title}","body":"text of ${title}"}')!
	assert res.status_code == 201, res.body
	return json2.decode[article_models.ArticleView](res.body)!
}

fn test_articles_crud() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	bob := create_user(base, 'Bob', 'bob@example.com')!

	first := create_article(base, ada, 'First')!
	assert app.valid_slug(first.slug)
	assert first.user_slug == ada.slug
	assert first.title == 'First' && first.body == 'text of First' && first.summary == ''
	assert first.published_at == none
	second := create_article(base, bob, 'Second')!

	list := call(.get, '${base}/articles', '')!
	assert list.status_code == 200
	views := json2.decode[[]article_models.ArticleView](list.body)!
	assert views.map('${it.slug} ${it.user_slug}') == ['${first.slug} ${ada.slug}',
		'${second.slug} ${bob.slug}']

	shown := call(.get, '${base}/articles/${first.slug}', '')!
	assert shown.status_code == 200
	assert !shown.body.contains('published_at')
	assert json2.decode[article_models.ArticleView](shown.body)! == first

	patch := call(.patch, '${base}/articles/${first.slug}', '{"published":true,"summary":"short"}')!
	assert patch.status_code == 200, patch.body
	patched := json2.decode[article_models.ArticleView](patch.body)!
	assert patched.summary == 'short' && patched.title == 'First'
	published_at := patched.published_at or { panic('expected a publication time') }
	assert published_at.ends_with('Z')

	put := call(.put, '${base}/articles/${first.slug}', '{"title":"Renamed","body":"new","published":true}')!
	assert put.status_code == 200, put.body
	replaced := json2.decode[article_models.ArticleView](put.body)!
	assert replaced.title == 'Renamed' && replaced.body == 'new' && replaced.summary == ''
	assert replaced.published_at or { '' } == published_at
	assert replaced.user_slug == ada.slug

	del := call(.delete, '${base}/articles/${first.slug}', '')!
	assert del.status_code == 204
	for method in [http.Method.get, .put, .patch, .delete] {
		res := call(method, '${base}/articles/${first.slug}', '{"title":"x","body":"x"}')!
		assert '${res.status_code} ${res.body}' == '404 {"error":"article not found"}', method.str()
	}
	after := call(.get, '${base}/articles', '')!
	assert json2.decode[[]article_models.ArticleView](after.body)!.map(it.slug) == [second.slug]
}

fn test_articles_errors() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	gone := create_user(base, 'Gone', 'gone@example.com')!
	assert call(.delete, '${base}/users/${gone.slug}', '')!.status_code == 204
	article := create_article(base, ada, 'Kept')!
	missing := app.new_slug()
	cases := [
		// method, path, body, status, error
		['POST', '/articles', '{"title":"t","body":"b"}', '400', 'an article needs a `user_slug`'],
		['POST', '/articles', '{"user_slug":"${missing}","title":"t","body":"b"}', '400',
			'user `${missing}` not found'],
		['POST', '/articles', '{"user_slug":"${gone.slug}","title":"t","body":"b"}', '400',
			'user `${gone.slug}` not found'],
		['POST', '/articles', '{"user_slug":"nope","title":"t","body":"b"}', '400',
			'user `nope` not found'],
		['POST', '/articles', '{"user_slug":"${ada.slug}","title":"","body":"b"}', '400',
			'an article needs a title'],
		['POST', '/articles',
			'{"user_slug":"${ada.slug}","title":"t","body":"b","published_at":"2020"}', '400',
			'The following attribute(s) are not supported: [published_at]'],
		// the author is fixed at create
		['PUT', '/articles/${article.slug}', '{"user_slug":"${ada.slug}","title":"t","body":"b"}',
			'400', 'The following attribute(s) are not supported: [user_slug]'],
		['PATCH', '/articles/${article.slug}', '{"user_slug":"${ada.slug}"}', '400',
			'The following attribute(s) are not supported: [user_slug]'],
		['PATCH', '/articles/${article.slug}', '{"published":"yes"}', '400', 'invalid JSON body'],
		['PUT', '/articles/${article.slug}', '{"title":"t"}', '400', 'an article needs a body'],
		['GET', '/articles/${missing}', '', '404', 'article not found'],
	]
	for c in cases {
		res := call(http.method_from_str(c[0]), '${base}${c[1]}', c[2])!
		assert '${res.status_code} ${res.body}' == '${c[3]} {"error":"${c[4]}"}', c.str()
	}
}

// Deleting a user doesn't hide their articles, which still name them.
fn test_articles_keep_a_deleted_author() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	article := create_article(base, ada, 'Kept')!
	assert call(.delete, '${base}/users/${ada.slug}', '')!.status_code == 204
	res := call(.get, '${base}/articles/${article.slug}', '')!
	assert res.status_code == 200
	assert json2.decode[article_models.ArticleView](res.body)!.user_slug == ada.slug
}

// create_post creates a post by `user` through the API, and returns it.
fn create_post(base string, user user_models.UserView, body string) !post_models.PostView {
	res := call(.post, '${base}/posts', '{"user_slug":"${user.slug}","body":"${body}"}')!
	assert res.status_code == 201, res.body
	return json2.decode[post_models.PostView](res.body)!
}

fn test_posts_crud() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	bob := create_user(base, 'Bob', 'bob@example.com')!
	first := create_post(base, ada, 'hello')!
	assert app.valid_slug(first.slug)
	assert first.user_slug == ada.slug && first.body == 'hello'
	second := create_post(base, bob, 'hi')!

	list := call(.get, '${base}/posts', '')!
	assert list.status_code == 200
	assert json2.decode[[]post_models.PostView](list.body)!.map('${it.slug} ${it.user_slug}') == [
		'${first.slug} ${ada.slug}',
		'${second.slug} ${bob.slug}',
	]
	shown := call(.get, '${base}/posts/${first.slug}', '')!
	assert json2.decode[post_models.PostView](shown.body)! == first

	put := call(.put, '${base}/posts/${first.slug}', '{"body":"replaced"}')!
	assert put.status_code == 200, put.body
	assert json2.decode[post_models.PostView](put.body)!.body == 'replaced'
	patch := call(.patch, '${base}/posts/${first.slug}', '{"body":"patched"}')!
	assert patch.status_code == 200, patch.body
	patched := json2.decode[post_models.PostView](patch.body)!
	assert patched.body == 'patched' && patched.user_slug == ada.slug
	assert patched.created_at == first.created_at

	assert call(.delete, '${base}/posts/${first.slug}', '')!.status_code == 204
	for method in [http.Method.get, .put, .patch, .delete] {
		res := call(method, '${base}/posts/${first.slug}', '{"body":"x"}')!
		assert '${res.status_code} ${res.body}' == '404 {"error":"post not found"}', method.str()
	}
	after := call(.get, '${base}/posts', '')!
	assert json2.decode[[]post_models.PostView](after.body)!.map(it.slug) == [second.slug]
}

fn test_posts_errors() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	post := create_post(base, ada, 'kept')!
	missing := app.new_slug()
	long := 'x'.repeat(2_001)
	cases := [
		// method, path, body, status, error
		['POST', '/posts', '{"body":"b"}', '400', 'a post needs a `user_slug`'],
		['POST', '/posts', '{"user_slug":"${missing}","body":"b"}', '400',
			'user `${missing}` not found'],
		['POST', '/posts', '{"user_slug":"${ada.slug}","body":" "}', '400', 'a post needs a body'],
		['POST', '/posts', '{"user_slug":"${ada.slug}","body":"${long}"}', '400',
			'the body is longer than 2000 bytes'],
		['POST', '/posts', '{"user_slug":"${ada.slug}","body":"b","title":"t"}', '400',
			'The following attribute(s) are not supported: [title]'],
		['PUT', '/posts/${post.slug}', '{"user_slug":"${ada.slug}","body":"b"}', '400',
			'The following attribute(s) are not supported: [user_slug]'],
		['PUT', '/posts/${post.slug}', '{}', '400', 'a post needs a body'],
		['PATCH', '/posts/${post.slug}', '{"body":5}', '400', 'invalid JSON body'],
		['GET', '/posts/${missing}', '', '404', 'post not found'],
	]
	for c in cases {
		res := call(http.method_from_str(c[0]), '${base}${c[1]}', c[2])!
		assert '${res.status_code} ${res.body}' == '${c[3]} {"error":"${c[4]}"}', c.str()
	}
}

// create_comment creates a comment by `user` through the API, and returns it.
fn create_comment(base string, user user_models.UserView, owner_type string, owner_slug string, parent_slug string, body string) !comment_models.CommentView {
	res := call(.post, '${base}/comments', '{"user_slug":"${user.slug}","owner_type":"${owner_type}","owner_slug":"${owner_slug}","parent_slug":"${parent_slug}","body":"${body}"}')!
	assert res.status_code == 201, res.body
	return json2.decode[comment_models.CommentView](res.body)!
}

// comments_at returns the comments that `GET path` lists, as "body parent".
fn comments_at(base string, path string) ![]string {
	res := call(.get, '${base}${path}', '')!
	assert res.status_code == 200, res.body
	return json2.decode[[]comment_models.CommentView](res.body)!.map('${it.body} ${it.parent_slug or {
		'-'
	}}')
}

fn test_comments_on_articles_and_posts() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	bob := create_user(base, 'Bob', 'bob@example.com')!
	article := create_article(base, ada, 'Hello')!
	post := create_post(base, bob, 'hi')!

	on_article := create_comment(base, bob, 'Article', article.slug, '', 'nice')!
	assert app.valid_slug(on_article.slug)
	assert on_article.user_slug == bob.slug
	assert on_article.owner_type == 'Article' && on_article.owner_slug == article.slug
	assert on_article.parent_slug == none
	reply := create_comment(base, ada, 'Article', article.slug, on_article.slug, 'thanks')!
	assert reply.parent_slug or { '' } == on_article.slug
	on_post := create_comment(base, ada, 'Post', post.slug, '', 'hey')!
	assert on_post.owner_type == 'Post' && on_post.owner_slug == post.slug

	assert comments_at(base, '/comments')! == ['nice -', 'thanks ${on_article.slug}', 'hey -']
	assert comments_at(base, '/comments?owner_type=Article&owner_slug=${article.slug}')! == [
		'nice -',
		'thanks ${on_article.slug}',
	]
	assert comments_at(base, '/comments?owner_type=Post&owner_slug=${post.slug}')! == ['hey -']

	shown := call(.get, '${base}/comments/${reply.slug}', '')!
	assert json2.decode[comment_models.CommentView](shown.body)! == reply
	assert !call(.get, '${base}/comments/${on_post.slug}', '')!.body.contains('parent_slug')

	patch := call(.patch, '${base}/comments/${reply.slug}', '{"body":"thank you"}')!
	assert patch.status_code == 200, patch.body
	patched := json2.decode[comment_models.CommentView](patch.body)!
	assert patched.body == 'thank you'
	assert patched.parent_slug or { '' } == on_article.slug
	put := call(.put, '${base}/comments/${on_post.slug}', '{"body":"replaced"}')!
	assert json2.decode[comment_models.CommentView](put.body)!.body == 'replaced'

	// deleting a comment keeps its replies, still pointing at it
	assert call(.delete, '${base}/comments/${on_article.slug}', '')!.status_code == 204
	assert comments_at(base, '/comments?owner_type=Article&owner_slug=${article.slug}')! == [
		'thank you ${on_article.slug}',
	]
	for method in [http.Method.get, .put, .patch, .delete] {
		res := call(method, '${base}/comments/${on_article.slug}', '{"body":"x"}')!
		assert '${res.status_code} ${res.body}' == '404 {"error":"comment not found"}', method.str()
	}
}

// A deleted article keeps its comments in the table, but takes no new ones,
// and its comments can't be listed through it.
fn test_comments_on_a_deleted_owner() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	article := create_article(base, ada, 'Gone')!
	create_comment(base, ada, 'Article', article.slug, '', 'early')!
	assert call(.delete, '${base}/articles/${article.slug}', '')!.status_code == 204

	listed := call(.get, '${base}/comments?owner_type=Article&owner_slug=${article.slug}', '')!
	assert '${listed.status_code} ${listed.body}' == '404 {"error":"article not found"}'
	created := call(.post, '${base}/comments', '{"user_slug":"${ada.slug}","owner_type":"Article","owner_slug":"${article.slug}","body":"late"}')!
	assert '${created.status_code} ${created.body}' == '400 {"error":"Article `${article.slug}` not found"}'
	// the flat list still has the comment, and still names its owner
	all := call(.get, '${base}/comments', '')!
	views := json2.decode[[]comment_models.CommentView](all.body)!
	assert views.map('${it.body} ${it.owner_slug}') == ['early ${article.slug}']
}

fn test_comments_errors() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	article := create_article(base, ada, 'Hello')!
	other := create_article(base, ada, 'Other')!
	post := create_post(base, ada, 'hi')!
	root := create_comment(base, ada, 'Article', article.slug, '', 'root')!
	missing := app.new_slug()
	u := ada.slug
	a := article.slug
	cases := [
		// method, path, body, status, error
		['POST', '/comments', '{"owner_type":"Article","owner_slug":"${a}","body":"b"}', '400',
			'a comment needs a `user_slug`'],
		['POST', '/comments', '{"user_slug":"${u}","owner_slug":"${a}","body":"b"}', '400',
			'a comment needs an `owner_type` and an `owner_slug`'],
		['POST', '/comments', '{"user_slug":"${u}","owner_type":"Article","body":"b"}', '400',
			'a comment needs an `owner_type` and an `owner_slug`'],
		['POST', '/comments',
			'{"user_slug":"${u}","owner_type":"User","owner_slug":"${u}","body":"b"}', '400',
			'`owner_type` must be one of: Article, Post'],
		['POST', '/comments',
			'{"user_slug":"${u}","owner_type":"article","owner_slug":"${a}","body":"b"}', '400',
			'`owner_type` must be one of: Article, Post'],
		// an article's slug isn't a post's
		['POST', '/comments',
			'{"user_slug":"${u}","owner_type":"Post","owner_slug":"${a}","body":"b"}', '400',
			'Post `${a}` not found'],
		['POST', '/comments',
			'{"user_slug":"${missing}","owner_type":"Article","owner_slug":"${a}","body":"b"}',
			'400', 'user `${missing}` not found'],
		['POST', '/comments',
			'{"user_slug":"${u}","owner_type":"Article","owner_slug":"${a}","body":" "}', '400',
			'a comment needs a body'],
		['POST', '/comments',
			'{"user_slug":"${u}","owner_type":"Article","owner_slug":"${a}","parent_slug":"${missing}","body":"b"}',
			'400', 'parent comment `${missing}` not found'],
		['POST', '/comments',
			'{"user_slug":"${u}","owner_type":"Article","owner_slug":"${other.slug}","parent_slug":"${root.slug}","body":"b"}',
			'400', 'a reply must be on the same Article as its parent comment'],
		['POST', '/comments',
			'{"user_slug":"${u}","owner_type":"Post","owner_slug":"${post.slug}","parent_slug":"${root.slug}","body":"b"}',
			'400', 'a reply must be on the same Post as its parent comment'],
		['POST', '/comments',
			'{"user_slug":"${u}","owner_type":"Article","owner_slug":"${a}","owner_id":1,"body":"b"}',
			'400', 'The following attribute(s) are not supported: [owner_id]'],
		// the author, owner and parent are fixed at create
		['PUT', '/comments/${root.slug}', '{"owner_slug":"${other.slug}","body":"b"}', '400',
			'The following attribute(s) are not supported: [owner_slug]'],
		['PATCH', '/comments/${root.slug}', '{"parent_slug":"${root.slug}","owner_type":"Post"}',
			'400', 'The following attribute(s) are not supported: [owner_type, parent_slug]'],
		['GET', '/comments?owner_type=Article', '', '400',
			'filter by both `owner_type` and `owner_slug`'],
		['GET', '/comments?owner_type=Nope&owner_slug=${a}', '', '400',
			'`owner_type` must be one of: Article, Post'],
		['GET', '/comments?owner_type=Post&owner_slug=${missing}', '', '404', 'post not found'],
		['GET', '/comments/${missing}', '', '404', 'comment not found'],
	]
	for c in cases {
		res := call(http.method_from_str(c[0]), '${base}${c[1]}', c[2])!
		assert '${res.status_code} ${res.body}' == '${c[3]} {"error":"${c[4]}"}', c.str()
	}
}

fn test_users_nested_routes() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	bob := create_user(base, 'Bob', 'bob@example.com')!
	a1 := create_article(base, ada, 'A1')!
	create_article(base, bob, 'B1')!
	a2 := create_article(base, ada, 'A2')!
	p1 := create_post(base, ada, 'ada post')!
	create_post(base, bob, 'bob post')!
	create_comment(base, ada, 'Article', a1.slug, '', 'ada on article')!
	create_comment(base, bob, 'Article', a1.slug, '', 'bob on article')!
	create_comment(base, ada, 'Post', p1.slug, '', 'ada on post')!
	assert call(.delete, '${base}/articles/${a2.slug}', '')!.status_code == 204

	arts := call(.get, '${base}/users/${ada.slug}/articles', '')!
	assert arts.status_code == 200, arts.body
	views := json2.decode[[]article_models.ArticleView](arts.body)!
	assert views.map(it.title) == ['A1']
	assert views[0] == a1
	posts := call(.get, '${base}/users/${ada.slug}/posts', '')!
	assert json2.decode[[]post_models.PostView](posts.body)!.map('${it.body} ${it.user_slug}') == [
		'ada post ${ada.slug}',
	]
	coms := call(.get, '${base}/users/${ada.slug}/comments', '')!
	assert json2.decode[[]comment_models.CommentView](coms.body)!.map('${it.body} ${it.owner_type} ${it.owner_slug}') == [
		'ada on article Article ${a1.slug}',
		'ada on post Post ${p1.slug}',
	]
	none_yet := create_user(base, 'Cy', 'cy@example.com')!
	for kind in ['articles', 'posts', 'comments'] {
		res := call(.get, '${base}/users/${none_yet.slug}/${kind}', '')!
		assert '${res.status_code} ${res.body}' == '200 []', kind
	}

	assert call(.delete, '${base}/users/${bob.slug}', '')!.status_code == 204
	for slug in [bob.slug, app.new_slug(), 'nope'] {
		for kind in ['articles', 'posts', 'comments'] {
			res := call(.get, '${base}/users/${slug}/${kind}', '')!
			assert '${res.status_code} ${res.body}' == '404 {"error":"user not found"}', '${slug} ${kind}'
		}
	}
}

// Articles and posts serve the comments on them at `/:slug/comments`.
fn test_owner_nested_comment_routes() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	article := create_article(base, ada, 'Hello')!
	other := create_article(base, ada, 'Other')!
	post := create_post(base, ada, 'hi')!
	create_comment(base, ada, 'Article', other.slug, '', 'elsewhere')!

	for owner_type, path in {
		'Article': '/articles/${article.slug}'
		'Post':    '/posts/${post.slug}'
	} {
		owner_slug := path.all_after_last('/')
		empty := call(.get, '${base}${path}/comments', '')!
		assert '${empty.status_code} ${empty.body}' == '200 []', path

		created := call(.post, '${base}${path}/comments', '{"user_slug":"${ada.slug}","body":"first"}')!
		assert created.status_code == 201, created.body
		first := json2.decode[comment_models.CommentView](created.body)!
		assert first.owner_type == owner_type && first.owner_slug == owner_slug
		assert first.parent_slug == none
		replied := call(.post, '${base}${path}/comments', '{"user_slug":"${ada.slug}","parent_slug":"${first.slug}","body":"reply"}')!
		assert replied.status_code == 201, replied.body

		// the nested list and the filtered flat list are the same
		nested := comments_at(base, '${path}/comments')!
		assert nested == ['first -', 'reply ${first.slug}']
		assert comments_at(base, '/comments?owner_type=${owner_type}&owner_slug=${owner_slug}')! == nested
	}

	missing := app.new_slug()
	a := '/articles/${article.slug}/comments'
	cases := [
		// method, path, body, status, error
		['POST', a, '{"body":"b"}', '400', 'a comment needs a `user_slug`'],
		['POST', a, '{"user_slug":"${missing}","body":"b"}', '400', 'user `${missing}` not found'],
		['POST', a, '{"user_slug":"${ada.slug}","body":""}', '400', 'a comment needs a body'],
		// the path names the owner, so the body can't
		['POST', a,
			'{"user_slug":"${ada.slug}","owner_type":"Post","owner_slug":"${post.slug}","body":"b"}',
			'400', 'The following attribute(s) are not supported: [owner_slug, owner_type]'],
		['GET', '/articles/${missing}/comments', '', '404', 'article not found'],
		['POST', '/articles/${missing}/comments', '{"user_slug":"${ada.slug}","body":"b"}', '404',
			'article not found'],
		// an article's slug isn't a post's
		['GET', '/posts/${article.slug}/comments', '', '404', 'post not found'],
		['GET', '/articles/${article.slug}/nope', '', '404', 'not found'],
	]
	for c in cases {
		res := call(http.method_from_str(c[0]), '${base}${c[1]}', c[2])!
		assert '${res.status_code} ${res.body}' == '${c[3]} {"error":"${c[4]}"}', c.str()
	}
	// a reply through one owner's path can't answer a comment on another
	on_post := comments_at(base, '/posts/${post.slug}/comments')!
	assert on_post.len == 2
	post_comment := json2.decode[[]comment_models.CommentView](call(.get, '${base}/posts/${post.slug}/comments',
		'')!.body)![0]
	cross := call(.post, '${base}${a}', '{"user_slug":"${ada.slug}","parent_slug":"${post_comment.slug}","body":"b"}')!
	assert '${cross.status_code} ${cross.body}' == '400 {"error":"a reply must be on the same Article as its parent comment"}'

	// once the article is deleted, its comments can't be reached through it
	assert call(.delete, '${base}/articles/${article.slug}', '')!.status_code == 204
	for method in [http.Method.get, .post] {
		res := call(method, '${base}${a}', '{"user_slug":"${ada.slug}","body":"late"}')!
		assert '${res.status_code} ${res.body}' == '404 {"error":"article not found"}', method.str()
	}
}

fn test_seed() {
	base := start_with(seed: true)!
	users := json2.decode[[]user_models.UserView](call(.get, '${base}/users', '')!.body)!
	assert users.map(it.email) == ['ada@example.com', 'grace@example.com']
	articles := json2.decode[[]article_models.ArticleView](call(.get, '${base}/articles',
		'')!.body)!
	assert articles.len == 2
	assert articles[0].published_at != none
	assert articles[1].published_at == none
	assert json2.decode[[]post_models.PostView](call(.get, '${base}/posts', '')!.body)!.len == 2
	all := json2.decode[[]comment_models.CommentView](call(.get, '${base}/comments', '')!.body)!
	assert all.map(it.owner_type) == ['Article', 'Article', 'Post']
	assert all[1].parent_slug or { '' } == all[0].slug
	assert comments_at(base, '/articles/${articles[0].slug}/comments')!.len == 2
}

// A database file is seeded on the first start only, and not again once its
// users are deleted, since their emails stay taken.
fn test_seed_runs_once() {
	dir := os.join_path(os.vtmp_dir(), 'service-seed-test-${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	cfg := app.Config{
		db_path: os.join_path(dir, 'seed.db')
	}
	first := new_app(cfg)!
	users := user_models.UserStore.new(first.db)
	assert users.count_all()! == 2
	for user in users.find_all()! {
		users.soft_delete(user.slug)!
	}
	again := new_app(cfg)!
	assert user_models.UserStore.new(again.db).count_all()! == 2
	rows := again.db.exec('SELECT COUNT(*) FROM articles')!
	assert rows[0].vals == ['2']
}

// start_counting runs a new app with an empty in-memory database on a free
// port, with every store query going through an `app.CountingConnection`. It
// returns the app's base URL and the log of its selects.
fn start_counting() !(string, &app.QueryLog) {
	cfg := app.Config{
		seed: false
		port: free_port()!
	}
	db := app.connect(cfg)!
	conn := app.CountingConnection{
		inner: db
	}
	mut api := new_app_on(cfg, db, conn)!
	spawn veb.run_at[App, app.Context](mut api,
		port:                 cfg.port
		family:               .ip
		host:                 '127.0.0.1'
		show_startup_message: false
	)
	base := 'http://127.0.0.1:${cfg.port}'
	for _ in 0 .. 100 {
		http.get('${base}/health') or {
			time.sleep(20 * time.millisecond)
			continue
		}
		return base, conn.log
	}
	return error('the app did not start on port ${cfg.port}')
}

// selects_for returns the selects that `GET path` runs.
fn selects_for(base string, mut log app.QueryLog, path string) ![]string {
	log.clear()
	res := http.get('${base}${path}')!
	assert res.status_code == 200, '${path}: ${res.body}'
	return log.selects()
}

// Each read endpoint runs a fixed set of selects, however many rows it returns:
// related records are looked up in one `IN` query per table, never one per row.
// This is the baseline from `rest-api` that vgraph's loading must match or beat.
fn test_read_endpoints_query_counts() {
	base, mut log := start_counting()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	bob := create_user(base, 'Bob', 'bob@example.com')!
	article := create_article(base, ada, 'One')!
	create_article(base, bob, 'Two')!
	post := create_post(base, bob, 'hi')!
	on_article := create_comment(base, bob, 'Article', article.slug, '', 'nice')!
	create_comment(base, ada, 'Article', article.slug, on_article.slug, 'thanks')!
	on_post := create_comment(base, ada, 'Post', post.slug, '', 'hey')!
	reply := create_comment(base, bob, 'Post', post.slug, on_post.slug, 'ho')!

	user := 'users where slug eq, deleted_at is_null'
	authors := 'users where id in'
	parents := 'comments where id in'
	article_owners := 'articles where id in'
	post_owners := 'posts where id in'
	on_owner := 'comments where owner_type eq, owner_id eq, deleted_at is_null'
	expected := {
		'/users':                                            ['users where deleted_at is_null']
		'/users/${ada.slug}':                                [user]
		'/users/${ada.slug}/articles':                       [user,
			'articles where user_id eq, deleted_at is_null']
		'/users/${ada.slug}/posts':                          [user,
			'posts where user_id eq, deleted_at is_null']
		'/users/${ada.slug}/comments':                       [user,
			'comments where user_id eq, deleted_at is_null', authors, parents, article_owners,
			post_owners]
		'/articles':                                         [
			'articles where deleted_at is_null',
			authors,
		]
		'/articles/${article.slug}':                         [
			'articles where slug eq, deleted_at is_null',
			authors,
		]
		'/articles/${article.slug}/comments':                [
			'articles where slug eq, deleted_at is_null',
			on_owner,
			authors,
			parents,
			article_owners,
		]
		'/posts':                                            [
			'posts where deleted_at is_null',
			authors,
		]
		'/posts/${post.slug}':                               [
			'posts where slug eq, deleted_at is_null',
			authors,
		]
		'/posts/${post.slug}/comments':                      [
			'posts where slug eq, deleted_at is_null',
			on_owner,
			authors,
			parents,
			post_owners,
		]
		'/comments':                                         [
			'comments where deleted_at is_null',
			authors,
			parents,
			article_owners,
			post_owners,
		]
		'/comments/${on_post.slug}':                         [
			'comments where slug eq, deleted_at is_null',
			authors,
			post_owners,
		]
		'/comments/${reply.slug}':                           [
			'comments where slug eq, deleted_at is_null',
			authors,
			parents,
			post_owners,
		]
		'/comments?owner_type=Post&owner_slug=${post.slug}': [
			'posts where slug eq, deleted_at is_null',
			on_owner,
			authors,
			parents,
			post_owners,
		]
	}
	for path, selects in expected {
		assert selects_for(base, mut log, path)! == selects, path
	}

	// more rows, the same queries
	for i in 0 .. 5 {
		more := create_article(base, bob, 'More ${i}')!
		create_comment(base, ada, 'Article', more.slug, '', 'and ${i}')!
	}
	for path in ['/articles', '/comments', '/users/${ada.slug}/comments'] {
		assert selects_for(base, mut log, path)! == expected[path], path
	}
}

// Startup creates the indexes that the edges need, and running it again on the
// same database is fine.
fn test_startup_creates_edge_indexes() {
	cfg := app.Config{
		seed: false
	}
	db := app.connect(cfg)!
	new_app_on(cfg, db, db)!
	new_app_on(cfg, db, db)!
	rows := db.exec("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE '%_idx' ORDER BY name")!
	assert rows.map(it.vals[0]) == [
		'articles_user_id_idx',
		'comments_owner_type_owner_id_idx',
		'comments_parent_id_idx',
		'comments_user_id_idx',
		'posts_user_id_idx',
	]
}

// gql posts a GraphQL request to the app, and returns the response, parsed.
fn gql(base string, query string) !graphql.Value {
	res := call(.post, '${base}/graphql', graphql.Value({
		'query': graphql.Value(query)
	}).json())!
	assert res.status_code == 200, res.body
	return graphql.parse_json(res.body)!
}

// at returns the value at `path` in a response, such as `data.users.0.slug`.
fn at(v graphql.Value, path string) graphql.Value {
	mut cur := v
	for key in path.split('.') {
		cur = match cur {
			map[string]graphql.Value { cur[key] or { graphql.null } }
			[]graphql.Value { cur[key.int()] or { graphql.null } }
			else { graphql.null }
		}
	}
	return cur
}

// tables returns the tables of `selects`, in order.
fn tables(selects []string) []string {
	return selects.map(it.all_before(' where'))
}

// Each REST read has a GraphQL query that reads the same, and it runs the same
// selects: one per table, never one per row.
fn test_graphql_runs_the_same_selects_as_rest() {
	base, mut log := start_counting()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	bob := create_user(base, 'Bob', 'bob@example.com')!
	article := create_article(base, ada, 'One')!
	create_article(base, bob, 'Two')!
	post := create_post(base, bob, 'hi')!
	on_article := create_comment(base, bob, 'Article', article.slug, '', 'nice')!
	create_comment(base, ada, 'Article', article.slug, on_article.slug, 'thanks')!
	on_post := create_comment(base, ada, 'Post', post.slug, '', 'hey')!
	reply := create_comment(base, bob, 'Post', post.slug, on_post.slug, 'ho')!

	live := 'deletedAtIsNil: true'
	comment := 'slug body author { slug } parent { slug }'
	cases := {
		'/users':                                            '{ users(where: {${live}}) { slug name email } }'
		'/users/${ada.slug}':                                '{ users(where: {slug: "${ada.slug}", ${live}}) { slug } }'
		'/users/${ada.slug}/articles':                       '{ users(where: {slug: "${ada.slug}", ${live}}) { articles { slug title } } }'
		'/users/${ada.slug}/posts':                          '{ users(where: {slug: "${ada.slug}", ${live}}) { posts { slug body } } }'
		'/users/${ada.slug}/comments':                       '{ users(where: {slug: "${ada.slug}", ${live}}) { comments { ${comment} article { slug } post { slug } } } }'
		'/articles':                                         '{ articles(where: {${live}}) { slug author { slug } } }'
		'/articles/${article.slug}':                         '{ articles(where: {slug: "${article.slug}", ${live}}) { slug author { slug } } }'
		'/articles/${article.slug}/comments':                '{ articles(where: {slug: "${article.slug}", ${live}}) { comments { ${comment} article { slug } } } }'
		'/posts':                                            '{ posts(where: {${live}}) { slug author { slug } } }'
		'/posts/${post.slug}':                               '{ posts(where: {slug: "${post.slug}", ${live}}) { slug author { slug } } }'
		'/posts/${post.slug}/comments':                      '{ posts(where: {slug: "${post.slug}", ${live}}) { comments { ${comment} post { slug } } } }'
		'/comments':                                         '{ comments(where: {${live}}) { ${comment} article { slug } post { slug } } }'
		'/comments/${on_post.slug}':                         '{ comments(where: {slug: "${on_post.slug}", ${live}}) { ${comment} article { slug } post { slug } } }'
		'/comments/${reply.slug}':                           '{ comments(where: {slug: "${reply.slug}", ${live}}) { ${comment} article { slug } post { slug } } }'
		'/comments?owner_type=Post&owner_slug=${post.slug}': '{ posts(where: {slug: "${post.slug}", ${live}}) { comments { ${comment} post { slug } } } }'
	}
	for path, query in cases {
		rest := tables(selects_for(base, mut log, path)!)
		log.clear()
		res := gql(base, query)!
		assert at(res, 'errors') is graphql.Null, '${path}: ${res}'
		assert tables(log.selects()) == rest, path
	}
	// the same data: the replies to a post's comment, with their authors
	res := gql(base, '{ posts(where: {slug: "${post.slug}"}) { comments(orderBy: {field: ID}) { body author { name } parent { body } } } }')!
	assert at(res, 'data.posts.0.comments').json() == '[{"body":"hey","author":{"name":"Ada"},"parent":null},{"body":"ho","author":{"name":"Bob"},"parent":{"body":"hey"}}]'
}

// Every write of the REST API is a mutation, through the same stores, so it
// checks and stores the same way and fails with the same messages.
fn test_graphql_mutations() {
	base := start()!
	mut res := gql(base, 'mutation { createUser(input: {name: "Ada", email: "Ada@Example.com"}) { slug name email } }')!
	assert at(res, 'data.createUser.email').as_string() == 'ada@example.com', res.str()
	ada := at(res, 'data.createUser.slug').as_string()
	res = gql(base, 'mutation { updateUser(slug: "${ada}", input: {name: "Ada L"}) { name email } }')!
	assert at(res, 'data.updateUser').json() == '{"name":"Ada L","email":"ada@example.com"}'
	res = gql(base, 'mutation { replaceUser(slug: "${ada}", input: {name: "Ada", email: "ada@example.org"}) { email } }')!
	assert at(res, 'data.replaceUser.email').as_string() == 'ada@example.org'

	res = gql(base, 'mutation { createArticle(input: {userSlug: "${ada}", title: " One ", body: "text"}) { slug title publishedAt author { slug } } }')!
	assert at(res, 'data.createArticle.title').as_string() == 'One', res.str()
	assert at(res, 'data.createArticle.publishedAt') is graphql.Null
	assert at(res, 'data.createArticle.author.slug').as_string() == ada
	article := at(res, 'data.createArticle.slug').as_string()
	res = gql(base, 'mutation { updateArticle(slug: "${article}", input: {published: true}) { title publishedAt } }')!
	assert at(res, 'data.updateArticle.publishedAt').as_string().ends_with('Z'), res.str()
	res = gql(base, 'mutation { replaceArticle(slug: "${article}", input: {title: "Uno", body: "texto"}) { title body summary } }')!
	assert at(res, 'data.replaceArticle').json() == '{"title":"Uno","body":"texto","summary":""}'

	res = gql(base, 'mutation { createPost(input: {userSlug: "${ada}", body: "hi"}) { slug } }')!
	post := at(res, 'data.createPost.slug').as_string()
	res = gql(base, 'mutation { updatePost(slug: "${post}", input: {body: "hey"}) { body } replacePost(slug: "${post}", input: {body: "ho"}) { body } }')!
	assert at(res, 'data').json() == '{"updatePost":{"body":"hey"},"replacePost":{"body":"ho"}}'

	res = gql(base, 'mutation { createArticleComment(slug: "${article}", input: {userSlug: "${ada}", body: "first"}) { slug article { slug } } }')!
	assert at(res, 'data.createArticleComment.article.slug').as_string() == article, res.str()
	first := at(res, 'data.createArticleComment.slug').as_string()
	res = gql(base, 'mutation { createComment(input: {userSlug: "${ada}", ownerType: "Article", ownerSlug: "${article}", parentSlug: "${first}", body: "second"}) { slug parent { body } } }')!
	assert at(res, 'data.createComment.parent.body').as_string() == 'first', res.str()
	second := at(res, 'data.createComment.slug').as_string()
	res = gql(base, 'mutation { createPostComment(slug: "${post}", input: {userSlug: "${ada}", body: "on a post"}) { post { body } } }')!
	assert at(res, 'data.createPostComment.post.body').as_string() == 'ho', res.str()
	res = gql(base, 'mutation { updateComment(slug: "${second}", input: {body: "2nd"}) { body } replaceComment(slug: "${first}", input: {body: "1st"}) { body } }')!
	assert at(res, 'data').json() == '{"updateComment":{"body":"2nd"},"replaceComment":{"body":"1st"}}'

	res = gql(base, 'mutation { deleteComment(slug: "${second}") deletePost(slug: "${post}") }')!
	assert at(res, 'data').json() == '{"deleteComment":true,"deletePost":true}'
	res = gql(base, '{ articles(where: {slug: "${article}"}) { comments { body } } postsCount(where: {deletedAtIsNil: true}) }')!
	assert at(res, 'data').json() == '{"articles":[{"comments":[{"body":"1st"}]}],"postsCount":0}'
	res = gql(base, 'mutation { deleteArticle(slug: "${article}") deleteUser(slug: "${ada}") }')!
	assert at(res, 'data').json() == '{"deleteArticle":true,"deleteUser":true}'

	// the REST API's messages, and nothing internal
	res = gql(base, 'mutation { createArticle(input: {userSlug: "nobody", title: "x", body: "y"}) { slug } }')!
	assert at(res, 'errors.0.message').as_string() == 'user `nobody` not found', res.str()
	assert at(res, 'data') is graphql.Null
	res = gql(base, 'mutation { createUser(input: {name: "", email: "x@example.com"}) { slug } }')!
	assert at(res, 'errors.0.message').as_string() == 'a user needs a name', res.str()
}

// A request's mutations run in one transaction: when one fails, the ones
// before it are rolled back.
fn test_graphql_mutations_roll_back_together() {
	base := start()!
	res := gql(base, 'mutation { a: createUser(input: {name: "Cy", email: "cy@example.com"}) { slug } b: createArticle(input: {userSlug: "nobody", title: "x", body: "y"}) { slug } }')!
	assert at(res, 'errors.0.message').as_string() == 'user `nobody` not found', res.str()
	assert at(gql(base, '{ usersCount }')!, 'data.usersCount').as_int() == 0, 'the user was rolled back'
	// a mutation can't be sent with GET
	get := http.get('${base}/graphql?query=mutation%7BdeleteUser(slug%3A%22x%22)%7D')!
	assert get.status_code == 405
}

// The app answers the introspection query, which GraphiQL and Apollo's tools
// ask, exactly as graphql-js answers it for the same schema:
// testdata/introspection.json, which CI checks against graphql-js.
fn test_graphql_introspection_matches_graphql_js() {
	base := start()!
	res := call(.post, '${base}/graphql', graphql.Value({
		'query': graphql.Value(graphql.introspection_query)
	}).json())!
	assert res.status_code == 200
	want := os.read_file(os.join_path(@DIR, 'testdata', 'introspection.json'))!
	assert res.body + '\n' == want
}
