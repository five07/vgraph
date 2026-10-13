module vgraph

import db.sqlite as sq
import graphql
import load
import orm
import sqlite
import time

@[table: 'authors']
struct Author {
	id   int @[primary; sql: serial]
	name string
}

fn (a Author) edges() []Edge {
	return [
		Edge{
			name:   'posts'
			kind:   .one_to_many
			to:     'posts'
			column: 'author_id'
		},
	]
}

// Post's hooks write their names into `trail`, so a stored row shows which
// hooks ran, in which order.
@[table: 'posts']
struct Post {
	id         int @[primary; sql: serial]
	author_id  ?int
	title      string
	slug       string
	trail      string
	views      int
	deleted_at ?time.Time
}

fn (p Post) edges() []Edge {
	return [
		Edge{
			name:   'author'
			kind:   .many_to_one
			to:     'authors'
			column: 'author_id'
		},
	]
}

fn (p Post) fields() []Field {
	return [
		Field{
			name:      'title'
			not_empty: true
		},
		Field{
			name:    'trail'
			default: fn () orm.Primitive {
				return ''
			}
		},
		Field{
			name:    'views'
			default: fn () orm.Primitive {
				return 0
			}
		},
	]
}

fn (p Post) hooks() []Hook {
	return [
		trail_hook('model'),
		// a slug from the title, when the create has none
		on(Hook{
			run: fn (next Mutate) Mutate {
				return fn [next] (ctx graphql.Context, mut m Mutation) ! {
					if _ := m.field_value('slug') {
					} else {
						title := m.field_value('title') or { orm.Primitive('') }
						m.set_field_value('slug', (title as string).to_lower().replace(' ', '-'))
					}
					next(ctx, mut m)!
				}
			}
		}, .create),
		soft_delete_hook('deleted_at'),
	]
}

fn (p Post) interceptors() []Interceptor {
	return [soft_delete_query('deleted_at')]
}

fn (p Post) policy() Policy {
	return Policy{
		mutation: [
			fn (_ graphql.Context, m Mutation) !Decision {
				title := m.field_value('title') or { return .skip }
				return if title == orm.Primitive('forbidden') { .deny } else { .skip }
			},
		]
	}
}

// trail_hook appends `name` to the `trail` of the write, before the rest runs.
fn trail_hook(name string) Hook {
	return Hook{
		name: name
		run:  fn [name] (next Mutate) Mutate {
			return fn [name, next] (ctx graphql.Context, mut m Mutation) ! {
				trail := m.field_value('trail') or { orm.Primitive('') }
				m.set_field_value('trail', '${trail as string}/${name}')
				next(ctx, mut m)!
			}
		}
	}
}

fn hook_schema() !Schema {
	mut s := Schema{}
	s.add[Author]()!
	s.add[Post]()!
	return s
}

fn hook_db() !sq.DB {
	db := sq.connect(':memory:')!
	sql db {
		create table Author
		create table Post
	}!
	return db
}

fn hook_clients() ![]Client {
	s := hook_schema()!
	return [Client.new(hook_db()!, s)!, Client.new(sqlite.new(hook_db()!), s)!]
}

fn new_post(c Client, title string) !string {
	return c.create(MutationData{
		table:  'posts'
		values: {
			'title': orm.Primitive(title)
		}
	})
}

// posts returns the posts a query of `c` sees, its interceptors applied.
fn posts(c Client) ![]Post {
	return load.select_where[Post](c.conn, c.prepare_query('posts', load.Query{ order: 'id' })!)
}

@[heap]
struct Events {
mut:
	items []string
}

fn (e &Events) add(item string) {
	mut events := unsafe { e }
	events.items << item
}

fn test_hooks_run_in_order() {
	for c in hook_clients()! {
		c.use(trail_hook('graph'))
		c.use_on('posts', trail_hook('table'))
		c.use_on('authors', trail_hook('other table'))
		new_post(c, 'First Post')!
		row := posts(c)![0]
		assert row.trail == '/graph/table/model'
		assert row.slug == 'first-post', 'a hook set it'
		// skipped by name
		c.skip('graph', 'model').create(MutationData{
			table:  'posts'
			values: {
				'title': orm.Primitive('b')
				'slug':  'own'
			}
		})!
		assert posts(c)![1].trail == '/table'
		assert posts(c)![1].slug == 'own'
	}
}

fn test_on_only_if_and_unless() {
	for c in hook_clients()! {
		c.use_on('posts', on(trail_hook('on update'), .update_one),
			only_if(trail_hook('if long'), fn (_ graphql.Context, m Mutation) bool {
				title := m.field_value('title') or { return false }
				return (title as string).len > 5
			}), unless(trail_hook('unless long'), fn (_ graphql.Context, m Mutation) bool {
				title := m.field_value('title') or { return false }
				return (title as string).len > 5
			}))
		key := new_post(c, 'short')!
		new_post(c, 'longer one')!
		assert posts(c)!.map(it.trail) == ['/unless long/model', '/if long/model']
		c.update_one(MutationData{
			table:   'posts'
			row_key: key
			values:  {
				'views': orm.Primitive(1)
			}
		})!
		// the update sets no title: `only_if` is false, `unless` true; it sets a
		// new trail
		assert posts(c)![0].trail == '/on update/unless long/model'
	}
}

