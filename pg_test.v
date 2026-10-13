// vtest build: vgraph_pg?
module vgraph

// Runs the edge kinds against PostgreSQL, whose SQL differs from SQLite's in
// placeholders and types. It runs only with `-d vgraph_pg`, not whenever a
// PostgreSQL process happens to be running: `v -d vgraph_pg test pg_test.v`, with
// `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE` set if the
// defaults below don't match the server.
import db.pg
import os
import time

@[table: 'vg_users']
struct PgUser {
	id         int @[primary; sql: serial]
	name       string
	deleted_at ?time.Time
}

fn (u PgUser) edges() []Edge {
	return [
		Edge{
			name:     'articles'
			kind:     .one_to_many
			to:       'vg_articles'
			column:   'user_id'
			soft_del: 'deleted_at'
		},
	]
}

@[table: 'vg_articles']
struct PgArticle {
	id         int @[primary; sql: serial]
	user_id    int
	title      string
	deleted_at ?time.Time
}

fn (a PgArticle) edges() []Edge {
	return [
		Edge{
			name:   'author'
			kind:   .many_to_one
			to:     'vg_users'
			column: 'user_id'
		},
		Edge{
			name:     'comments'
			kind:     .one_to_many
			to:       'vg_comments'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Article'
		},
		Edge{
			name:       'tags'
			kind:       .many_to_many
			to:         'vg_tags'
			column:     'article_id'
			through:    'vg_article_tags'
			through_to: 'tag_id'
		},
	]
}

@[table: 'vg_comments']
struct PgComment {
	id         int @[primary; sql: serial]
	owner_type string
	owner_id   int
	parent_id  ?int
	body       string
	created_at time.Time
}

fn (c PgComment) edges() []Edge {
	return [
		Edge{
			name:     'article'
			kind:     .many_to_one
			to:       'vg_articles'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Article'
		},
		Edge{
			name:   'parent'
			kind:   .many_to_one
			to:     'vg_comments'
			column: 'parent_id'
		},
	]
}

@[table: 'vg_tags']
struct PgTag {
	id   int @[primary; sql: serial]
	name string
}

@[table: 'vg_article_tags']
struct PgArticleTag {
	id         int @[primary; sql: serial]
	article_id int
	tag_id     int
}

fn pg_client() !Client {
	mut db := pg.connect(pg.Config{
		host:     os.getenv_opt('PGHOST') or { 'localhost' }
		port:     (os.getenv_opt('PGPORT') or { '5432' }).int()
		user:     os.getenv_opt('PGUSER') or { 'postgres' }
		password: os.getenv_opt('PGPASSWORD') or { '12345678' }
		dbname:   os.getenv_opt('PGDATABASE') or { 'postgres' }
	}, pg.PoolConfig{})!
	db.exec('SET client_min_messages = warning')!
	for table in ['vg_article_tags', 'vg_tags', 'vg_comments', 'vg_articles', 'vg_users'] {
		db.exec('DROP TABLE IF EXISTS ${table}')!
	}
	sql db {
		create table PgUser
		create table PgArticle
		create table PgComment
		create table PgTag
		create table PgArticleTag
	}!
	for name in ['ada', 'bob'] {
		user := PgUser{
			name: name
		}
		sql db {
			insert user into PgUser
		}!
	}
	// articles 1 and 2 by ada, 3 by bob and deleted
	for n in [1, 1, 2] {
		article := PgArticle{
			user_id:    n
			title:      'by ${n}'
			deleted_at: if n == 2 { ?time.Time(time.now()) } else { none }
		}
		sql db {
			insert article into PgArticle
		}!
	}
	// comment 3 answers comment 1
	for c in [['Article', '1', '0'], ['Post', '1', '0'], ['Article', '2', '1']] {
		comment := PgComment{
			owner_type: c[0]
			owner_id:   c[1].int()
			parent_id:  if c[2] != '0' { ?int(c[2].int()) } else { none }
			body:       '${c[0]} ${c[1]}'
			created_at: time.now()
		}
		sql db {
			insert comment into PgComment
		}!
	}
	for name in ['v', 'sql'] {
		tag := PgTag{
			name: name
		}
		sql db {
			insert tag into PgTag
		}!
	}
	for pair in [[1, 1], [1, 2], [2, 2]] {
		link := PgArticleTag{
			article_id: pair[0]
			tag_id:     pair[1]
		}
		sql db {
			insert link into PgArticleTag
		}!
	}
	mut s := Schema{}
	s.add[PgUser]()!
	s.add[PgArticle]()!
	s.add[PgComment]()!
	s.add[PgTag]()!
	return Client.new(db, s)!
}

fn test_postgres_edges() {
	c := pg_client()!
	users := sql c.conn {
		select from PgUser order by id
	}!
	articles := sql c.conn {
		select from PgArticle order by id
	}!
	comments := sql c.conn {
		select from PgComment order by id
	}!

	by_user := c.load_many[PgUser, PgArticle](users, 'articles')!
	assert by_user['1'].map(it.title) == ['by 1', 'by 1']
	assert '2' !in by_user, 'soft-deleted articles are skipped'

	authors := c.load_one[PgArticle, PgUser](articles, 'author')!
	assert authors.keys().sorted() == ['1', '2']

	on_article := c.load_many[PgArticle, PgComment](articles, 'comments')!
	assert on_article['1'].map(it.body) == ['Article 1']
	assert on_article['2'].map(it.body) == ['Article 2']
	assert on_article['2'][0].parent_id or { 0 } == 1
	assert on_article['2'][0].created_at.year >= 2026

	owners := c.load_one[PgComment, PgArticle](comments, 'article')!
	assert owners.keys().sorted() == ['1', '2'], 'the Post comment is not followed'
	parents := c.load_one[PgComment, PgComment](comments, 'parent')!
	assert parents.keys() == ['1']

	tags := c.load_many[PgArticle, PgTag](articles, 'tags')!
	assert tags['1'].map(it.name) == ['v', 'sql']
	assert tags['2'].map(it.name) == ['sql']
}

fn test_postgres_ensure_indexes() {
	c := pg_client()!
	mut conn := c.conn
	assert c.ensure_indexes()!.len == 3
	c.ensure_indexes()!
	rows := conn.execute("SELECT indexname FROM pg_indexes WHERE indexname LIKE 'vg_%_idx' ORDER BY indexname")!
	assert rows.map(it.vals[0]) == ['vg_article_tags_article_id_idx', 'vg_articles_user_id_idx',
		'vg_comments_owner_type_owner_id_idx']
}
