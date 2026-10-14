// vtest build: vgraph_pg?
module vgraph

// Runs the edge kinds against PostgreSQL, whose SQL differs from SQLite's in
// placeholders and types. It runs only with `-d vgraph_pg`, not whenever a
// PostgreSQL process happens to be running: `v -d vgraph_pg test pg_test.v`, with
// `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE` set if the
// defaults below don't match the server.
import db.pg
import load
import orm
import os
import pg as vpg
import time
import v.migrations

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

// The tables the tests use, in an order they can be dropped in.
const pg_tables = ['vg_schema_migrations', 'vg_article_tags', 'vg_tags', 'vg_comments', 'vg_articles',
	'vg_users']

fn pg_config() pg.Config {
	return pg.Config{
		host:     os.getenv_opt('PGHOST') or { 'localhost' }
		port:     (os.getenv_opt('PGPORT') or { '5432' }).int()
		user:     os.getenv_opt('PGUSER') or { 'postgres' }
		password: os.getenv_opt('PGPASSWORD') or { '12345678' }
		dbname:   os.getenv_opt('PGDATABASE') or { 'postgres' }
	}
}

fn pg_schema() !Schema {
	mut s := Schema{}
	s.add[PgUser]()!
	s.add[PgArticle]()!
	s.add[PgComment]()!
	s.add[PgTag]()!
	return s
}

fn pg_client() !Client {
	return Client.new(pg_seeded()!, pg_schema()!)!
}

