module main

import db.sqlite
import os
import net
import net.http
import sync
import time
import veb
import app
import five07.vgraph
import five07.vgraph.graphql
import migrations

// start runs a new app with an empty in-memory database on a free port, and
// returns its base URL once it answers.
fn start() !string {
	return start_with(seed: false)!
}

// start_with runs a new app with the settings `cfg` on a free port, and
// returns its base URL once it answers.
fn start_with(cfg app.Config) !string {
	return serve(new_app(app.Config{ ...cfg, port: 0 })!)
}

// Log holds the tables of the selects the app ran, and `sql` for each
// statement vgraph's driver wrote itself. Requests run on several threads.
@[heap]
struct Log {
mut:
	mu     &sync.Mutex = sync.new_mutex()
	tables []string
}

fn (mut l Log) add(table string) {
	l.mu.lock()
	l.tables << table
	l.mu.unlock()
}

// take returns what was logged since the last call.
fn (mut l Log) take() []string {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	out := l.tables.clone()
	l.tables.clear()
	return out
}

// start_counting runs a new app, without example data, whose selects go to
// the returned log.
fn start_counting() !(string, &Log) {
	log := &Log{}
	cfg := app.Config{
		seed: false
	}
	api := new_app_on(cfg, app.connect(cfg)!, fn [log] (e vgraph.TraceEvent) {
		mut l := unsafe { log }
		if e.kind == .select {
			l.add(e.table)
		} else if e.kind == .raw {
			l.add('sql')
		}
	})!
	return serve(api)!, log
}

