module main

// The checks for each Ent relationship kind, run on SQLite by `main_test.v` and
// on PostgreSQL by `pg_test.v`, through the client `vgraph gen` wrote into
// `graph/`.
import orm
import graph
import models

// Log holds the table of each select a `Counting` connection ran.
@[heap]
struct Log {
mut:
	tables []string
}

// Counting runs every query on `inner`, and logs each select in `log`.
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

// Fixture is a seeded database, its client, and the log of its selects.
struct Fixture {
	g   graph.Graph
	db  orm.Connection
	log &Log
}

// queries returns the tables of the selects run since the last call.
fn (f Fixture) queries() []string {
	mut log := f.log
	tables := log.tables.clone()
	log.tables.clear()
	return tables
}

// seed creates the tables on `db`, which must have none of them, and fills them.
fn seed(db orm.Connection) !Fixture {
	sql db {
		create table models.User
		create table models.Card
		create table models.Pet
		create table models.Group
		create table models.GroupUser
		create table models.Follow
		create table models.Friendship
		create table models.Node
		create table models.Category
	}!
	for name in ['ada', 'bob', 'cy', 'dee'] {
		user := models.User{
			name: name
		}
		sql db {
			insert user into models.User
		}!
	}
	// ada and bob are married: each holds the other's id
	sql db {
		update models.User set spouse_id = 2 where id == 1
		update models.User set spouse_id = 1 where id == 2
	}!
	for card in [models.Card{
		number:   '4242'
		owner_id: 1
	}, models.Card{
		number:   '5555'
		owner_id: 2
	}] {
		sql db {
			insert card into models.Card
		}!
	}
	for pet in [models.Pet{
		name:     'rex'
		owner_id: 1
	}, models.Pet{
		name:     'tom'
		owner_id: 1
	}, models.Pet{
		name: 'stray'
	}] {
		sql db {
			insert pet into models.Pet
		}!
	}
	for name in ['admins', 'devs'] {
		group := models.Group{
			name: name
		}
		sql db {
			insert group into models.Group
		}!
	}
	// admins: ada; devs: ada and bob
	for pair in [[1, 1], [2, 1], [2, 2]] {
		link := models.GroupUser{
			group_id: pair[0]
			user_id:  pair[1]
		}
		sql db {
			insert link into models.GroupUser
		}!
	}
	// ada follows bob and cy; bob follows cy
	for pair in [[1, 2], [1, 3], [2, 3]] {
		follow := models.Follow{
			follower_id: pair[0]
			followee_id: pair[1]
		}
		sql db {
			insert follow into models.Follow
		}!
	}
	// ada and bob are friends, and cy and dee: each friendship in both directions
	for pair in [[1, 2], [2, 1], [3, 4], [4, 3]] {
		friendship := models.Friendship{
			user_id:   pair[0]
			friend_id: pair[1]
		}
		sql db {
			insert friendship into models.Friendship
		}!
	}
	// the list 1 -> 2 -> 3
	for value in [1, 2, 3] {
		node := models.Node{
			value:   value
			next_id: if value < 3 { ?int(value + 1) } else { none }
		}
		sql db {
			insert node into models.Node
		}!
	}
	// root > a > a1, and root > b
	for c in [['root', '0'], ['a', '1'], ['b', '1'], ['a1', '2']] {
		category := models.Category{
			name:      c[0]
			parent_id: if c[1] != '0' { ?int(c[1].int()) } else { none }
		}
		sql db {
			insert category into models.Category
		}!
	}
	log := &Log{}
	g := graph.Graph.new(Counting{
		inner: db
		log:   log
	})!
	g.client.ensure_indexes()!
	return Fixture{
		g:   g
		db:  db
		log: log
	}
}

fn names(users []graph.UserNode) []string {
	return users.map(it.user.name)
}

// O2O two types: a user has at most one card, which has one owner.
fn check_o2o_two_types(f Fixture) ! {
	f.queries()
	users := f.g.users().with_card().order_by_id().all()!
	cards := f.g.cards().with_owner().order_by_id().all()!
	assert f.queries() == ['users', 'cards', 'cards', 'users']
	assert users.map(if c := it.card { c.card.number } else { '-' }) == ['4242', '5555', '-', '-']
	assert cards.map(if o := it.owner { o.user.name } else { '-' }) == ['ada', 'bob']
	assert users[0].query_card().first()!.card.number == '4242'
	assert users[2].query_card().all()!.len == 0
	assert cards[1].query_owner().first()!.user.name == 'bob'
}

// O2O same type: each node of a linked list has a next and a previous node.
fn check_o2o_same_type(f Fixture) ! {
	f.queries()
	nodes := f.g.nodes().with_next().with_prev().order_by_id().all()!
	assert f.queries() == ['nodes', 'nodes', 'nodes']
	assert nodes.map(if n := it.next { n.node.value } else { 0 }) == [2, 3, 0]
	assert nodes.map(if p := it.prev { p.node.value } else { 0 }) == [0, 1, 2]
	// walk the list both ways by traversal
	mut forward := []int{}
	mut node := f.g.nodes().where_next_id(2).first()!
	for {
		forward << node.node.value
		node = node.query_next().first() or { break }
	}
	assert forward == [1, 2, 3]
	mut back := []int{}
	for {
		back << node.node.value
		node = node.query_prev().first() or { break }
	}
	assert back == [3, 2, 1]
}

