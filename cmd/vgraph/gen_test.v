module main

// End to end: writes a small project, runs `vgraph gen` on it, and runs that
// project's own test against the generated client. It needs this checkout
// installed as `five07.vgraph` (`~/.vmodules/five07/vgraph`), as CI does.
import os

const models = 'module models

import context
import time
import five07.vgraph
import five07.vgraph.load

// Viewer is who a request runs as, in its context.
pub struct Viewer {
pub:
	banned bool
}

const viewer_key = \'viewer\'

// as_viewer returns a context that runs as `v`.
pub fn as_viewer(v Viewer) context.Context {
	return context.with_value(context.background(), viewer_key, v)
}

// viewer_of returns the viewer of `ctx`: no one banned when it has none.
pub fn viewer_of(ctx context.Context) Viewer {
	if value := ctx.value(viewer_key) {
		if value is Viewer {
			return value
		}
	}
	return Viewer{}
}

@[table: \'users\']
pub struct User {
pub:
	id            int @[primary; sql: serial]
	name          string
	password_hash string @[graphql: \'-\']
}

// Audit is left out of GraphQL, and so is every edge to it.
@[graphql: \'-\'; table: \'audits\']
pub struct Audit {
pub:
	id      int @[primary; sql: serial]
	user_id int
}

pub fn (a Audit) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   \'user\'
			kind:   .many_to_one
			to:     \'users\'
			column: \'user_id\'
		},
	]
}

@[table: \'articles\']
pub struct Article {
pub:
	id         int @[primary; sql: serial]
	user_id    int
	title      string
	deleted_at ?time.Time
}

// hooks gives an article without a title one.
pub fn (a Article) hooks() []vgraph.Hook {
	return [
		vgraph.on(vgraph.Hook{
			run: fn (next vgraph.Mutate) vgraph.Mutate {
				return fn [next] (ctx context.Context, mut m vgraph.Mutation) ! {
					if _ := m.field_value(\'title\') {
					} else {
						m.set_field_value(\'title\', \'Untitled\')
					}
					next(ctx, mut m)!
				}
			}
		}, .create),
	]
}

// fields: GraphQL\'s description of `title`, which an update can\'t set, and a
// directive on it.
pub fn (a Article) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:            \'title\'
			comment:         \'The title, Untitled when it is missing.\'
			graphql_skip_in: [.update_input]
			directives:      [\'@tag(name: "title")\']
		},
	]
}

// otel: articles record every span: their queries, writes, loads, hooks and
// privacy rules.
pub fn (a Article) otel() vgraph.Otel {
	return vgraph.Otel{
		level: .full
	}
}

// policy keeps articles from banned viewers.
pub fn (a Article) policy() vgraph.Policy {
	return vgraph.Policy{
		query: [
			fn (ctx context.Context, _ string, mut _ load.Query) !vgraph.Decision {
				return if viewer_of(ctx).banned { .deny } else { .skip }
			},
		]
	}
}

pub fn (a Article) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   \'author\'
			kind:   .many_to_one
			to:     \'users\'
			column: \'user_id\'
		},
		vgraph.Edge{
			name:     \'comments\'
			kind:     .one_to_many
			to:       \'comments\'
			column:   \'owner_id\'
			type_col: \'owner_type\'
			type_val: \'Article\'
			soft_del: \'deleted_at\'
		},
		vgraph.Edge{
			name:       \'tags\'
			kind:       .many_to_many
			to:         \'tags\'
			column:     \'article_id\'
			through:    \'article_tags\'
			through_to: \'tag_id\'
		},
	]
}

// fields: GraphQL marks `name` deprecated.
pub fn (u User) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:       \'name\'
			deprecated: \'Use the handle.\'
		},
	]
}

// otel: users record their queries, writes and loads.
pub fn (u User) otel() vgraph.Otel {
	return vgraph.Otel{
		level: .ops
	}
}

pub fn (u User) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:     \'articles\'
			kind:     .one_to_many
			to:       \'articles\'
			column:   \'user_id\'
			soft_del: \'deleted_at\'
		},
		vgraph.Edge{
			name:   \'audits\'
			kind:   .one_to_many
			to:     \'audits\'
			column: \'user_id\'
		},
	]
}