// serve runs `api` on a free port, and returns its base URL once it answers.
fn serve(api &App) !string {
	port := free_port()!
	mut a := unsafe { api }
	spawn veb.run_at[App, app.Context](mut a,
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

// gql posts a GraphQL request to the app, and returns the response, parsed.
fn gql(base string, query string) !graphql.Value {
	res := http.fetch(
		url:    '${base}/graphql'
		method: .post
		data:   graphql.Value({
			'query': graphql.Value(query)
		}).json()
		header: http.new_header(key: .content_type, value: 'application/json')
	)!
	assert res.status_code == 200, res.body
	return graphql.parse_json(res.body)!
}

// data posts a GraphQL request, and returns its data, or its errors as one
// error.
fn data(base string, query string) !graphql.Value {
	res := gql(base, query)!
	if errors := res.as_map()['errors'] {
		return error(errors.as_list().map(at(it, 'message').as_string()).join('\n'))
	}
	return at(res, 'data')
}

// failure posts a GraphQL request that must fail, and returns its first
// error's message.
fn failure(base string, query string) !string {
	res := gql(base, query)!
	message := at(res, 'errors.0.message').as_string()
	assert message != '', 'expected an error: ${res}'
	return message
}

// at returns the value at `path` in a response, such as `users.edges.0.node`.
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

// nodes returns the nodes of the connection at `path`.
fn nodes(v graphql.Value, path string) []graphql.Value {
	return at(v, path + '.edges').as_list().map(at(it, 'node'))
}

// create_user creates a user, and returns its id.
fn create_user(base string, name string, email string) !string {
	return at(data(base, 'mutation { createUser(input: {name: "${name}", email: "${email}"}) { id } }')!,
		'createUser.id').as_string()
}

// create_article creates an article by `user`, and returns its id.
fn create_article(base string, user string, title string) !string {
	return at(data(base, 'mutation { createArticle(input: {userID: "${user}", title: "${title}", body: "text of ${title}"}) { id } }')!,
		'createArticle.id').as_string()
}

// create_post creates a post by `user`, and returns its id.
fn create_post(base string, user string, body string) !string {
	return at(data(base, 'mutation { createPost(input: {userID: "${user}", body: "${body}"}) { id } }')!,
		'createPost.id').as_string()
}

// create_comment creates a comment by `user` on the owner of the type
// `owner_type` with the id `owner`, answering `parent` when it is set, and
// returns its id.
fn create_comment(base string, user string, owner_type string, owner string, parent string, body string) !string {
	reply := if parent != '' { ', parentID: "${parent}"' } else { '' }
	return at(data(base, 'mutation { createComment(input: {userID: "${user}", ownerType: "${owner_type}", ownerID: "${owner}"${reply}, body: "${body}"}) { id } }')!,
		'createComment.id').as_string()
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
	for path in ['/nope', '/users'] {
		res := http.get('${base}${path}')!
		assert res.status_code == 404
		assert (res.header.get(.content_type) or { '' }) == 'application/json'
		assert res.body == '{"error":"not found"}'
	}
}

fn test_users() {
	base := start()!
	// the name trimmed, the email trimmed and lowercased
	created := data(base, 'mutation { createUser(input: {name: " Ada ", email: " Ada@Example.com"}) { id name email createdAt updatedAt } }')!
	ada := at(created, 'createUser.id').as_string()
	assert at(created, 'createUser.name').as_string() == 'Ada'
	assert at(created, 'createUser.email').as_string() == 'ada@example.com'
	assert at(created, 'createUser.createdAt') == at(created, 'createUser.updatedAt')
	// a global id: users count from their own range
	assert ada.i64() > i64(1) << 32
	assert at(data(base, '{ node(id: "${ada}") { __typename ... on User { name } } }')!, 'node').json() == '{"__typename":"User","name":"Ada"}'
	bob := create_user(base, 'Bob', 'bob@example.com')!
	list := data(base, '{ users { totalCount edges { node { name } } } }')!
	assert at(list, 'users.totalCount').as_int() == 2
	assert nodes(list, 'users').map(at(it, 'name').as_string()) == ['Ada', 'Bob']
	// an update changes what it sets, and `updatedAt`
	time.sleep(1100 * time.millisecond)
	updated := data(base, 'mutation { updateUser(id: "${ada}", input: {name: "Ada L", email: "ADA@example.org"}) { name email createdAt updatedAt } }')!
	assert at(updated, 'updateUser.name').as_string() == 'Ada L'
	assert at(updated, 'updateUser.email').as_string() == 'ada@example.org'
	assert at(updated, 'updateUser.createdAt') == at(created, 'createUser.createdAt')
	assert at(updated, 'updateUser.updatedAt') != at(created, 'createUser.updatedAt')
	// a delete marks the user deleted: gone from queries
	assert at(data(base, 'mutation { deleteUser(id: "${bob}") }')!, 'deleteUser').as_string() == bob
	assert nodes(data(base, '{ users { edges { node { name } } } }')!, 'users').map(at(it, 'name').as_string()) == [
		'Ada L',
	]
	assert failure(base, '{ node(id: "${bob}") { id } }')! == 'Could not resolve to a node with the global ID of "${bob}".'
	assert failure(base, 'mutation { updateUser(id: "${bob}", input: {name: "x"}) { id } }')! == 'no `users` row matches'
}

fn test_users_errors() {
	base := start()!
	create_user(base, 'Ada', 'ada@example.com')!
	for input, message in {
		'name: " ", email: "x@example.com"':                  '`users.name`: is empty'
		'name: "${'n'.repeat(101)}", email: "x@example.com"': '`users.name`: is longer than 100 bytes'
		'name: "X", email: "example.com"':                    '`users.email`: needs an `@`'
		'name: "X", email: " "':                              '`users.email`: is empty'
	} {
		assert failure(base, 'mutation { createUser(input: {${input}}) { id } }')! == message
	}
	// the unique email, as the database reports it, whatever its case, and
	// without the SQL
	assert failure(base, 'mutation { createUser(input: {name: "Ada 2", email: "ADA@example.com"}) { id } }')! == 'UNIQUE constraint failed: users.email'
	assert failure(base, 'mutation { createUser(input: {name: "X"}) { id } }')! == 'Field "CreateUserInput.email" of required type "String!" was not provided.'
	assert failure(base, 'mutation { updateUser(id: "nope", input: {name: "X"}) { id } }')! == 'invalid ID "nope"'
}

// The server owns ids and times: the inputs have no fields for them.
fn test_server_owned_fields() {
	base := start()!
	for field in ['createdAt', 'updatedAt', 'deletedAt', 'id'] {
		assert failure(base, 'mutation { createUser(input: {name: "X", email: "x@example.com", ${field}: "1"}) { id } }')! == 'Field "${field}" is not defined by type "CreateUserInput".'
	}
	// the author of a record doesn't change, from either side
	assert failure(base, 'mutation { updateArticle(id: "1", input: {userID: "1"}) { id } }')! == 'Field "userID" is not defined by type "UpdateArticleInput".'
	assert failure(base, 'mutation { createUser(input: {name: "X", email: "x@example.com", articleIDs: ["1"]}) { id } }')! == 'Field "articleIDs" is not defined by type "CreateUserInput".'
}

fn test_concurrent_requests() {
	base := start()!
	mut creates := []thread !string{}
	for i in 0 .. 30 {
		creates << spawn create_user(base, 'user ${i}', 'user${i}@example.com')
	}
	mut ids := []string{}
	for t in creates {
		ids << t.wait()!
	}
	assert ids.len == 30
	mut updates := []thread !graphql.Value{}
	for i, id in ids {
		updates << spawn data(base, 'mutation { updateUser(id: "${id}", input: {name: "renamed ${i}"}) { name } }')
		updates << spawn data(base, '{ node(id: "${id}") { id } }')
	}
	for t in updates {
		t.wait()!
	}
	users := nodes(data(base, '{ users { edges { node { id name email } } } }')!, 'users')
	assert users.len == 30
	for user in users {
		i := ids.index(at(user, 'id').as_string())
		// each create returned its own user, not one another thread inserted
		assert at(user, 'email').as_string() == 'user${i}@example.com'
		assert at(user, 'name').as_string() == 'renamed ${i}'
	}
}

fn test_articles() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	// the title and summary trimmed, the summary empty unless set
	created := data(base, 'mutation { createArticle(input: {userID: "${ada}", title: " One ", body: "text"}) { id title summary publishedAt author { name } } }')!
	assert at(created, 'createArticle').json().all_after('"title"') == ':"One","summary":"","publishedAt":null,"author":{"name":"Ada"}}'
	article := at(created, 'createArticle.id').as_string()
	// published, then not
	published := data(base, 'mutation { updateArticle(id: "${article}", input: {publishedAt: "2026-10-13T07:30:00Z", summary: " short "}) { summary publishedAt } }')!
	assert at(published, 'updateArticle').json() == '{"summary":"short","publishedAt":"2026-10-13T07:30:00.000Z"}'
	assert at(data(base, '{ articles(where: {publishedAtNotNil: true}) { totalCount } }')!, 'articles.totalCount').as_int() == 1
	unpublished := data(base, 'mutation { updateArticle(id: "${article}", input: {clearPublishedAt: true}) { publishedAt } }')!
	assert at(unpublished, 'updateArticle.publishedAt') is graphql.Null
	// the checks
	for input, message in {
		'title: " ", body: "x"':                                '`articles.title`: is empty'
		'title: "${'t'.repeat(201)}", body: "x"':               '`articles.title`: is longer than 200 bytes'
		'title: "x", summary: "${'s'.repeat(501)}", body: "x"': '`articles.summary`: is longer than 500 bytes'
		'title: "x", body: "  "':                               '`articles.body`: is blank'
	} {
		assert failure(base, 'mutation { createArticle(input: {userID: "${ada}", ${input}}) { id } }')! == message
	}
	// an author that doesn't exist
	assert failure(base, 'mutation { createArticle(input: {userID: "99", title: "x", body: "y"}) { id } }')! == 'FOREIGN KEY constraint failed'
	// a delete hides the article
	data(base, 'mutation { deleteArticle(id: "${article}") }')!
	assert at(data(base, '{ articles { totalCount } }')!, 'articles.totalCount').as_int() == 0
	assert failure(base, 'mutation { deleteArticle(id: "${article}") }')! == 'no `articles` row matches'
}

// An article by a deleted user still shows its author (Q112): deleted users
// are left out of queries, not of edges.
fn test_a_deleted_author_still_shows() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	create_article(base, ada, 'One')!
	create_post(base, ada, 'hi')!
	data(base, 'mutation { deleteUser(id: "${ada}") }')!
	assert data(base, '{ articles { edges { node { title author { name } } } } posts { edges { node { author { name } } } } users { totalCount } }')!.json() == '{"articles":{"edges":[{"node":{"title":"One","author":{"name":"Ada"}}}]},"posts":{"edges":[{"node":{"author":{"name":"Ada"}}}]},"users":{"totalCount":0}}'
}