fn test_a_hook_error_stops_the_write() {
	for c in hook_clients()! {
		c.use_on('posts', Hook{
			run: fn (next Mutate) Mutate {
				return fn [next] (ctx graphql.Context, mut m Mutation) ! {
					next(ctx, mut m)!
					// after the insert: the transaction rolls it back
					if m.key() == '2' {
						return error('no second post')
					}
				}
			}
		})
		new_post(c, 'one')!
		new_post(c, 'two') or { assert err.msg() == 'no second post' }
		if c.conn is Driver || c.conn is orm.TransactionalConnection {
			assert posts(c)!.map(it.title) == ['one']
		}
	}
}

fn test_what_a_hook_sees() {
	for c in hook_clients()! {
		events := &Events{}
		ada := c.create(MutationData{
			table:  'authors'
			values: {
				'name': orm.Primitive('ada')
			}
		})!
		for title in ['a', 'b', 'c'] {
			new_post(c, title)!
		}
		c.use_on('posts', Hook{
			run: fn [events] (next Mutate) Mutate {
				return fn [events, next] (ctx graphql.Context, mut m Mutation) ! {
					match m.operation() {
						.update {
							events.add('keys ${m.keys()!}')
						}
						.update_one {
							events.add('old title ${m.old_field('title')!}, old author ${m.old_field('author_id')!}')
							// a hook can change edges and conditions too
							m.where(load.ne('title', 'b'))
						}
						else {}
					}
					next(ctx, mut m)!
					events.add('${m.operation()} ${m.key()}')
				}
			}
		})
		assert c.update(MutationData{
			table:  'posts'
			conds:  [load.ne('title', 'a')]
			values: {
				'views': orm.Primitive(2)
			}
		})! == 2
		assert c.update_one(MutationData{
			table:   'posts'
			row_key: '1'
			values:  {
				'title': orm.Primitive('a2')
			}
		})!
		assert !c.update_one(MutationData{
			table:   'posts'
			row_key: '2'
			values:  {
				'title': orm.Primitive('b2')
			}
		})!, "the hook's condition leaves post 2 out"
		assert events.items == [
			"keys ['2', '3']",
			'update ',
			"old title Primitive('a'), old author Primitive(orm.Null{})",
			'update_one 1',
			"old title Primitive('b'), old author Primitive(orm.Null{})",
			'update_one 2',
		]
		// a hook on authors adds every post to the author it creates
		c.use_on('authors', Hook{
			run: fn (next Mutate) Mutate {
				return fn [next] (ctx graphql.Context, mut m Mutation) ! {
					m.add_ids('posts', '1', '2', '3')
					next(ctx, mut m)!
				}
			}
		})
		bob := c.create(MutationData{
			table:  'authors'
			values: {
				'name': orm.Primitive('bob')
			}
		})!
		assert posts(c)!.map(it.author_id or { 0 }) == [bob.int(), bob.int(), bob.int()]
		assert ada == '1'
	}
}

fn test_transaction_hooks() {
	for c in hook_clients()! {
		events := &Events{}
		c.use_on('posts', Hook{
			run: fn [events] (next Mutate) Mutate {
				return fn [events, next] (ctx graphql.Context, mut m Mutation) ! {
					title := m.field_value('title') or { orm.Primitive('') }
					m.on_commit(fn [events, title] () {
						events.add('committed ${title as string}')
					})
					m.on_rollback(fn [events, title] () {
						events.add('rolled back ${title as string}')
					})
					next(ctx, mut m)!
				}
			}
		})
		// a write of its own
		new_post(c, 'alone')!
		new_post(c, '') or {}
		assert events.items == ['committed alone', 'rolled back ']
		events.add('-')
		// inside a transaction, they wait for it
		mut tx := c.begin()!
		new_post(tx, 'in tx')!
		tx.on_commit(fn [events] () {
			events.add('tx committed')
		})
		assert events.items.last() == '-'
		tx.commit()!
		assert events.items[events.items.len - 2..] == ['committed in tx', 'tx committed']
		tx = c.begin()!
		new_post(tx, 'dropped')!
		tx.rollback()!
		assert events.items.last() == 'rolled back dropped'
	}
}

