module vgraph

import db.sqlite
import time
import v.migrations

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
		Edge{
			name:   'profile'
			kind:   .one_to_one
			to:     'profiles'
			column: 'user_id'
		},
	]
}

@[table: 'profiles']
struct Profile {
	id      int @[primary; sql: serial]
	user_id int
	bio     string
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
	s.add[Profile]()!
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
		create table Profile
	}!
	// only ada has a profile
	profile := Profile{
		user_id: 1
		bio:     'hi'
	}
	sql db {
		insert profile into Profile
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
	assert s.tables().map(it.name) == ['users', 'articles', 'comments', 'tags', 'profiles']
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
			'users.profile: no table `profiles` is registered',
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
	assert articles.keys().sorted() == ['1', '2'], 'the Post comment is not followed'
	authors := c.load_one[Article, User](articles.values(), 'author')!
	assert authors['1'].name == 'ada'
}

fn test_load_many() {
	c := client()!
	users := sql c.conn {
		select from User order by id
	}!
	articles := c.load_many[User, Article](users, 'articles')!
	assert articles['1'].map(it.title) == ['by 1', 'by 1']
	assert '2' !in articles, 'soft-deleted articles are skipped'
	all := sql c.conn {
		select from Article order by id
	}!
	comments := c.load_many[Article, Comment](all, 'comments')!
	assert comments['1'].map(it.body) == ['Article 1'], 'only comments on articles'
	assert comments['2'].map(it.body) == ['Article 2']
	tags := c.load_many[Article, Tag](all, 'tags')!
	assert tags['1'].map(it.name) == ['v', 'sql']
	assert tags['2'].map(it.name) == ['sql']
	assert '3' !in tags
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

fn test_migration_indexes() {
	s := schema()!
	assert s.migration_indexes().map('${it.name} ${it.table} ${it.columns} ${it.unique}') == [
		"article_tags_article_id_idx article_tags ['article_id'] false",
		"article_tags_article_id_tag_id_idx article_tags ['article_id', 'tag_id'] true",
		"articles_user_id_idx articles ['user_id'] false",
		"comments_owner_type_owner_id_idx comments ['owner_type', 'owner_id'] false",
		"profiles_user_id_idx profiles ['user_id'] true",
	]
}

fn test_foreign_keys() {
	s := schema()!
	// none on comments.owner_id, which the polymorphic edges use
	assert s.foreign_keys()!.map('${it.name}: ${it.from_table}.${it.column} -> ${it.to_table}.${it.primary_key}') == [
		'article_tags_article_id_fkey: article_tags.article_id -> articles.id',
		'article_tags_tag_id_fkey: article_tags.tag_id -> tags.id',
		'articles_user_id_fkey: articles.user_id -> users.id',
		'profiles_user_id_fkey: profiles.user_id -> users.id',
	]
}

fn test_join_table() {
	s := schema()!
	t := s.join_table('articles', 'tags')!
	assert t.name == 'article_tags'
	assert t.id
	assert t.columns.map('${it.name} ${it.kind} ${it.nullable or { true }}') == [
		'article_id integer false',
		'tag_id integer false',
	]
	assert t.foreign_keys.map(it.name) == ['article_tags_article_id_fkey', 'article_tags_tag_id_fkey']
	if _ := s.join_table('articles', 'author') {
		assert false
	} else {
		assert err.msg() == '`articles.author` is many_to_one; only a many_to_many edge has a join table'
	}
}

// edge_migration creates the tables of `schema()`, the join table from
// `join_table`, and the edges' indexes; its down removes the indexes only.
fn edge_migration(s Schema) migrations.Migration {
	return migrations.Migration{
		version: 1
		name:    'edges'
		up:      fn [s] (mut ctx migrations.Context) ! {
			migrations.create_orm_table[User](mut ctx)!
			migrations.create_orm_table[Article](mut ctx)!
			migrations.create_orm_table[Comment](mut ctx)!
			migrations.create_orm_table[Tag](mut ctx)!
			migrations.create_orm_table[Profile](mut ctx)!
			ctx.create_table(s.join_table('articles', 'tags')!)!
			add_edge_indexes(mut ctx, s)!
		}
		down:    fn [s] (mut ctx migrations.Context) ! {
			remove_edge_indexes(mut ctx, s)!
		}
	}
}

fn edge_index_names(mut db sqlite.DB) ![]string {
	rows := db.exec("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE '%_idx' ORDER BY name")!
	return rows.map(it.vals[0])
}

fn test_migrate_adds_and_removes_edge_indexes() {
	s := schema()!
	mut db := sqlite.connect(':memory:')!
	db.exec('PRAGMA foreign_keys = ON')!
	mut m := migrations.new(mut db, [edge_migration(s)], dialect: .sqlite)!
	m.migrate()!
	assert edge_index_names(mut db)! == s.migration_indexes().map(it.name)
	// the join table's keys are checked, and a pair is stored once (through
	// `exec_param_many`: `exec` ignores errors raised while a statement runs)
	link := 'INSERT INTO article_tags (article_id, tag_id) VALUES (?, ?)'
	db.exec_param_many('INSERT INTO articles (user_id, title) VALUES (?, ?)', ['1', 'a'])!
	db.exec_param_many('INSERT INTO tags (name) VALUES (?)', ['v'])!
	db.exec_param_many(link, ['1', '1'])!
	if _ := db.exec_param_many(link, ['1', '1']) {
		assert false, 'a pair is stored once'
	}
	if _ := db.exec_param_many(link, ['1', '9']) {
		assert false, 'tag 9 does not exist'
	}
	m.rollback(1)!
	assert edge_index_names(mut db)! == []
}

// Gadget is keyed by a UUID, and linked to people through a join table.
@[table: 'gadgets']
struct Gadget {
	id   string @[primary; sql_type: 'uuid']
	name string
}

fn (g Gadget) edges() []Edge {
	return [
		Edge{
			name:       'people'
			kind:       .many_to_many
			to:         'people'
			column:     'gadget_id'
			through:    'gadget_people'
			through_to: 'person_id'
		},
	]
}

fn test_join_table_key_types() {
	mut s := Schema{}
	s.add[Gadget]()!
	s.add[Person]()!
	s.add[Session]()!
	s.add[Device]()!
	assert s.table('gadgets')!.column('id')?.sql_type == 'uuid'
	t := s.join_table('gadgets', 'people')!
	assert t.columns.map('${it.name} ${it.kind}') == ['gadget_id uuid', 'person_id integer']
}

fn test_load_one_to_one() {
	c := client()!
	users := sql c.conn {
		select from User order by id
	}!
	profiles := c.load_many[User, Profile](users, 'profile')!
	assert profiles['1'].map(it.bio) == ['hi']
	assert '2' !in profiles
}

fn test_a_one_to_one_index_is_unique_only_alone() {
	mut s := Schema{}
	s.add[Profile]()!
	s.add[ProfileOwner]()!
	// `ProfileOwner.profiles` needs the same index, and it isn't unique
	assert s.migration_indexes().map(it.unique) == [false]
}

@[table: 'profile_owners']
struct ProfileOwner {
	id int @[primary; sql: serial]
}

fn (o ProfileOwner) edges() []Edge {
	return [
		Edge{
			name:   'profile'
			kind:   .one_to_one
			to:     'profiles'
			column: 'user_id'
		},
		Edge{
			name:   'profiles'
			kind:   .one_to_many
			to:     'profiles'
			column: 'user_id'
		},
	]
}

// Person is a table with no edges of its own.
@[table: 'people']
struct Person {
	id   int @[primary; sql: serial]
	name string
}

// Device is keyed by a UUID string, and its sessions refer to it by that key.
@[table: 'devices']
struct Device {
	id      string @[primary]
	user_id int
	name    string
}

fn (d Device) edges() []Edge {
	return [
		Edge{
			name:   'sessions'
			kind:   .one_to_many
			to:     'sessions'
			column: 'device_id'
		},
		Edge{
			name:   'owner'
			kind:   .many_to_one
			to:     'people'
			column: 'user_id'
		},
	]
}

@[table: 'sessions']
struct Session {
	id        i64 @[primary; sql: serial]
	device_id string
	started   time.Time
}

fn (s Session) edges() []Edge {
	return [
		Edge{
			name:   'device'
			kind:   .many_to_one
			to:     'devices'
			column: 'device_id'
		},
	]
}

fn test_string_keys() {
	mut s := Schema{}
	s.add[Person]()!
	s.add[Device]()!
	s.add[Session]()!
	assert s.table('devices')!.column('id')?.kind == .string
	assert s.table('sessions')!.column('id')?.kind == .i64
	mut db := sqlite.connect(':memory:')!
	sql db {
		create table Person
		create table Device
		create table Session
	}!
	person := Person{
		name: 'ada'
	}
	device := Device{
		id:      'a3c1f0e2-5b7d-4e8a-9c6f-2d1b0a9e8f73'
		user_id: 1
		name:    'phone'
	}
	session := Session{
		device_id: device.id
		started:   time.now()
	}
	sql db {
		insert person into Person
		insert device into Device
		insert session into Session
		insert session into Session
	}!
	c := Client.new(db, s)!
	devices := c.load_one[Session, Device]([session], 'device')!
	assert devices[device.id].name == 'phone'
	sessions := c.load_many[Device, Session]([device], 'sessions')!
	assert sessions[device.id].map(it.id) == [i64(1), 2]
	owners := c.load_one[Device, Person]([device], 'owner')!
	assert owners['1'].name == 'ada'
}

fn test_validate_checks_key_types() {
	mut s := Schema{}
	s.add[Person]()!
	s.add[Device]()!
	s.add[BadKeys]()!
	s.add[TimeKeyed]()!
	s.validate() or {
		assert err.msg().split('\n') == [
			'devices.sessions: no table `sessions` is registered',
			'bad_keys.device: `column` names `bad_keys.device_id`, which is not a string column',
			'bad_keys.user: `column` names `bad_keys.user_name`, which is not an int column',
			'bad_keys.timed: the key `time_keyed.id` is time.Time; edges need an int, i64 or string key',
		]
		return
	}
	assert false, 'the schema should be rejected'
}

@[table: 'bad_keys']
struct BadKeys {
	id        int @[primary; sql: serial]
	device_id int
	user_name string
}

fn (b BadKeys) edges() []Edge {
	return [
		// devices are keyed by strings
		Edge{
			name:   'device'
			kind:   .many_to_one
			to:     'devices'
			column: 'device_id'
		},
		// users are keyed by ints
		Edge{
			name:   'user'
			kind:   .many_to_one
			to:     'people'
			column: 'user_name'
		},
		Edge{
			name:   'timed'
			kind:   .many_to_one
			to:     'time_keyed'
			column: 'device_id'
		},
	]
}

@[table: 'time_keyed']
struct TimeKeyed {
	id time.Time @[primary]
}