fn test_posts() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	post := create_post(base, ada, 'hi')!
	assert at(data(base, 'mutation { updatePost(id: "${post}", input: {body: "hey"}) { body author { name } } }')!, 'updatePost').json() == '{"body":"hey","author":{"name":"Ada"}}'
	assert failure(base, 'mutation { createPost(input: {userID: "${ada}", body: " "}) { id } }')! == '`posts.body`: is blank'
	assert failure(base, 'mutation { createPost(input: {userID: "${ada}", body: "${'b'.repeat(2001)}"}) { id } }')! == '`posts.body`: is longer than 2000 bytes'
	data(base, 'mutation { deletePost(id: "${post}") }')!
	assert at(data(base, '{ posts { totalCount } }')!, 'posts.totalCount').as_int() == 0
}

fn test_comments_on_articles_and_posts() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	bob := create_user(base, 'Bob', 'bob@example.com')!
	article := create_article(base, ada, 'One')!
	post := create_post(base, bob, 'hi')!
	first := create_comment(base, bob, 'Article', article, '', 'nice')!
	create_comment(base, ada, 'Article', article, first, 'thanks')!
	on_post := create_comment(base, ada, 'Post', post, '', 'hey')!
	// a comment's owner, author, parent and replies
	got := data(base, '{ node(id: "${article}") { ... on Article { comments(orderBy: {field: ID}) { edges { node { body author { name } article { title } post { body } parent { body } replies { edges { node { body } } } } } } } } }')!
	assert nodes(got, 'node.comments').map(it.json()) == [
		'{"body":"nice","author":{"name":"Bob"},"article":{"title":"One"},"post":null,"parent":null,"replies":{"edges":[{"node":{"body":"thanks"}}]}}',
		'{"body":"thanks","author":{"name":"Ada"},"article":{"title":"One"},"post":null,"parent":{"body":"nice"},"replies":{"edges":[]}}',
	]
	assert nodes(data(base, '{ node(id: "${post}") { ... on Post { comments { edges { node { body post { body } } } } } } }')!,
		'node.comments').map(it.json()) == ['{"body":"hey","post":{"body":"hi"}}']
	// what each user wrote
	bobs := data(base, '{ node(id: "${bob}") { ... on User { articles { totalCount } posts { totalCount } comments { totalCount edges { node { body } } } } } }')!
	assert at(bobs, 'node').json() == '{"articles":{"totalCount":0},"posts":{"totalCount":1},"comments":{"totalCount":1,"edges":[{"node":{"body":"nice"}}]}}'
	// a deleted reply is left out of its parent's replies, and a comment can
	// be edited, but not moved
	data(base, 'mutation { updateComment(id: "${on_post}", input: {body: "hey!"}) { body } }')!
	assert failure(base, 'mutation { updateComment(id: "${on_post}", input: {ownerID: "${article}"}) { id } }')! == 'Field "ownerID" is not defined by type "UpdateCommentInput".'
	replies := nodes(data(base, '{ node(id: "${first}") { ... on Comment { replies { edges { node { id } } } } } }')!,
		'node.replies')
	data(base, 'mutation { deleteComment(id: "${at(replies[0], 'id').as_string()}") }')!
	assert at(data(base, '{ node(id: "${first}") { ... on Comment { replies { totalCount } } } }')!, 'node.replies.totalCount').as_int() == 0
	assert at(data(base, '{ comments { totalCount } }')!, 'comments.totalCount').as_int() == 2
}