fn test_interceptors_and_skip() {
	for c in hook_clients()! {
		for title in ['a', 'b', 'c'] {
			new_post(c, title)!
		}
		c.intercept(Interceptor{
			name: 'not a'
			run:  fn (_ graphql.Context, _ string, mut q load.Query) ! {
				q.conds << load.ne('title', 'a')
			}
		})
		c.intercept_on('posts', Interceptor{
			run: fn (_ graphql.Context, table string, mut q load.Query) ! {
				assert table == 'posts'
				q.conds << load.ne('title', 'c')
			}
		})
		assert posts(c)!.map(it.title) == ['b']
		assert posts(c.skip('not a'))!.map(it.title) == ['a', 'b']
		assert posts(c.bypass())!.map(it.title) == ['a', 'b', 'c']
	}
}

fn test_soft_delete() {
	for c in hook_clients()! {
		for title in ['a', 'b', 'c'] {
			new_post(c, title)!
		}
		assert c.delete_one(MutationData{
			table:   'posts'
			row_key: '1'
		})!
		// deleted rows are left out of queries, updates and deletes
		assert posts(c)!.map(it.title) == ['b', 'c']
		assert !c.delete_one(MutationData{
			table:   'posts'
			row_key: '1'
		})!
		assert c.update(MutationData{
			table:  'posts'
			values: {
				'views': orm.Primitive(5)
			}
		})! == 2
		assert c.delete(MutationData{
			table: 'posts'
			conds: [load.eq('title', 'b')]
		})! == 1
		// skipped, they show, and a delete is a delete
		all := posts(c.skip('soft_delete'))!
		assert all.map(it.title) == ['a', 'b', 'c']
		assert all.map(it.deleted_at != none) == [true, true, false]
		assert all.map(it.views) == [0, 5, 5]
		assert c.skip('soft_delete').delete(MutationData{
			table: 'posts'
			conds: [load.is_not_null('deleted_at')]
		})! == 2
		assert posts(c.skip('soft_delete'))!.map(it.title) == ['c']
	}
}

fn test_privacy() {
	for c in hook_clients()! {
		// the model's rule denies a title
		new_post(c, 'forbidden') or {
			assert err is PrivacyError
			assert err.msg() == 'privacy: create of `posts` denied'
		}
		assert posts(c)!.len == 0
		// a graph rule before it can allow
		c.policy(Policy{
			mutation: [
				fn (ctx graphql.Context, _ Mutation) !Decision {
					return if ctx is Admin { .allow } else { .skip }
				},
			]
		})
		admin := c.with_ctx(Admin{})
		new_post(admin, 'forbidden')!
		assert posts(c)!.map(it.title) == ['forbidden']
		// a table rule: when every rule skips, the write runs; `always_deny` ends that
		new_post(c, 'fine')!
		c.policy_on('posts', Policy{
			mutation: [always_deny]
			query:    [
				// a filter: narrows, then lets the next rule decide
				fn (_ graphql.Context, _ string, mut q load.Query) !Decision {
					q.conds << load.ne('title', 'forbidden')
					return .skip
				},
				fn (ctx graphql.Context, _ string, mut _ load.Query) !Decision {
					return if ctx is NoContext { .deny } else { .allow }
				},
			]
		})
		new_post(c, 'late') or { assert err is PrivacyError }
		posts(c) or { assert err.msg() == 'privacy: query of `posts` denied' }
		assert posts(c.with_ctx(Admin{}))!.map(it.title) == ['fine']
		// privileged: no rules; interceptors still apply
		new_post(c.privileged(), 'system')!
		assert posts(c.privileged())!.map(it.title) == ['forbidden', 'fine', 'system']
	}
}

struct Admin {}

@[heap]
struct TraceLog {
mut:
	events []TraceEvent
}

fn test_trace_reports_statements_without_values() {
	for driver in [false, true] {
		log := &TraceLog{}
		db := hook_db()!
		conn := if driver { orm.Connection(sqlite.new(db)) } else { orm.Connection(db) }
		traced := trace(conn, fn [log] (e TraceEvent) {
			mut l := unsafe { log }
			l.events << e
		})
		assert (traced is Driver) == driver
		assert traced is orm.TransactionalConnection
		c := Client.new(traced, hook_schema()!)!
		new_post(c, 'secret title')!
		new_post(c, '') or {}
		kinds := log.events.map('${it.kind} ${it.table}'.trim_space())
		if driver {
			assert kinds == ['begin', 'raw', 'commit', 'begin', 'rollback']
			assert log.events[1].statement.starts_with('INSERT INTO "posts" (')
			assert log.events[1].statement.ends_with('VALUES (?, ?, ?, ?) RETURNING "id"')
		} else {
			assert kinds == ['begin', 'insert posts', 'commit', 'begin', 'rollback']
		}
		for e in log.events {
			assert !e.statement.contains('secret')
			assert !e.failed
		}
		// a failed statement says so, without its message
		mut t := traced
		t.select(orm.SelectConfig{
			table: orm.Table{
				name: 'missing'
			}
		}, orm.QueryData{}, orm.QueryData{}) or {}
		assert log.events.last().kind == .select
		assert log.events.last().table == 'missing'
		assert log.events.last().failed
	}
}