// O2O bidirectional: a spouse is a user whose spouse is this user.
fn check_o2o_bidirectional(f Fixture) ! {
	users := f.g.users().with_spouse().order_by_id().all()!
	assert users.map(if s := it.spouse { s.user.name } else { '-' }) == ['bob', 'ada', '-', '-']
	bob := users[0].query_spouse().first()!
	assert bob.query_spouse().first()!.user.name == 'ada'
	assert users[2].query_spouse().all()!.len == 0
}

// O2M two types: a user has many pets; a pet has at most one owner.
fn check_o2m_two_types(f Fixture) ! {
	users := f.g.users().with_pets(fn (q graph.PetQuery) graph.PetQuery {
		return q.order_by_name_desc()
	}).order_by_id().all()!
	assert users[0].pets.map(it.pet.name) == ['tom', 'rex']
	assert users[1].pets.len == 0
	assert users[0].query_pets().order_by_name().all()!.map(it.pet.name) == ['rex', 'tom']
	pets := f.g.pets().with_owner().order_by_id().all()!
	assert pets.map(if o := it.owner { o.user.name } else { '-' }) == ['ada', 'ada', '-']
	assert pets[0].query_owner().first()!.user.name == 'ada'
	assert pets[2].query_owner().all()!.len == 0, 'a pet with no owner'
	assert f.g.pets().where_owner_id_is_null().first()!.pet.name == 'stray'
}

// O2M same type: a category tree, loaded three levels deep in three queries.
fn check_o2m_same_type(f Fixture) ! {
	f.queries()
	roots := f.g.categories().where_parent_id_is_null().with_children(fn (q graph.CategoryQuery) graph.CategoryQuery {
		return q.order_by_name().with_children()
	}).all()!
	assert f.queries() == ['categories', 'categories', 'categories']
	assert roots.map(it.category.name) == ['root']
	children := roots[0].children
	assert children.map(it.category.name) == ['a', 'b']
	assert children[0].children.map(it.category.name) == ['a1']
	assert children[1].children.len == 0
	assert roots[0].query_children().order_by_name_desc().all()!.map(it.category.name) == [
		'b',
		'a',
	]
	a1 := f.g.categories().where_name('a1').with_parent(fn (q graph.CategoryQuery) graph.CategoryQuery {
		return q.with_parent()
	}).first()!
	parent := a1.parent or { return error('a1 has a parent') }
	assert parent.category.name == 'a'
	grandparent := parent.parent or { return error('a has a parent') }
	assert grandparent.category.name == 'root'
	assert a1.query_parent().first()!.category.name == 'a'
	assert roots[0].query_parent().all()!.len == 0, 'the root has no parent'
}

// M2M two types: a group has many users, who can be in many groups.
fn check_m2m_two_types(f Fixture) ! {
	f.queries()
	groups := f.g.groups().with_users().order_by_id().all()!
	assert f.queries() == ['groups', 'group_users', 'users'], 'the join table, then the users'
	assert groups.map(names(it.users)) == [['ada'], ['ada', 'bob']]
	users := f.g.users().with_groups().order_by_id().all()!
	assert users.map(it.groups.map(it.group.name)) == [['admins', 'devs'], ['devs'], [], []]
	assert names(groups[1].query_users()!.order_by_name_desc().all()!) == ['bob', 'ada']
	assert users[0].query_groups()!.order_by_id().all()!.map(it.group.name) == [
		'admins',
		'devs',
	]
	assert users[3].query_groups()!.all()!.len == 0
}

// M2M same type: following and followers, two edges over one join table.
fn check_m2m_same_type(f Fixture) ! {
	users := f.g.users().with_following().with_followers().order_by_id().all()!
	assert users.map(names(it.following)) == [['bob', 'cy'], ['cy'], [], []]
	assert users.map(names(it.followers)) == [[], ['ada'], ['ada', 'bob'], []]
	assert names(users[0].query_following()!.order_by_id().all()!) == ['bob', 'cy']
	assert names(users[2].query_followers()!.order_by_id().all()!) == ['ada', 'bob']
}

// M2M bidirectional: friends, stored in both directions, so either side sees
// the other.
fn check_m2m_bidirectional(f Fixture) ! {
	users := f.g.users().with_friends().order_by_id().all()!
	assert users.map(names(it.friends)) == [['bob'], ['ada'], ['dee'], ['cy']]
	assert names(users[3].query_friends()!.all()!) == ['cy']
}

// The one_to_one edges get unique indexes, so the database keeps them one to
// one: it rejects a second card for ada.
fn check_one_to_one_indexes_are_unique(f Fixture) ! {
	unique := f.g.client.schema.indexes().filter(it.unique).map(it.name)
	assert unique == ['cards_owner_id_idx', 'nodes_next_id_idx']
	second_card := models.Card{
		number:   '9999'
		owner_id: 1
	}
	sql f.db {
		insert second_card into models.Card
	} or {
		// SQLite says `UNIQUE constraint failed`, PostgreSQL `violates unique constraint`
		assert err.msg().to_lower().contains('unique')
		return
	}
	return error('a second card for ada should be rejected')
}