fn test_comments_errors() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	article := create_article(base, ada, 'One')!
	other := create_article(base, ada, 'Two')!
	post := create_post(base, ada, 'hi')!
	on_other := create_comment(base, ada, 'Article', other, '', 'there')!
	comment := 'mutation { createComment(input: {userID: "${ada}", body: "x", '
	assert failure(base, comment + 'ownerType: "Page", ownerID: "${article}"}) { id } }')! == '`ownerType` is one of Article, Post'
	assert failure(base, comment + 'ownerType: "Post", ownerID: "${article}"}) { id } }')! == '`comments.owner_id`: no `Post` has the key `${article}`'
	assert failure(base, comment + 'ownerType: "Article", ownerID: "${post}"}) { id } }')! == '`comments.owner_id`: no `Article` has the key `${post}`'
	assert failure(base, comment + 'ownerType: "Article", ownerID: "${article}", parentID: "${on_other}"}) { id } }')! == 'a reply is on the owner of the comment it answers'
	assert failure(base, comment + 'ownerType: "Article", ownerID: "${article}", parentID: "${post}"}) { id } }')! == 'the parent comment ${post} not found'
	assert failure(base, 'mutation { createComment(input: {userID: "${ada}", ownerType: "Article", ownerID: "${article}", body: "  "}) { id } }')! == '`comments.body`: is blank'
	// a deleted owner takes no new comments, and its comments still show it
	data(base, 'mutation { deleteArticle(id: "${other}") }')!
	assert failure(base, comment + 'ownerType: "Article", ownerID: "${other}"}) { id } }')! == '`comments.owner_id`: no `Article` has the key `${other}`'
	assert at(data(base, '{ node(id: "${on_other}") { ... on Comment { article { title } } } }')!, 'node.article.title').as_string() == 'Two'
}

