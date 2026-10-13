module main

// End to end: writes a small project, runs `vgraph gen` on it, and runs that
// project's own test against the generated client. It needs this checkout
// installed as `five07.vgraph` (`~/.vmodules/five07/vgraph`), as CI does.
import os

const models = "module models

import time
import five07.vgraph

@[table: 'users']
pub struct User {
pub:
	id   int @[primary; sql: serial]
	name string
}

@[table: 'articles']
pub struct Article {
pub:
	id         int @[primary; sql: serial]
	user_id    int
	title      string
	deleted_at ?time.Time
}

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
		vgraph.Edge{
			name:       'tags'
			kind:       .many_to_many
			to:         'tags'
			column:     'article_id'
			through:    'article_tags'
			through_to: 'tag_id'
		},
	]
}

pub fn (u User) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:     'articles'
			kind:     .one_to_many
			to:       'articles'
			column:   'user_id'
			soft_del: 'deleted_at'
		},
	]
}

@[table: 'tags']
pub struct Tag {
pub:
	id   int @[primary; sql: serial]
	name string
}

pub fn (t Tag) edges() []vgraph.Edge {
	return []
}

@[table: 'article_tags']
pub struct ArticleTag {
pub:
	id         int @[primary; sql: serial]
	article_id int
	tag_id     int
}

@[table: 'comments']
pub struct Comment {
pub:
	id         int @[primary; sql: serial]
	owner_type string
	owner_id   int
	parent_id  ?int
	body       string
	deleted_at ?time.Time
}

pub fn (c Comment) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:     'article'
			kind:     .many_to_one
			to:       'articles'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Article'
		},
		vgraph.Edge{
			name:   'parent'
			kind:   .many_to_one
			to:     'comments'
			column: 'parent_id'
		},
		vgraph.Edge{
			name:     'replies'
			kind:     .one_to_many
			to:       'comments'
			column:   'parent_id'
			soft_del: 'deleted_at'
		},
	]
}
"

const project_test = "module main

import db.sqlite
import orm
import time
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
	mut db := sqlite.connect(':memory:')!
	sql db {
		create table models.User
		create table models.Article
		create table models.Tag
		create table models.ArticleTag
		create table models.Comment
	}!
	for name in ['ada', 'bob'] {
		u := models.User{
			name: name
		}
		sql db {
			insert u into models.User
		}!
	}
	// 1 'V tips' by ada, 2 'SQL' by bob, 3 'Old' by ada and deleted
	for a in [['1', 'V tips'], ['2', 'SQL'], ['1', 'Old']] {
		article := models.Article{
			user_id:    a[0].int()
			title:      a[1]
			deleted_at: if a[1] == 'Old' { ?time.Time(time.now()) } else { none }
		}
		sql db {
			insert article into models.Article
		}!
	}
	for name in ['v', 'db'] {
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
	for c in [['Article', '1', '0', 'a'], ['Article', '1', '1', 'b'], ['Post', '1', '0', 'c'],
		['Article', '1', '0', 'd']] {
		comment := models.Comment{
			owner_type: c[0]
			owner_id:   c[1].int()
			parent_id:  if c[2] != '0' { ?int(c[2].int()) } else { none }
			body:       c[3]
			deleted_at: if c[3] == 'd' { ?time.Time(time.now()) } else { none }
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
	return graph.Graph.new(conn)!, log
}

fn test_eager_loading_is_one_query_per_edge() {
	g, log := setup()!
	articles := g.articles().where_deleted_at_is_null().order_by_id().with_author().with_tags().with_comments(fn (q graph.CommentQuery) graph.CommentQuery {
		return q.with_replies().order_by_id_desc()
	}).all()!
	assert log.tables == ['articles', 'users', 'comments', 'comments', 'article_tags', 'tags']
	assert articles.map(it.article.title) == ['V tips', 'SQL']
	assert articles.map(if a := it.author { a.user.name } else { '' }) == ['ada', 'bob']
	assert articles[0].tags.map(it.tag.name) == ['v', 'db']
	assert articles[1].tags.map(it.tag.name) == ['db']
	assert articles[0].comments.map(it.comment.body) == ['b', 'a'], 'deleted and Post comments are left out'
	assert articles[0].comments[1].replies.map(it.comment.body) == ['b']
	assert articles[1].comments.len == 0
}

fn test_polymorphic_and_nullable_edges() {
	g, _ := setup()!
	comments := g.comments().with_article().with_parent().order_by_id().all()!
	assert comments.map(if a := it.article { a.article.title } else { '-' }) == ['V tips', 'V tips',
		'-', 'V tips']
	assert comments.map(if p := it.parent { p.comment.body } else { '-' }) == ['-', 'a', '-', '-']
}

fn test_predicates() {
	g, _ := setup()!
	assert g.articles().where_title_like('SQ%').all()!.map(it.article.title) == ['SQL']
	assert g.articles().where_id_in([1, 3]).order_by_id_desc().all()!.map(it.article.id) == [3, 1]
	assert g.articles().where_user_id(1).where_id_gt(1).all()!.map(it.article.id) == [3]
	assert g.articles().where_deleted_at_is_not_null().all()!.len == 1
	assert g.articles().order_by_id().limit(2).all()!.len == 2
	assert g.users().where_name('bob').first()!.user.id == 2
	g.users().where_name('cy').first() or {
		assert err is graph.NotFoundError
		assert err.msg() == 'no `users` row matches'
		return
	}
	assert false
}

fn test_traversal() {
	g, _ := setup()!
	article := g.articles().where_id(1).first()!
	assert article.query_comments().order_by_id().all()!.map(it.comment.body) == ['a', 'b']
	assert article.query_author().first()!.user.name == 'ada'
	assert article.query_tags()!.all()!.map(it.tag.name) == ['v', 'db']
	ada := g.users().where_id(1).first()!
	assert ada.query_articles().all()!.map(it.article.title) == ['V tips']
	on_post := g.comments().where_body('c').first()!
	assert on_post.query_article().all()!.len == 0, 'a Post comment has no article'
	assert on_post.query_parent().all()!.len == 0, 'no parent'
}

fn test_nodes_on_rows_you_have() {
	g, log := setup()!
	rows := [models.Comment{
		id:         2
		owner_type: 'Article'
		owner_id:   1
		parent_id:  1
	}]
	log.tables.clear()
	nodes := g.comments().with_parent().with_article().nodes(rows)!
	// edges load in the order they are declared, not the order asked for
	assert log.tables == ['articles', 'comments']
	assert nodes[0].parent?.comment.body == 'a'
}
"

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

	run(root, 'graph')!
	assert os.ls(os.join_path(root, 'graph'))!.sorted() == ['articles.v', 'comments.v', 'graph.v',
		'tags.v', 'users.v']

	// a stale generated file goes away; a hand-written one stays
	os.write_file(os.join_path(root, 'graph', 'old.v'), '${header()}\nmodule graph\n')!
	os.write_file(os.join_path(root, 'graph', 'mine.v'), 'module graph\n')!
	run(root, 'graph')!
	assert !os.exists(os.join_path(root, 'graph', 'old.v'))
	assert os.exists(os.join_path(root, 'graph', 'mine.v'))

	res := os.exec([@VEXE, '-stats', 'test', root])
	assert res.exit_code == 0, res.output
}

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
	run(root, 'graph') or {
		assert err.msg() == 'the schema has problems:\nas.bs: no table `nowhere` is registered'
		assert !os.exists(os.join_path(root, 'graph'))
		assert !os.exists(os.join_path(root, '.vgraph-gen')), 'the loader is cleaned up'
		return
	}
	assert false, 'gen should fail'
}
