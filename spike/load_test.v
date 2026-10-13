import db.sqlite
import load
import orm

@[table: 'articles']
struct Article {
	id    int @[primary; sql: serial]
	title string
}

@[table: 'comments']
struct Comment {
	id    int @[primary; sql: serial]
	owner int @[sql: 'owner_id']
	body  string
}

fn seed() !sqlite.DB {
	mut db := sqlite.connect(':memory:')!
	sql db {
		create table Article
		create table Comment
	}!
	for title in ['a', 'b', 'c', 'd'] {
		article := Article{
			title: title
		}
		sql db {
			insert article into Article
		}!
	}
	// articles 1 and 2 get two comments each, 3 gets none, and 4 one that is not loaded.
	for owner in [1, 1, 2, 2, 4] {
		comment := Comment{
			owner: owner
			body:  'on ${owner}'
		}
		sql db {
			insert comment into Comment
		}!
	}
	return db
}

fn test_load_many_runs_one_query_for_three_articles() {
	db := seed()!
	mut conn := load.CountingConnection{
		inner: db
	}
	articles := [Article{ id: 1 }, Article{ id: 2 }, Article{ id: 3 }, Article{ id: 2 }]
	comments := load.load_many[Article, Comment](conn, articles, 'owner_id')!
	assert conn.log.selects == ['comments']
	assert comments.keys().len == 2
	assert comments[1].map(it.body) == ['on 1', 'on 1']
	assert comments[2].len == 2
	assert 3 !in comments
	assert 4 !in comments
}

fn test_load_many_with_no_parents_runs_no_query() {
	db := seed()!
	mut conn := load.CountingConnection{
		inner: db
	}
	comments := load.load_many[Article, Comment](conn, []Article{}, 'owner_id')!
	assert comments.len == 0
	assert conn.log.selects.len == 0
}

fn test_reflection_reads_keys_and_columns() {
	assert load.primary_key[Article]() == 'id'
	assert load.keys_of[Article]([Article{ id: 3 }, Article{ id: 1 }, Article{ id: 3 }])! == [
		3,
		1,
	]
	assert load.int_column[Comment](Comment{ owner: 7 }, 'owner_id')? == 7
	assert load.int_column[Comment](Comment{ owner: 7 }, 'owner') == none
}

fn test_select_in_without_new_query() {
	db := seed()!
	mut conn := load.CountingConnection{
		inner: db
	}
	mut c := orm.Connection(conn)
	comments := load.select_in[Comment](mut c, 'owner_id', [2, 4])!
	assert conn.log.selects == ['comments']
	assert comments.map(it.owner) == [2, 2, 4]
	assert comments[0].body == 'on 2'
	assert comments[0].id == 3
}