// Pages of a connection, ordered by a field, through the driver.
fn test_connections() {
	base := start()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	for title in ['C', 'A', 'E', 'B', 'D'] {
		create_article(base, ada, title)!
	}
	mut titles := []string{}
	mut after := ''
	for {
		cursor := if after != '' { ', after: "${after}"' } else { '' }
		page := data(base, '{ articles(first: 2, orderBy: {field: TITLE}${cursor}) { edges { node { title } } pageInfo { hasNextPage endCursor } } }')!
		titles << nodes(page, 'articles').map(at(it, 'title').as_string())
		if !at(page, 'articles.pageInfo.hasNextPage').as_bool() {
			break
		}
		after = at(page, 'articles.pageInfo.endCursor').as_string()
	}
	assert titles == ['A', 'B', 'C', 'D', 'E']
	last := data(base, '{ node(id: "${ada}") { ... on User { articles(last: 2, orderBy: {field: TITLE}) { edges { node { title } } pageInfo { hasPreviousPage } } } } }')!
	assert at(last, 'node.articles').json() == '{"edges":[{"node":{"title":"D"}},{"node":{"title":"E"}}],"pageInfo":{"hasPreviousPage":true}}'
}

// Each query runs a fixed set of selects, however many rows it returns:
// related records are read in one query per edge, never one per row.
fn test_queries_run_a_fixed_set_of_selects() {
	base, mut log := start_counting()!
	ada := create_user(base, 'Ada', 'ada@example.com')!
	bob := create_user(base, 'Bob', 'bob@example.com')!
	article := create_article(base, ada, 'One')!
	post := create_post(base, bob, 'hi')!
	first := create_comment(base, bob, 'Article', article, '', 'nice')!
	create_comment(base, ada, 'Article', article, first, 'thanks')!
	create_comment(base, ada, 'Post', post, '', 'hey')!
	comment := 'body author { name } parent { body } article { title } post { body }'
	queries := {
		'{ users { edges { node { name } } } }':                                                         [
			'users',
		]
		'{ users { edges { node { articles { totalCount edges { node { title } } } } } } }':             [
			'users',
			'articles',
			'sql',
		]
		'{ articles { edges { node { title author { name } } } } }':                                     [
			'articles',
			'users',
		]
		'{ node(id: "${article}") { ... on Article { comments { edges { node { ${comment} } } } } } }':  [
			'articles',
			'comments',
			'users',
			'comments',
			'articles',
		]
		'{ comments { totalCount edges { node { ${comment} replies { edges { node { body } } } } } } }': [
			'comments',
			'comments',
			'users',
			'comments',
			'articles',
			'posts',
			'comments',
		]
	}
	for query, want in queries {
		log.take()
		data(base, query)!
		assert log.take() == want, query
	}
	// the other paths, whose selects are recorded on this data: a post's
	// comments, each user edge as a connection, edge predicates, and `nodes`
	// across every table
	others := [
		'{ posts { totalCount edges { node { body author { name } comments { totalCount edges { node { body post { body } replies { totalCount } } } } } } } }',
		'{ users(first: 10) { totalCount edges { node { name articles(first: 2) { totalCount edges { node { title } } } posts(last: 1) { totalCount edges { node { body } } } comments(first: 1) { totalCount edges { node { body article { title } post { body } } } } } } } }',
		'{ comments(where: {hasArticle: true, hasAuthorWith: [{name: "Ada"}]}) { totalCount edges { node { body } } } articles(where: {hasCommentsWith: [{hasReplies: true}]}) { edges { node { title } } } }',
		'{ nodes(ids: ${all_ids(base)!}) { id ... on User { name } ... on Article { author { name } } ... on Post { comments { totalCount } } ... on Comment { article { title } post { body } } } }',
	]
	mut recorded := map[string][]string{}
	for query in others {
		log.take()
		data(base, query)!
		recorded[query] = log.take()
		assert recorded[query].len > 0
	}
	// more rows, the same selects
	for i in 0 .. 5 {
		user := create_user(base, 'User ${i}', 'user${i}@example.com')!
		more := create_article(base, user, 'More ${i}')!
		first_on := create_comment(base, ada, 'Article', more, '', 'and ${i}')!
		create_comment(base, user, 'Article', more, first_on, 'reply ${i}')!
		more_post := create_post(base, user, 'post ${i}')!
		on_post := create_comment(base, bob, 'Post', more_post, '', 'on post ${i}')!
		create_comment(base, user, 'Post', more_post, on_post, 'reply on post ${i}')!
	}
	for query, want in queries {
		log.take()
		data(base, query)!
		assert log.take() == want, query
	}
	for query in others {
		// `nodes` gets every id there is now
		now := if query.starts_with('{ nodes') {
			query.replace(query.find_between('nodes(ids: ', ') {'), all_ids(base)!)
		} else {
			query
		}
		log.take()
		data(base, now)!
		assert log.take() == recorded[query], query
	}
}