// pg_seeded returns a pool on a database with the tests' tables, seeded.
fn pg_seeded() !&pg.DB {
	mut db := pg.connect(pg_config(), pg.PoolConfig{})!
	db.exec('SET client_min_messages = warning')!
	for table in pg_tables {
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
	return db
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

// The migration helpers on PostgreSQL, which `v.migrations` runs on a direct
// connection (`pg.connect_direct`), not a pool: the tables, the join table from
// `join_table`, the other foreign keys with `add_foreign_key`, then the indexes.
fn test_postgres_migration_helpers() {
	mut db := pg.connect_direct(pg_config())!
	defer {
		db.close() or {}
	}
	db.exec('SET client_min_messages = warning')!
	for table in pg_tables {
		db.exec('DROP TABLE IF EXISTS ${table}')!
	}
	s := pg_schema()!
	join := s.join_table('vg_articles', 'tags')!
	mut m := migrations.new(mut db, [
		migrations.Migration{
			version: 1
			name:    'edges'
			up:      fn [s, join] (mut ctx migrations.Context) ! {
				migrations.create_orm_table[PgUser](mut ctx)!
				migrations.create_orm_table[PgArticle](mut ctx)!
				migrations.create_orm_table[PgComment](mut ctx)!
				migrations.create_orm_table[PgTag](mut ctx)!
				ctx.create_table(join)!
				for key in s.foreign_keys()! {
					if key.from_table != join.name {
						ctx.add_foreign_key(key)!
					}
				}
				add_edge_indexes(mut ctx, s)!
				add_polymorphic_checks(mut ctx, s)!
			}
			down:    fn [s] (mut ctx migrations.Context) ! {
				remove_polymorphic_checks(mut ctx, s)!
				remove_edge_indexes(mut ctx, s)!
			}
		},
	], dialect: .pg, table: 'vg_schema_migrations')!
	m.migrate()!
	indexes := "SELECT indexname FROM pg_indexes WHERE indexname LIKE 'vg_%_idx' ORDER BY indexname"
	assert db.exec(indexes)!.map(it.vals[0] or { '' }) == s.migration_indexes().map(it.name)
	keys := db.exec("SELECT conname FROM pg_constraint WHERE contype = 'f' AND conname LIKE 'vg_%' ORDER BY conname")!
	assert keys.map(it.vals[0] or { '' }) == [
		'vg_article_tags_article_id_fkey',
		'vg_article_tags_tag_id_fkey',
		'vg_articles_user_id_fkey',
		'vg_comments_parent_id_fkey',
	]
	assert s.foreign_keys()!.map(it.name) == keys.map(it.vals[0] or { '' })
	// a comment's owner is checked by a trigger
	triggers := "SELECT tgname FROM pg_trigger WHERE tgname LIKE 'vg_%_poly' ORDER BY tgname"
	assert db.exec(triggers)!.map(it.vals[0] or { '' }) == ['vg_comments_owner_id_poly']
	db.exec("INSERT INTO vg_users (name) VALUES ('ada')")!
	db.exec("INSERT INTO vg_articles (user_id, title) VALUES (1, 'a')")!
	comment := 'INSERT INTO vg_comments (owner_type, owner_id, body, created_at) VALUES'
	db.exec("${comment} ('Article', 1, 'ok', now())")!
	for values in ["'Article', 9", "'Post', 1"] {
		if _ := db.exec("${comment} (${values}, 'bad', now())") {
			assert false, values
		} else {
			assert err.msg().contains('vg_comments.owner_id: no row of the type in owner_type has this key')
		}
	}
	if _ := db.exec('UPDATE vg_comments SET owner_id = 9') {
		assert false
	}
	m.rollback(1)!
	assert db.exec(indexes)!.len == 0
	assert db.exec(triggers)!.len == 0
	assert db.exec("SELECT 1 FROM pg_proc WHERE proname = 'vg_comments_owner_id_poly'")!.len == 0
}

// The writes check a polymorphic edge's key against the table its type
// names, through the driver.
fn test_postgres_polymorphic_writes() {
	c := Client.new(vpg.pool(pg_seeded()!), pg_schema()!)!
	comment := fn [c] (typ string, owner int) !string {
		return c.create(MutationData{
			op:     .create
			table:  'vg_comments'
			values: {
				'owner_type': orm.Primitive(typ)
				'owner_id':   owner
				'body':       'new'
				'created_at': time.now()
			}
		})
	}
	assert comment('Article', 2)! == '4'
	if _ := comment('Article', 9) {
		assert false
	} else {
		assert err.msg() == '`vg_comments.owner_id`: no `Article` has the key `9`'
	}
	if _ := comment('Post', 1) {
		assert false
	} else {
		assert err.msg() == '`vg_comments.owner_type`: is `Post`, not one of `Article`'
	}
}

// Writes through the driver on a pool: a multi-row insert returns its keys in
// order, and a transaction holds one connection of the pool, whose writes
// the pool's other connections don't see until it commits.
fn test_postgres_writes_on_a_pool() {
	db := pg_seeded()!
	c := Client.new(vpg.pool(db), pg_schema()!)!
	keys := c.create_bulk(['go', 'zig', 'odin'].map(MutationData{
		op:     .create
		table:  'vg_tags'
		values: {
			'name': orm.Primitive(it)
		}
	}))!
	assert keys == ['3', '4', '5']
	article := c.create(MutationData{
		op:     .create
		table:  'vg_articles'
		values: {
			'user_id': orm.Primitive(2)
			'title':   'new'
		}
		added:  {
			'tags': ['3', '5']
		}
	})!
	assert article == '4'
	links := load.select_where[PgArticleTag](c.conn, load.Query{
		conds: [load.eq('article_id', 4)]
		order: 'tag_id'
	})!
	assert links.map(it.tag_id) == [3, 5]
	tx := c.begin()!
	assert tx.update(MutationData{
		op:     .update
		table:  'vg_articles'
		conds:  [load.eq('user_id', 1)]
		values: {
			'title': orm.Primitive('renamed')
		}
	})! == 2
	inside := load.count_where[PgArticle](tx.conn, load.Query{
		conds: [load.eq('title', 'renamed')]
	})!
	outside := load.count_where[PgArticle](c.conn, load.Query{
		conds: [load.eq('title', 'renamed')]
	})!
	assert [inside, outside] == [2, 0]
	tx.rollback()!
	assert load.count_where[PgArticle](c.conn, load.Query{
		conds: [load.eq('title', 'renamed')]
	})! == 0
	// a delete takes the article's join rows
	assert c.delete_one(MutationData{
		op:      .delete_one
		table:   'vg_articles'
		row_key: article
	})!
	assert load.count_where[PgArticleTag](c.conn, load.Query{
		conds: [load.eq('article_id', 4)]
	})! == 0
}

@[table: 'vg_first_ids']
struct PgFirstId {
	id   i64 @[primary; sql: serial]
	name string
}

@[table: 'vg_second_ids']
struct PgSecondId {
	id   i64 @[primary; sql: serial]
	name string
}

// Global ids on PostgreSQL: each table's BIGSERIAL starts at its own range,
// which a table keeps when a later migration adds another.
fn test_postgres_global_ids() {
	mut db := pg.connect_direct(pg_config())!
	defer {
		db.close() or {}
	}
	db.exec('SET client_min_messages = warning')!
	for table in ['vg_id_migrations', 'vgraph_types', 'vg_first_ids', 'vg_second_ids'] {
		db.exec('DROP TABLE IF EXISTS ${table}')!
	}
	mut first := Schema{}
	first.add[PgFirstId]()!
	mut both := Schema{}
	both.add[PgSecondId]()!
	both.add[PgFirstId]()!
	mut m := migrations.new(mut db, [
		migrations.Migration{
			version: 1
			name:    'first'
			up:      fn [first] (mut ctx migrations.Context) ! {
				create_table(mut ctx, first, 'vg_first_ids')!
				global_ids(mut ctx, first)!
			}
			down:    fn (mut ctx migrations.Context) ! {}
		},
		migrations.Migration{
			version: 2
			name:    'second'
			up:      fn [both] (mut ctx migrations.Context) ! {
				create_table(mut ctx, both, 'vg_second_ids')!
				global_ids(mut ctx, both)!
			}
			down:    fn (mut ctx migrations.Context) ! {}
		},
	], dialect: .pg, table: 'vg_id_migrations')!
	m.migrate()!
	c := Client.new(vpg.direct(db), both)!
	first_key := c.create(MutationData{
		table:  'vg_first_ids'
		values: {
			'name': orm.Primitive('a')
		}
	})!
	second_key := c.create(MutationData{
		table:  'vg_second_ids'
		values: {
			'name': orm.Primitive('b')
		}
	})!
	assert first_key.i64() == (i64(1) << 32) + 1
	assert second_key.i64() == (i64(2) << 32) + 1
	assert c.table_of(first_key.i64())! == 'vg_first_ids'
	assert c.table_of(second_key.i64())! == 'vg_second_ids'
}