@[table: \'tags\']
pub struct Tag {
pub:
	id   int @[primary; sql: serial]
	name string
}

// otel: tags record what the app chooses when it runs.
pub fn (t Tag) otel() vgraph.Otel {
	return vgraph.Otel{
		level: .default
	}
}

pub fn (t Tag) edges() []vgraph.Edge {
	return []
}

// graphql renames tags in GraphQL, with a directive of api.graphql.
pub fn (t Tag) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		type_name:   \'Label\'
		query_field: \'labels\'
		directives:  [\'@tag(name: "public")\']
	}
}

@[table: \'article_tags\']
pub struct ArticleTag {
pub:
	id         int @[primary; sql: serial]
	article_id int
	tag_id     int
}

@[table: \'comments\']
pub struct Comment {
pub:
	id         int @[primary; sql: serial]
	owner_type string
	owner_id   int
	parent_id  ?int
	body       string
	deleted_at ?time.Time
}

// graphql: comments are only created through GraphQL.
pub fn (c Comment) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		mutations: [.create]
	}
}

pub fn (c Comment) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:     \'article\'
			kind:     .many_to_one
			to:       \'articles\'
			column:   \'owner_id\'
			type_col: \'owner_type\'
			type_val: \'Article\'
		},
		vgraph.Edge{
			name:   \'parent\'
			kind:   .many_to_one
			to:     \'comments\'
			column: \'parent_id\'
		},
		vgraph.Edge{
			name:     \'replies\'
			kind:     .one_to_many
			to:       \'comments\'
			column:   \'parent_id\'
			soft_del: \'deleted_at\'
		},
	]
}
'

const project_test = 'module main

import context
import db.sqlite
import orm
import time
import five07.otel.sdk.trace as sdk
import five07.vgraph
import five07.vgraph.graphql
import graph
import shop.models

@[heap]
struct Log {
mut:
	tables []string
}

struct Counting {
mut:
	inner orm.Connection
	log   &Log
}

fn (mut c Counting) select(config orm.SelectConfig, data orm.QueryData, where orm.QueryData) ![][]orm.Primitive {
	c.log.tables << config.table.name
	return c.inner.select(config, data, where)
}

fn (mut c Counting) insert(table orm.Table, data orm.QueryData) ! {
	c.inner.insert(table, data)!
}

fn (mut c Counting) update(table orm.Table, data orm.QueryData, where orm.QueryData) ! {
	c.inner.update(table, data, where)!
}

fn (mut c Counting) delete(table orm.Table, where orm.QueryData) ! {
	c.inner.delete(table, where)!
}

fn (mut c Counting) create(table orm.Table, fields []orm.TableField) ! {
	c.inner.create(table, fields)!
}

fn (mut c Counting) drop(table orm.Table) ! {
	c.inner.drop(table)!
}

fn (mut c Counting) last_id() int {
	return c.inner.last_id()
}

fn (mut c Counting) execute(query string) ![]orm.Row {
	return c.inner.execute(query)
}

fn setup() !(graph.Graph, &Log) {
	return setup_with()
}