// all_ids returns the ids of every user, article, post and comment, as a
// GraphQL list.
fn all_ids(base string) !string {
	got := data(base, '{ users { edges { node { id } } } articles { edges { node { id } } } posts { edges { node { id } } } comments { edges { node { id } } } }')!
	mut ids := []string{}
	for table in ['users', 'articles', 'posts', 'comments'] {
		ids << nodes(got, table).map('"${at(it, 'id').as_string()}"')
	}
	return '[${ids.join(', ')}]'
}

// A request's mutations run in one transaction: when one fails, the ones
// before it are rolled back.
fn test_mutations_roll_back_together() {
	base := start()!
	res := gql(base, 'mutation { a: createUser(input: {name: "Cy", email: "cy@example.com"}) { id } b: createArticle(input: {userID: "99", title: "x", body: "y"}) { id } }')!
	assert at(res, 'errors.0.path').json() == '["b"]', res.str()
	assert at(data(base, '{ users { totalCount } }')!, 'users.totalCount').as_int() == 0, 'the user was rolled back'
	// a mutation can't be sent with GET
	get := http.get('${base}/graphql?query=mutation%7BdeleteUser(id%3A%221%22)%7D')!
	assert get.status_code == 405
}

fn test_seed() {
	base := start_with(seed: true)!
	got := data(base, '{ users { edges { node { name articles { totalCount } posts { totalCount } comments { totalCount } } } } comments(orderBy: {field: ID}) { edges { node { body parent { body } article { title } post { body } } } } }')!
	assert nodes(got, 'users').map(it.json()) == [
		'{"name":"Ada Lovelace","articles":{"totalCount":1},"posts":{"totalCount":1},"comments":{"totalCount":2}}',
		'{"name":"Grace Hopper","articles":{"totalCount":1},"posts":{"totalCount":1},"comments":{"totalCount":1}}',
	]
	assert nodes(got, 'comments').map(it.json()) == [
		'{"body":"Could it compose music?","parent":null,"article":{"title":"Notes on the Analytical Engine"},"post":null}',
		'{"body":"Elaborate pieces, of any degree of complexity.","parent":{"body":"Could it compose music?"},"article":{"title":"Notes on the Analytical Engine"},"post":null}',
		'{"body":"Congratulations!","parent":null,"article":null,"post":{"body":"Wrote a compiler this week."}}',
	]
}

