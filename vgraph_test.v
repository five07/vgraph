module vgraph

import db.sqlite
import time

@[table: 'users']
struct User {
	id         int @[primary; sql: serial]
	name       string
	deleted_at ?time.Time
}

fn (u User) edges() []Edge {
	return [
		Edge{
			name:     'articles'
			kind:     .one_to_many
			to:       'articles'
			column:   'user_id'
			soft_del: 'deleted_at'
		},
	]
}

@[table: 'articles']
struct Article {
	id         int @[primary; sql: serial]
	user_id    int
	title      string
	deleted_at ?time.Time
}

fn (a Article) edges() []Edge {
	return [
		Edge{
			name:   'author'
			kind:   .many_to_one
			to:     'users'
			column: 'user_id'
		},
		Edge{
			name:     'comments'
			kind:     .one_to_many
			to:       'comments'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Article'
		},
		Edge{
			name:       'tags'
			kind:       .many_to_many
			to:         'tags'
			column:     'article_id'
			through:    'article_tags'
			through_to: 'tag_id'
		},
	]
}

@[table: 'comments']
struct Comment {
	id         int @[primary; sql: serial]
	owner_type string
	owner_id   int
	body       string
}

fn (c Comment) edges() []Edge {
	return [
		Edge{
			name:     'article'
			kind:     .many_to_one
			to:       'articles'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Article'
		},
	]
}

@[table: 'tags']
struct Tag {
	id   int @[primary; sql: serial]
	name string
}

@[table: 'article_tags']
struct ArticleTag {
	id         int @[primary; sql: serial]
	article_id int
	tag_id     int
}

fn schema() !Schema {
	mut s := Schema{}
	s.add[User]()!
	s.add[Article]()!
	s.add[Comment]()!
	s.add[Tag]()!
	return s
}

fn client() !Client {
	mut db := sqlite.connect(':memory:')!
	sql db {
		create table User
		create table Article
		create table Comment
		create table Tag
		create table ArticleTag
	}!
	for name in ['ada', 'bob'] {
		user := User{
			name: name
		}
		sql db {
			insert user into User
		}!
	}
	// articles 1 and 2 by ada, 3 by bob and deleted
	for n in [1, 1, 2] {
		article := Article{
			user_id:    n
			title:      'by ${n}'
			deleted_at: if n == 2 { ?time.Time(time.now()) } else { none }
		}
		sql db {
			insert article into Article
		}!
	}
	for owner in [['Article', '1'], ['Post', '1'], ['Article', '2']] {
		comment := Comment{
			owner_type: owner[0]
			owner_id:   owner[1].int()
			body:       '${owner[0]} ${owner[1]}'
		}
		sql db {
			insert comment into Comment
		}!
	}
	for name in ['v', 'sql'] {
		tag := Tag{
			name: name
		}
		sql db {
			insert tag into Tag
		}!
	}
	for pair in [[1, 1], [1, 2], [2, 2]] {
		link := ArticleTag{
			article_id: pair[0]
			tag_id:     pair[1]
		}
		sql db {
			insert link into ArticleTag
		}!
	}
	return Client.new(db, schema()!)!
}

fn test_add_reflects_tables_and_edges() {
	s := schema()!
	article := s.table('articles')!
	assert article.key == 'id'
	assert article.struct_ == 'vgraph.Article'
	assert article.column('user_id')?.kind == .int
	assert article.column('deleted_at')?.nullable
	assert article.column('deleted_at')?.typ == '?time.Time'
	assert article.columns.map(it.name) == ['id', 'user_id', 'title', 'deleted_at']
	assert s.tables().map(it.name) == ['users', 'articles', 'comments', 'tags']
	assert article.edges.map(it.name) == ['author', 'comments', 'tags']
	assert s.table('tags')!.edges.len == 0
	s.validate()!
}

fn test_add_rejects_a_table_twice() {
	mut s := Schema{}
	s.add[User]()!
	s.add[User]() or {
		assert err.msg() == 'table `users` is registered twice'
		return
	}
	assert false
}

fn test_validate_reports_every_problem() {
	mut s := Schema{}
	s.add[BadEdges]()!
	s.add[User]()!
	s.validate() or {
		assert err.msg().split('\n') == [
			'bad.missing: no table `nowhere` is registered',
			'bad.wrong_column: `column` names `bad.nope`, which does not exist',
			'bad.text_key: `column` names `bad.name`, which is not an int column',
			'bad.half_poly: `type_col` and `type_val` go together',
			'bad.half_poly: declared twice',
			'bad.no_join: a many_to_many edge needs `through` and `through_to`',
			'bad.bad_soft_del: `soft_del` names `users.name`, which is not nullable',
			'users.articles: no table `articles` is registered',
		]
		return
	}
	assert false, 'the schema should be rejected'
}