fn setup_with(opts vgraph.ClientOptions) !(graph.Graph, &Log) {
	mut db := sqlite.connect(\':memory:\')!
	sql db {
		create table models.User
		create table models.Article
		create table models.Tag
		create table models.ArticleTag
		create table models.Comment
		create table models.Audit
	}!
	for name in [\'ada\', \'bob\'] {
		u := models.User{
			name: name
		}
		sql db {
			insert u into models.User
		}!
	}
	// 1 \'V tips\' by ada, 2 \'SQL\' by bob, 3 \'Old\' by ada and deleted
	for a in [[\'1\', \'V tips\'], [\'2\', \'SQL\'], [\'1\', \'Old\']] {
		article := models.Article{
			user_id:    a[0].int()
			title:      a[1]
			deleted_at: if a[1] == \'Old\' { ?time.Time(time.now()) } else { none }
		}
		sql db {
			insert article into models.Article
		}!
	}
	for name in [\'v\', \'db\'] {
		t := models.Tag{
			name: name
		}
		sql db {
			insert t into models.Tag
		}!
	}
	for p in [[1, 1], [1, 2], [2, 2]] {
		link := models.ArticleTag{
			article_id: p[0]
			tag_id:     p[1]
		}
		sql db {
			insert link into models.ArticleTag
		}!
	}
	// 1 on article 1; 2 answers 1; 3 on a Post 1; 4 on article 1, deleted
	for c in [[\'Article\', \'1\', \'0\', \'a\'], [\'Article\', \'1\', \'1\', \'b\'], [\'Post\', \'1\', \'0\', \'c\'],
		[\'Article\', \'1\', \'0\', \'d\']] {
		comment := models.Comment{
			owner_type: c[0]
			owner_id:   c[1].int()
			parent_id:  if c[2] != \'0\' { ?int(c[2].int()) } else { none }
			body:       c[3]
			deleted_at: if c[3] == \'d\' { ?time.Time(time.now()) } else { none }
		}
		sql db {
			insert comment into models.Comment
		}!
	}
	log := &Log{}
	conn := Counting{
		inner: db
		log:   log
	}
	return graph.Graph.new(conn, opts)!, log
}

// recorder returns a provider that keeps its spans, and the exporter that
// holds them.
fn recorder() !(&sdk.TracerProvider, &sdk.InMemoryExporter) {
	exporter := sdk.InMemoryExporter.new()
	provider := sdk.TracerProvider.new(processors: [sdk.SimpleSpanProcessor.new(exporter)])!
	return provider, exporter
}

fn span_named(spans []sdk.ReadOnlySpan, name string) !sdk.ReadOnlySpan {
	for s in spans {
		if s.name == name {
			return s
		}
	}
	return error(\'no span `\${name}` in \${spans.map(it.name)}\')
}

fn is_child(child sdk.ReadOnlySpan, parent sdk.ReadOnlySpan) bool {
	return child.parent.span_id == parent.span_context.span_id
}

fn attr(span sdk.ReadOnlySpan, key string) string {
	for kv in span.attributes {
		if kv.key == key {
			value := kv.value
			return match value {
				string { value }
				i64 { value.str() }
				else { value.str() }
			}
		}
	}
	return \'\'
}

// Each model records the spans of its level: articles everything, users their
// operations, comments nothing, tags what the client chooses.
fn test_spans_by_level() {
	provider, exporter := recorder()!
	g, _ := setup_with(tracer_provider: provider)!
	tracer := provider.tracer(\'test\')
	ctx, request := tracer.start(context.background(), \'request\')
	gc := g.with_ctx(ctx)
	articles := gc.articles().with_author().order_by_id().all()!
	gc.comments().all()!
	gc.users().count()!
	gc.tags().all()!
	request.end()
	spans := exporter.spans()
	root := span_named(spans, \'request\')!
	query := span_named(spans, \'query articles\')!
	assert is_child(query, root)
	assert attr(query, \'db.collection.name\') == \'articles\'
	assert attr(query, \'vgraph.operation\') == \'all\'
	assert attr(query, \'vgraph.rows\') == articles.len.str()
	// full: the policy\'s rules, under the query
	assert is_child(span_named(spans, \'privacy articles\')!, query)
	assert attr(span_named(spans, \'privacy articles\')!, \'vgraph.decision\') == \'skip\'
	// the query\'s statement and its edge load, under it; the load\'s statement
	// under the load
	assert is_child(span_named(spans, \'SELECT articles\')!, query)
	load := span_named(spans, \'load articles.author\')!
	assert is_child(load, query)
	assert attr(load, \'vgraph.batch_size\') == articles.len.str()
	assert is_child(span_named(spans, \'SELECT users\')!, load)
	// users are ops: their query, and no privacy span
	assert is_child(span_named(spans, \'query users\')!, root)
	// comments record nothing of their own; their statement is the request\'s
	assert \'query comments\' !in spans.map(it.name)
	assert is_child(span_named(spans, \'SELECT comments\')!, root)
	// tags are default: ops, by default
	assert is_child(span_named(spans, \'query tags\')!, root)
}

// A default model follows the client: `otel_level: .none` turns its spans off.
fn test_a_default_model_follows_the_client() {
	provider, exporter := recorder()!
	g, _ := setup_with(tracer_provider: provider, otel_level: .none)!
	g.tags().all()!
	g.users().all()!
	names := exporter.spans().map(it.name)
	assert \'query tags\' !in names
	assert \'query users\' in names
}

// A write is a span; a full model\'s hooks are spans inside it, and the write\'s
// statements are the innermost hook\'s.
fn test_write_and_hook_spans() {
	provider, exporter := recorder()!
	g, _ := setup_with(tracer_provider: provider)!
	g.articles().create().set_user_id(1).exec()!
	spans := exporter.spans()
	create := span_named(spans, \'create articles\')!
	assert attr(create, \'vgraph.operation\') == \'create\'
	hook := span_named(spans, \'hook articles\')!
	assert is_child(hook, create)
	assert attr(hook, \'vgraph.operation\') == \'create\'
	assert is_child(span_named(spans, \'INSERT articles\')!, hook)
	// a user\'s write has no hooks, and so no hook span
	exporter.reset()
	g.users().update_one_id(1).set_name(\'ada\').exec()!
	assert span_named(exporter.spans(), \'update users\')!.status.code == .unset
	assert \'hook users\' !in exporter.spans().map(it.name)
}

// A failure is the span\'s error, without its message.
fn test_a_failed_operation_is_an_error() {
	provider, exporter := recorder()!
	g, _ := setup_with(tracer_provider: provider)!
	g.with_ctx(models.as_viewer(models.Viewer{ banned: true })).articles().count() or {}
	query := span_named(exporter.spans(), \'query articles\')!
	assert query.status.code == .error
	assert query.status.description == \'\'
	privacy := span_named(exporter.spans(), \'privacy articles\')!
	assert privacy.status.code == .error
}

fn test_eager_loading_is_one_query_per_edge() {
	g, log := setup()!
	articles := g.articles().where_deleted_at_is_null().order_by_id().with_author().with_tags().with_comments(fn (q graph.CommentQuery) graph.CommentQuery {
		return q.with_replies().order_by_id_desc()
	}).all()!
	assert log.tables == [\'articles\', \'users\', \'comments\', \'comments\', \'article_tags\', \'tags\']
	assert articles.map(it.article.title) == [\'V tips\', \'SQL\']
	assert articles.map(if a := it.author { a.user.name } else { \'\' }) == [\'ada\', \'bob\']
	assert articles[0].tags.map(it.tag.name) == [\'v\', \'db\']
	assert articles[1].tags.map(it.tag.name) == [\'db\']
	assert articles[0].comments.map(it.comment.body) == [\'b\', \'a\'], \'deleted and Post comments are left out\'
	assert articles[0].comments[1].replies.map(it.comment.body) == [\'b\']
	assert articles[1].comments.len == 0
}

fn test_polymorphic_and_nullable_edges() {
	g, _ := setup()!
	comments := g.comments().with_article().with_parent().order_by_id().all()!
	assert comments.map(if a := it.article { a.article.title } else { \'-\' }) == [\'V tips\', \'V tips\',
		\'-\', \'V tips\']
	assert comments.map(if p := it.parent { p.comment.body } else { \'-\' }) == [\'-\', \'a\', \'-\', \'-\']
}

fn test_predicates() {
	g, _ := setup()!
	assert g.articles().where_title_like(\'SQ%\').all()!.map(it.article.title) == [\'SQL\']
	assert g.articles().where_id_in([1, 3]).order_by_id_desc().all()!.map(it.article.id) == [3, 1]
	assert g.articles().where_user_id(1).where_id_gt(1).all()!.map(it.article.id) == [3]
	assert g.articles().where_deleted_at_is_not_null().all()!.len == 1
	assert g.articles().order_by_id().limit(2).all()!.len == 2
	assert g.users().where_name(\'bob\').first()!.user.id == 2
	g.users().where_name(\'cy\').first() or {
		assert err is graph.NotFoundError
		assert err.msg() == \'no `users` row matches\'
		return
	}
	assert false
}

fn test_traversal() {
	g, _ := setup()!
	article := g.articles().where_id(1).first()!
	assert article.query_comments().order_by_id().all()!.map(it.comment.body) == [\'a\', \'b\']
	assert article.query_author().first()!.user.name == \'ada\'
	assert article.query_tags()!.all()!.map(it.tag.name) == [\'v\', \'db\']
	ada := g.users().where_id(1).first()!
	assert ada.query_articles().all()!.map(it.article.title) == [\'V tips\']
	on_post := g.comments().where_body(\'c\').first()!
	assert on_post.query_article().all()!.len == 0, \'a Post comment has no article\'
	assert on_post.query_parent().all()!.len == 0, \'no parent\'
}

fn test_nodes_on_rows_you_have() {
	g, log := setup()!
	rows := [models.Comment{
		id:         2
		owner_type: \'Article\'
		owner_id:   1
		parent_id:  1
	}]
	log.tables.clear()
	nodes := g.comments().with_parent().with_article().nodes(rows)!
	// edges load in the order they are declared, not the order asked for
	assert log.tables == [\'articles\', \'comments\']
	assert nodes[0].parent?.comment.body == \'a\'
}

fn test_graphql() {
	g, log := setup()!
	s := g.graphql(graph.Resolvers{})!
	log.tables.clear()
	res := s.execute(graphql.Request{
		query: \'{ hello articles(where: {deletedAtIsNil: true}, orderBy: {field: ID}) { title url author { name } tags { name } comments(orderBy: {field: BODY, direction: DESC}) { body replies { body } } } }\'
	}, context.background())
	assert res.json() == \'{"data":{"hello":"hello world","articles":[{"title":"V tips","url":"/articles/1","author":{"name":"ada"},"tags":[{"name":"v"},{"name":"db"}],"comments":[{"body":"b","replies":[]},{"body":"a","replies":[{"body":"b"}]}]},{"title":"SQL","url":"/articles/2","author":{"name":"bob"},"tags":[{"name":"db"}],"comments":[]}]}}\'
	// one select per edge per level
	assert log.tables == [\'articles\', \'users\', \'article_tags\', \'tags\', \'comments\', \'comments\']
	// hidden fields and tables are not in the schema
	assert !graph.schema_sdl.contains(\'passwordHash\')
	assert !graph.schema_sdl.contains(\'Audit\')
	failed := s.execute(graphql.Request{
		query: \'mutation { touch(id: "1") { title } }\'
	}, context.background())
	assert failed.errors.map(it.message) == [\'not now\']
}

// Writes on a connection without a vgraph driver, which runs no transactions:
// a polymorphic edge sets its type column too.
fn test_polymorphic_writes() {
	g, _ := setup()!
	e := g.comments().create().set_body(\'e\').set_article_id(2).save()!
	assert e.comment.owner_type == \'Article\'
	assert e.query_article().first()!.article.title == \'SQL\'
	// comment 3, on a Post, moves to article 2
	g.articles().update_one_id(2).add_comments_ids(3).exec()!
	assert g.articles().where_id(2).first()!.query_comments().order_by_id().all()!.map(it.comment.body) == [
		\'c\',
		\'e\',
	]
	// a comment always has an owner
	g.articles().update_one_id(2).remove_comments_ids(3).exec() or {
		assert err.msg() == \'`comments.owner_id` is not nullable, so `comments` can\\\'t lose a target; delete it, or point it elsewhere\'
		return
	}
	assert false
}

// The GraphQL options of the models: a renamed type and root field, a field
// left out of one input, directives, descriptions and deprecations, and
// mutations turned off; and a polymorphic edge\'s type, checked.
fn test_graphql_options() {
	g, _ := setup()!
	sdl := graph.schema_sdl
	assert sdl.contains("type Label @tag(name: \\"public\\") {")
	assert sdl.contains("labels(where: LabelWhereInput")
	assert sdl.contains("\\"\\"\\"The title, Untitled when it is missing.\\"\\"\\"\\n  title: String! @tag(name: \\"title\\")")
	assert sdl.contains("name: String! @deprecated(reason: \\"Use the handle.\\")")
	assert sdl.contains("createComment(") && !sdl.contains("updateComment(") && !sdl.contains("deleteComment(")
	s := g.graphql(graph.Resolvers{})!
	labels := s.execute(graphql.Request{
		query: "{ labels(orderBy: {field: NAME}) { __typename name } }"
	}, context.background())
	assert labels.json() == "{\\"data\\":{\\"labels\\":[{\\"__typename\\":\\"Label\\",\\"name\\":\\"db\\"},{\\"__typename\\":\\"Label\\",\\"name\\":\\"v\\"}]}}"
	no_title := s.execute(graphql.Request{
		query: "mutation { updateArticle(id: \\"1\\", input: {title: \\"x\\"}) { id } }"
	}, context.background())
	assert no_title.errors.map(it.message) == ["Field \\"title\\" is not defined by type \\"UpdateArticleInput\\"."]
	bad := s.execute(graphql.Request{
		query: "mutation { createComment(input: {ownerType: \\"Nope\\", ownerID: \\"1\\", body: \\"x\\"}) { id } }"
	}, context.background())
	assert bad.errors.map(it.message) == ["`ownerType` is one of Article"]
	made := s.execute(graphql.Request{
		query: "mutation { createComment(input: {ownerType: \\"Article\\", ownerID: \\"2\\", body: \\"x\\", parentID: \\"1\\"}) { body article { title } parent { body } } }"
	}, context.background())
	assert made.json() == "{\\"data\\":{\\"createComment\\":{\\"body\\":\\"x\\",\\"article\\":{\\"title\\":\\"SQL\\"},\\"parent\\":{\\"body\\":\\"a\\"}}}}"
	// the client\'s input, as the resolvers use it
	art := g.articles().create().set_input(graph.CreateArticleInput{
		user_id:  2
		title:    \'From an input\'
		tag_ids:  [1]
	}).save()!
	assert art.query_tags()!.all()!.map(it.tag.name) == [\'v\']
}

// Typed hooks and interceptors on the graph, the model\'s hook and policy, and
// privacy through GraphQL.
fn test_hooks_and_privacy() {
	g, _ := setup()!
	mut old := []string{}
	log := &old
	g.articles().use(fn [log] (next graph.ArticleMutate) graph.ArticleMutate {
		return fn [log, next] (ctx context.Context, mut m graph.ArticleMutation) ! {
			if title := m.title() {
				m.set_title(title.to_upper())
			}
			if m.operation() == .update_one {
				mut l := unsafe { log }
				l << m.old_title()!
			}
			next(ctx, mut m)!
		}
	})
	// the graph\'s hook runs before the model\'s, which sets a missing title
	assert g.articles().create().set_user_id(1).save()!.article.title == \'Untitled\'
	art := g.articles().create().set_user_id(1).set_title(\'hi\').save()!
	assert art.article.title == \'HI\'
	art.update().set_title(\'again\').exec()!
	assert old == [\'HI\']
	assert g.articles().where_id(art.article.id).first()!.article.title == \'AGAIN\'
	// a typed interceptor narrows every query of users, edge loads included
	g.users().intercept(fn (_ context.Context, q graph.UserQuery) !graph.UserQuery {
		return q.where_name(\'bob\')
	})
	assert g.users().all()!.map(it.user.name) == [\'bob\']
	assert g.articles().where_id_in([1, 2]).with_author().order_by_id().all()!.map(if a := it.author { a.user.name } else { \'-\' }) == [
		\'-\',
		\'bob\',
	]
	// privacy: the policy denies a banned viewer; GraphQL reports it at the field
	s := g.graphql(graph.Resolvers{})!
	res := s.execute(graphql.Request{
		query: \'{ articles { title } users { name } }\'
	}, models.as_viewer(models.Viewer{
		banned: true
	}))
	assert res.errors.map(it.message) == [\'privacy: query of `articles` denied\']
	assert res.json().contains(\'"path":["articles"]\')
	assert g.with_ctx(models.as_viewer(models.Viewer{})).articles().count()! == 5
	if _ := g.with_ctx(models.as_viewer(models.Viewer{ banned: true })).articles().count() {
		assert false
	} else {
		assert err is vgraph.PrivacyError
	}
}
'

fn test_gen_writes_a_working_client() {
	root := os.join_path(os.vtmp_dir(), 'vgraph_gen_test_${os.getpid()}')
	os.rmdir_all(root) or {}
	defer {
		os.rmdir_all(root) or {}
	}
	os.mkdir_all(os.join_path(root, 'shop', 'models'))!
	os.write_file(os.join_path(root, 'v.mod'), "Module {\n\tname: 'shop'\n\tversion: '0.0.0'\n}\n")!
	os.write_file(os.join_path(root, 'shop', 'models', 'models.v'), models)!
	os.write_file(os.join_path(root, 'main_test.v'), project_test)!

	os.write_file(os.join_path(root, 'api.graphql'), api_sdl)!
	run(root, 'graph', true)!
	assert os.ls(os.join_path(root, 'graph'))!.sorted() == ['articles.v', 'articles_mutation.v',
		'audits.v', 'audits_mutation.v', 'comments.v', 'comments_mutation.v', 'graph.v', 'graphql.v',
		'resolvers.v', 'schema.graphql', 'tags.v', 'tags_mutation.v', 'users.v', 'users_mutation.v']
	// a stub for each field api.graphql adds
	stubs := os.read_file(os.join_path(root, 'graph', 'resolvers.v'))!
	for method in ['query_hello', 'article_url', 'mutation_touch'] {
		assert stubs.contains(') ${method}('), method
	}
	// the stubs are the project's: written once, never overwritten
	os.write_file(os.join_path(root, 'graph', 'resolvers.v'), resolvers)!
	run(root, 'graph', true)!
	assert os.read_file(os.join_path(root, 'graph', 'resolvers.v'))! == resolvers
	// a new field gets a new stub, after what is there
	os.write_file(os.join_path(root, 'api.graphql'), api_sdl + 'extend type Label { slug: String! }\n')!
	run(root, 'graph', true)!
	with_stub := os.read_file(os.join_path(root, 'graph', 'resolvers.v'))!
	assert with_stub.starts_with(resolvers.trim_right('\n'))
	assert with_stub.contains(') label_slug(')
	os.write_file(os.join_path(root, 'api.graphql'), api_sdl)!
	os.write_file(os.join_path(root, 'graph', 'resolvers.v'), resolvers)!
	run(root, 'graph', true)!

	// a stale generated file goes away; a hand-written one stays
	os.write_file(os.join_path(root, 'graph', 'old.v'), '${header()}\nmodule graph\n')!
	os.write_file(os.join_path(root, 'graph', 'mine.v'), 'module graph\n')!
	run(root, 'graph', true)!
	assert !os.exists(os.join_path(root, 'graph', 'old.v'))
	assert os.exists(os.join_path(root, 'graph', 'mine.v'))

	// an operations folder holds operations, checked against the schema
	os.mkdir_all(os.join_path(root, 'web', 'operations'))!
	os.write_file(os.join_path(root, 'web', 'operations', 'titles.graphql'), 'query Titles { articles(orderBy: {field: ID}) { title ...Who } }\nfragment Who on Article { author { name } }\n')!
	run(root, 'graph', true)!

	res := os.exec([@VEXE, '-stats', 'test', root])
	assert res.exit_code == 0, res.output
}

const api_sdl = 'directive @tag(name: String!) on OBJECT | FIELD_DEFINITION

extend type Query {
  hello(name: String = \"world\"): String!
}

extend type Article {
  url: String!
}

extend type Mutation {
  touch(id: ID!): Article
}
'

const resolvers = "module graph

import context
import five07.vgraph.graphql

pub struct Resolvers {}

pub fn (r Resolvers) query_hello(_ context.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	return parents.map(graphql.Resolved(graphql.Value('hello ' + info.arg('name').as_string())))
}

pub fn (r Resolvers) article_url(_ context.Context, _ graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	return parents.map(graphql.Resolved(graphql.Value('/articles/' + (it as ArticleNode).article.id.str())))
}

pub fn (r Resolvers) mutation_touch(_ context.Context, _ graphql.FieldInfo, _ []graphql.Source) ![]graphql.Resolved {
	return error('not now')
}
"

fn header() string {
	return '// Code generated by vgraph gen. DO NOT EDIT.'
}

fn test_gen_reports_schema_problems() {
	root := os.join_path(os.vtmp_dir(), 'vgraph_gen_bad_${os.getpid()}')
	os.rmdir_all(root) or {}
	defer {
		os.rmdir_all(root) or {}
	}
	// a module path with no dot, imported without an alias
	os.mkdir_all(os.join_path(root, 'm'))!
	os.write_file(os.join_path(root, 'v.mod'), "Module {\n\tname: 'bad'\n\tversion: '0.0.0'\n}\n")!
	os.write_file(os.join_path(root, 'm', 'm.v'), "module m

import five07.vgraph

@[table: 'as']
pub struct A {
pub:
	id int @[primary; sql: serial]
}

pub fn (a A) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'bs'
			kind:   .one_to_many
			to:     'nowhere'
			column: 'a_id'
		},
	]
}
")!
	run(root, 'graph', true) or {
		assert err.msg() == 'the schema has problems:\nas.bs: no table `nowhere` is registered'
		assert !os.exists(os.join_path(root, 'graph'))
		assert !os.exists(os.join_path(root, '.vgraph-gen')), 'the loader is cleaned up'
		return
	}
	assert false, 'gen should fail'
}

fn test_gen_reports_graphql_problems_where_they_are() {
	root := os.join_path(os.vtmp_dir(), 'vgraph_gen_gql_${os.getpid()}')
	os.rmdir_all(root) or {}
	defer {
		os.rmdir_all(root) or {}
	}
	os.mkdir_all(os.join_path(root, 'shop', 'models'))!
	os.write_file(os.join_path(root, 'v.mod'), "Module {\n\tname: 'shop'\n\tversion: '0.0.0'\n}\n")!
	os.write_file(os.join_path(root, 'shop', 'models', 'models.v'), models)!
	os.mkdir_all(os.join_path(root, 'schema'))!
	os.write_file(os.join_path(root, 'schema', 'bad.graphql'), '# a mistake\nextend type Query {\n  x: Nope\n}\n')!
	os.write_file(os.join_path(root, 'schema', 'directives.graphql'), 'directive @tag(name: String!) on OBJECT | FIELD_DEFINITION\n')!
	run(root, 'graph', true) or {
		// the file and line of the mistake, not of the merged schema
		assert err.msg().starts_with('schema/bad.graphql:3:6: Unknown type "Nope".'), err.msg()
		return
	}
	assert false, 'gen should fail'
}

// An operation in a schema file would be dropped: vgraph gen reports it; and
// one in an operations folder that no longer fits the schema.
fn test_gen_checks_operations() {
	root := os.join_path(os.vtmp_dir(), 'vgraph_gen_ops_${os.getpid()}')
	os.rmdir_all(root) or {}
	defer {
		os.rmdir_all(root) or {}
	}
	os.mkdir_all(os.join_path(root, 'shop', 'models'))!
	os.write_file(os.join_path(root, 'v.mod'), "Module {\n\tname: 'shop'\n\tversion: '0.0.0'\n}\n")!
	os.write_file(os.join_path(root, 'shop', 'models', 'models.v'), models)!
	os.write_file(os.join_path(root, 'api.graphql'), api_sdl + '\nquery GetUser { users { name } }\n')!
	run(root, 'graph', true) or {
		assert err.msg() == 'api.graphql:15:1: the operation `GetUser` is not schema: put operations in an `operations` folder, which vgraph gen checks against the schema', err.msg()
		os.write_file(os.join_path(root, 'api.graphql'), api_sdl)!
		os.mkdir_all(os.join_path(root, 'operations'))!
		os.write_file(os.join_path(root, 'operations', 'users.graphql'), '# users\nquery Users {\n  users { name nickname }\n}\n')!
		run(root, 'graph', true) or {
			assert err.msg() == 'operations/users.graphql:3:16: Cannot query field "nickname" on type "User". Did you mean "name"?', err.msg()
			return
		}
		assert false, 'gen should fail on the operation'
	}
	assert false, 'gen should fail'
}

// `vgraph describe` on `examples/relations`, which has every schema option.
fn test_describe() {
	text := describe_project(os.real_path(os.join_path(@VMODROOT, 'examples', 'relations')),
		'graph')!
	assert text.contains('Gadget (gadgets):')
	assert text.contains('OwnedPet (pet_owners) (view):')
	for parts in [
		['Stamps.created_at', 'time.Time', 'immutable, default, from Stamps'],
		['color', 'Color (enum)', 'values red|green|blue'],
		['serial_no', 'Serial (string)'],
		['tags', 'json []string'],
		['owner', 'many_to_one', 'owner_id', 'ref gadgets, required, immutable'],
		['likers', 'many_to_many', 'likes.user_id', 'ref liked_gadgets'],
		['gadgets_rated_owner_idx', 'owner_id', 'rating IS NOT NULL'],
		['spouse', 'many_to_one', 'spouse_id', 'bidi'],
	] {
		assert text.split_into_lines().any(fn [parts] (line string) bool {
			return parts.all(line.contains(it))
		}), parts.str()
	}
	// pets have a soft-delete hook and interceptor, groups a policy
	pets := text.all_after('Pet (pets):').all_before('\n\n')
	assert pets.contains('hooks: 1, interceptors: 1, policy rules: 0')
	groups := text.all_after('Group (groups):').all_before('\n\n')
	assert groups.contains('policy rules: 1, otel: full')
	assert pets.contains('otel: none')
}

// `--no-graphql` writes the client alone.
fn test_gen_without_graphql() {
	root := os.join_path(os.vtmp_dir(), 'vgraph_plain_test_${os.getpid()}')
	os.rmdir_all(root) or {}
	defer {
		os.rmdir_all(root) or {}
	}
	os.mkdir_all(os.join_path(root, 'shop', 'models'))!
	os.write_file(os.join_path(root, 'v.mod'), "Module {\n\tname: 'shop'\n\tversion: '0.0.0'\n}\n")!
	os.write_file(os.join_path(root, 'shop', 'models', 'models.v'), models)!
	run(root, 'graph', false)!
	files := os.ls(os.join_path(root, 'graph'))!
	assert 'graph.v' in files && 'articles.v' in files
	assert 'graphql.v' !in files && 'schema.graphql' !in files && 'resolvers.v' !in files
}