// The example data goes into a database once: a second start on the same file
// adds nothing, even when every user was deleted.
fn test_seed_runs_once() {
	path := os.join_path(os.vtmp_dir(), 'service_seed_${os.getpid()}.db')
	os.rm(path) or {}
	defer {
		os.rm(path) or {}
	}
	cfg := app.Config{
		db_path: path
		seed:    true
	}
	base := start_with(cfg)!
	for user in nodes(data(base, '{ users { edges { node { id } } } }')!, 'users') {
		data(base, 'mutation { deleteUser(id: "${at(user, 'id').as_string()}") }')!
	}
	again := start_with(cfg)!
	assert data(again, '{ users { totalCount } articles { totalCount } }')!.json() == '{"users":{"totalCount":0},"articles":{"totalCount":2}}'
}

// edge_indexes returns the names of the indexes that vgraph's edges need.
fn edge_indexes(db sqlite.DB) ![]string {
	rows := db.exec("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE '%_idx' ORDER BY name")!
	return rows.map(it.vals[0])
}

// Startup migrates an empty database through v.migrations alone, and running it
// again on the same database is fine. The migration rolls back and applies
// again.
fn test_startup_migrates() {
	cfg := app.Config{
		seed: false
	}
	mut db := app.connect(cfg)!
	new_app_on(cfg, db, none)!
	new_app_on(cfg, db, none)!
	mut m := migrations.new(mut db)!
	assert m.status()!.map('${it.version} ${it.name} ${it.state}') == [
		'1 initial applied',
		'2 polymorphic_checks applied',
	]
	indexes := [
		'articles_user_id_idx',
		'comments_owner_type_owner_id_idx',
		'comments_parent_id_idx',
		'comments_user_id_idx',
		'posts_user_id_idx',
	]
	assert edge_indexes(db)! == indexes
	// each table has its range of global ids
	assert db.exec('SELECT id, name FROM vgraph_types ORDER BY id')!.map(it.vals.join(' ')) == [
		'1 articles',
		'2 comments',
		'3 posts',
		'4 users',
	]

	// the database checks a comment's owner too, for writes outside the app
	triggers := "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name"
	assert db.exec(triggers)!.map(it.vals[0]) == ['comments_owner_id_poly_insert',
		'comments_owner_id_poly_update']
	// (the trigger runs before the row's other checks, so the user can be any)
	if _ := db.exec_param_many('INSERT INTO comments ("Stamps.created_at", "Stamps.updated_at", user_id, owner_type, owner_id, body) VALUES (?, ?, ?, ?, ?, ?)',
		['2026-10-14 00:00:00', '2026-10-14 00:00:00', '1', 'Article', '9', 'x'])
	{
		assert false, 'article 9 does not exist'
	} else {
		assert err.msg().contains('comments.owner_id: no row of the type in owner_type has this key')
	}

	m.rollback(2)!
	assert m.status()!.map('${it.version} ${it.name} ${it.state}') == [
		'1 initial pending',
		'2 polymorphic_checks pending',
	]
	tables := "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('users', 'articles', 'posts', 'comments', 'vgraph_types')"
	assert db.exec(tables)!.len == 0
	assert edge_indexes(db)! == []
	assert db.exec(triggers)!.len == 0

	m.migrate()!
	assert db.exec(tables)!.len == 5
	assert edge_indexes(db)! == indexes
}

// The app answers the introspection query, which GraphiQL and Apollo's tools
// ask, exactly as graphql-js answers it for the same schema:
// testdata/introspection.json, which CI checks against graphql-js.
fn test_graphql_introspection_matches_graphql_js() {
	base := start()!
	res := http.fetch(
		url:    '${base}/graphql'
		method: .post
		data:   graphql.Value({
			'query': graphql.Value(graphql.introspection_query)
		}).json()
		header: http.new_header(key: .content_type, value: 'application/json')
	)!
	assert res.status_code == 200
	want := os.read_file(os.join_path(@DIR, 'testdata', 'introspection.json'))!
	assert res.body + '\n' == want
}