@[table: 'bad']
struct BadEdges {
	id      int @[primary; sql: serial]
	user_id int
	name    string
}

fn (b BadEdges) edges() []Edge {
	return [
		Edge{
			name:   'missing'
			kind:   .many_to_one
			to:     'nowhere'
			column: 'user_id'
		},
		Edge{
			name:   'wrong_column'
			kind:   .many_to_one
			to:     'users'
			column: 'nope'
		},
		Edge{
			name:   'text_key'
			kind:   .many_to_one
			to:     'users'
			column: 'name'
		},
		Edge{
			name:     'half_poly'
			kind:     .many_to_one
			to:       'users'
			column:   'user_id'
			type_col: 'name'
		},
		Edge{
			name:   'half_poly'
			kind:   .many_to_one
			to:     'users'
			column: 'user_id'
		},
		Edge{
			name:   'no_join'
			kind:   .many_to_many
			to:     'users'
			column: 'user_id'
		},
		Edge{
			name:     'bad_soft_del'
			kind:     .many_to_one
			to:       'users'
			column:   'user_id'
			soft_del: 'name'
		},
	]
}

fn test_load_one() {
	c := client()!
	comments := sql c.conn {
		select from Comment order by id
	}!
	articles := c.load_one[Comment, Article](comments, 'article')!
	assert articles.keys().sorted() == [1, 2], 'the Post comment is not followed'
	authors := c.load_one[Article, User](articles.values(), 'author')!
	assert authors[1].name == 'ada'
}

fn test_load_many() {
	c := client()!
	users := sql c.conn {
		select from User order by id
	}!
	articles := c.load_many[User, Article](users, 'articles')!
	assert articles[1].map(it.title) == ['by 1', 'by 1']
	assert 2 !in articles, 'soft-deleted articles are skipped'
	all := sql c.conn {
		select from Article order by id
	}!
	comments := c.load_many[Article, Comment](all, 'comments')!
	assert comments[1].map(it.body) == ['Article 1'], 'only comments on articles'
	assert comments[2].map(it.body) == ['Article 2']
	tags := c.load_many[Article, Tag](all, 'tags')!
	assert tags[1].map(it.name) == ['v', 'sql']
	assert tags[2].map(it.name) == ['sql']
	assert 3 !in tags
}

fn test_load_errors() {
	c := client()!
	if _ := c.load_many[User, Comment]([User{ id: 1 }], 'articles') {
		assert false
	} else {
		assert err.msg() == '`users.articles` leads to `articles`, not `comments`'
	}
	if _ := c.load_one[Article, User]([Article{}], 'nope') {
		assert false
	} else {
		assert err.msg() == '`articles` has no edge `nope`'
	}
	if _ := c.load_one[User, Article]([User{}], 'articles') {
		assert false
	} else {
		assert err.msg() == '`users.articles` is one_to_many; use `load_many`'
	}
	if _ := c.load_many[Article, User]([Article{}], 'author') {
		assert false
	} else {
		assert err.msg() == '`articles.author` is many_to_one; use `load_one`'
	}
	if _ := c.load_one[Tag, User]([Tag{}], 'x') {
		assert false
	} else {
		assert err.msg() == '`tags` has no edge `x`'
	}
}

fn test_indexes() {
	s := schema()!
	assert s.indexes().map(it.sql()) == [
		'CREATE INDEX IF NOT EXISTS "article_tags_article_id_idx" ON "article_tags" ("article_id")',
		'CREATE INDEX IF NOT EXISTS "articles_user_id_idx" ON "articles" ("user_id")',
		'CREATE INDEX IF NOT EXISTS "comments_owner_type_owner_id_idx" ON "comments" ("owner_type", "owner_id")',
	]
}

fn test_ensure_indexes_creates_them_once() {
	c := client()!
	mut conn := c.conn
	assert c.ensure_indexes()!.len == 3
	c.ensure_indexes()!
	rows := conn.execute("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE '%_idx' ORDER BY name")!
	assert rows.map(it.vals[0]) == ['article_tags_article_id_idx', 'articles_user_id_idx',
		'comments_owner_type_owner_id_idx']
}
