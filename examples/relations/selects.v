module main

// Every read path runs a fixed set of selects (G1): each case runs on the
// seed, then on many more rows of every table, and runs the same selects in
// the same order. An edge whose keys come back empty skips the select of its
// rows, so each case reaches rows on every edge it loads, on the seed too.
import orm
import rand
import time
import five07.vgraph
import five07.vgraph.graphql
import five07.vgraph.load
import graph

// Setup is a client and its GraphQL server, traced to the fixture's log.
struct Setup {
	name   string
	g      graph.Graph
	s      &graphql.Server
	driver bool // on a vgraph driver, which runs the SQL the ORM can't
}

// Case is a read whose selects are checked.
struct Case {
	name   string
	driver bool // it needs a vgraph driver
	run    fn (st Setup, w graph.Graph) ! @[required]
}

// guarded returns a client on `conn` whose pets are filtered by an
// interceptor, and whose users by a privacy rule, each with an edge predicate:
// a subquery with a driver, a select of its own without one.
fn guarded(conn orm.Connection, f Fixture, name string, driver bool) !Setup {
	g := graph.Graph.new(vgraph.trace(conn, log_to(f.log)))!
	g.client.intercept_on('pets', vgraph.Interceptor{
		name: 'carded_owner'
		run:  fn (_ graphql.Context, _ string, mut q load.Query) ! {
			q.conds << graph.pet_has_owner_with(graph.user_has_card())
		}
	})
	g.client.policy_on('users', vgraph.Policy{
		query: [
			fn (_ graphql.Context, _ string, mut q load.Query) !vgraph.Decision {
				q.conds << graph.user_has_groups()
				return .skip
			},
		]
	})
	return Setup{
		name:   name
		g:      g
		s:      g.graphql(graph.Resolvers{})!
		driver: driver
	}
}

// selects_of runs `c` on `st`, and returns the tables of its selects.
fn selects_of(f Fixture, st Setup, c Case) ![]string {
	f.queries()
	c.run(st, f.w) or { return error('${st.name}, ${c.name}: ${err.msg()}') }
	return f.queries()
}

// check_fixed_selects runs each case on each setup, grows every table, and
// runs them again.
fn check_fixed_selects(f Fixture) ! {
	gadgets(f.w)!
	setups := [
		Setup{
			name: 'orm'
			g:    f.g
			s:    f.server
		},
		Setup{
			name:   'driver'
			g:      f.t
			s:      f.tserver
			driver: true
		},
		guarded(f.db, f, 'guarded orm', false)!,
		guarded(f.w.client.conn, f, 'guarded driver', true)!,
	]
	cases := read_cases()
	mut before := map[string][]string{}
	for st in setups {
		for c in cases {
			if c.driver && !st.driver {
				continue
			}
			tables := selects_of(f, st, c)!
			assert tables.len > 0, '${st.name}, ${c.name}'
			before['${st.name}, ${c.name}'] = tables
		}
	}
	grow(f.w)!
	for st in setups {
		for c in cases {
			if c.driver && !st.driver {
				continue
			}
			key := '${st.name}, ${c.name}'
			assert selects_of(f, st, c)! == before[key], key
		}
	}
}

// grow adds rows to every table, each linked by every edge: 20 users, each with
// a card, pets (one deleted), a device with logins, a gadget, groups, follows,
// friends and likes, and more list nodes and categories.
fn grow(w graph.Graph) ! {
	mut prev_user := 0
	mut prev_node := 0
	for i in 0 .. 20 {
		mut b := w.users().create().set_name('u${i}').add_groups_ids(1, 2).add_following_ids(1,
			2, 3).add_friends_ids(4)
		if prev_user > 0 && i % 2 == 1 {
			b = b.set_spouse_id(prev_user)
		}
		uid := b.save()!.user.id
		prev_user = uid
		w.cards().create().set_number('c${i}').set_owner_id(uid).exec()!
		for j in 0 .. 3 {
			mut p := w.pets().create().set_name('p${i}-${j}').set_owner_id(uid)
			if j == 2 {
				p = p.set_deleted_at(time.now())
			}
			p.exec()!
		}
		w.groups().create().set_name('g${i}').add_users_ids(uid, 1).exec()!
		device := w.devices().create().set_id(rand.uuid_v4()).set_name('d${i}').set_owner_id(uid).add_groups_ids(1,
			2).save()!.device.id
		for j in 0 .. 2 {
			w.logins().create().set_device_id(device).set_at(100 + i * 2 + j).exec()!
		}
		w.gadgets().create().set_owner_id(uid).set_serial_no('G-${i}').set_color(.red).set_level(1).set_weight(1).set_parts(1).set_big(1).set_ratio(1).set_tags('[]').add_likers_ids(1,
			uid).exec()!
		mut n := w.nodes().create().set_value(100 + i)
		if prev_node > 0 {
			n = n.set_next_id(prev_node)
		}
		prev_node = n.save()!.node.id
		w.categories().create().set_name('k${i}').set_parent_id(1 + i % 4).exec()!
	}
}

// read_cases returns a case for each read path: root lists, every edge kind
// (loaded, nested and named), traversals, edge predicates, counts, aggregates,
// orders by an edge, limits per parent, and their GraphQL forms, with
// `node`, `nodes` and connections.
fn read_cases() []Case {
	return [
		Case{
			name: 'root list'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.users().order_by_id().all()!
				st.g.users().order_by_name().first()!
				st.g.users().where_id(1).only()!
				st.g.users().order_by_id().ids()!
				st.g.users().where_name('ada').exist()!
			}
		},
		Case{
			name: 'o2o'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.users().with_card().with_spouse().all()!
				st.g.cards().with_owner().all()!
				st.g.nodes().with_next().with_prev().all()!
			}
		},
		Case{
			name: 'o2m'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.users().with_pets().with_devices().all()!
				st.g.pets().with_owner().all()!
				st.g.logins().with_device().all()!
			}
		},
		Case{
			name: 'o2m same type, nested'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.categories().with_children(fn (q graph.CategoryQuery) graph.CategoryQuery {
					return q.with_children(fn (q graph.CategoryQuery) graph.CategoryQuery {
						return q.with_children()
					})
				}).with_parent(fn (q graph.CategoryQuery) graph.CategoryQuery {
					return q.with_parent()
				}).all()!
			}
		},
		Case{
			name: 'm2m'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.users().with_groups().with_following().with_followers().with_friends().all()!
				st.g.groups().with_users().with_devices().all()!
				st.g.devices().with_owner().with_logins().with_groups().all()!
			}
		},
		Case{
			name: 'edge schema and view'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.gadgets().with_owner().with_likers().all()!
				st.g.likes().with_user().with_gadget().all()!
				st.g.users().with_gadgets().with_liked_gadgets().all()!
				st.g.pet_owners().with_owner().all()!
			}
		},
		Case{
			name: 'nested three levels'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.users().with_pets(fn (q graph.PetQuery) graph.PetQuery {
					return q.with_owner(fn (q graph.UserQuery) graph.UserQuery {
						return q.with_groups(fn (q graph.GroupQuery) graph.GroupQuery {
							return q.with_users()
						})
					})
				}).all()!
			}
		},
		Case{
			name: 'named edges'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.users().with_named_pets('r', fn (q graph.PetQuery) graph.PetQuery {
					return q.where(graph.pet_name_has_prefix('r'))
				}).with_named_pets('t', fn (q graph.PetQuery) graph.PetQuery {
					return q.where(graph.pet_name_has_prefix('t'))
				}).with_named_groups('devs', fn (q graph.GroupQuery) graph.GroupQuery {
					return q.where(graph.group_name_eq('devs'))
				}).all()!
			}
		},
		Case{
			name: 'limits per parent'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.users().with_pets(fn (q graph.PetQuery) graph.PetQuery {
					return q.order_by_name_desc().limit(1)
				}).with_groups(fn (q graph.GroupQuery) graph.GroupQuery {
					return q.order_by_name().limit(1).offset(1)
				}).all()!
			}
		},
		Case{
			name: 'traversals'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.users().query_pets().query_owner().query_groups().all()!
				st.g.groups().query_users().query_devices().query_logins().all()!
				st.g.categories().query_children().query_children().all()!
				ada := st.g.users().where_id(1).first()!
				ada.query_pets().all()!
				ada.query_groups()!.all()!
				ada.query_card().all()!
				ada.query_liked_gadgets()!.all()!
			}
		},
		Case{
			name: 'edge predicates'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.users().has_card().has_pets_with(fn (q graph.PetQuery) graph.PetQuery {
					return q.where(graph.pet_name_has_prefix('r'))
				}).all()!
				st.g.users().has_groups_with(fn (q graph.GroupQuery) graph.GroupQuery {
					return q.where(graph.group_name_eq('devs'))
				}).has_followers().all()!
				st.g.users().where(graph.user_has_devices_with(graph.device_has_logins())).all()!
				st.g.gadgets().has_likers().all()!
			}
		},
		Case{
			name: 'counts and aggregates'
			run:  fn (st Setup, _ graph.Graph) ! {
				st.g.users().count()!
				st.g.users().has_pets().count()!
				st.g.users().query_pets().count()!
				st.g.logins().sum_at()!
				st.g.logins().min_at()!
				st.g.logins().max_at()!
				st.g.logins().mean_at()!
			}
		},
		Case{
			name:   'group by, orders by an edge'
			driver: true
			run:    fn (st Setup, _ graph.Graph) ! {
				st.g.logins().group_by('device_id').aggregate(vgraph.count(), vgraph.sum('at')).all()!
				st.g.users().order_by_pets_count_desc().order_by_id().all()!
				st.g.cards().order_by_owner_name_desc().all()!
			}
		},
		Case{
			name: 'GraphQL: every edge'
			run:  fn (st Setup, _ graph.Graph) ! {
				run(st.s, '{ users { name card { number owner { name } } spouse { name } pets { name owner { name } } groups { name users { name } devices { name } } following { name } followers { name } friends { name } devices { name owner { name } logins { at device { name } } groups { name } } } }')!
				run(st.s, '{ categories { name parent { name parent { name } } children { name children { name children { name } } } } listNodes { value next { value } prev { value } } }')!
				run(st.s, '{ likes { user { name } gadget { serialNo } } petOwners { petName owner { name } } cards { owner { name } } logins { device { name } } }')!
			}
		},
		Case{
			name: 'GraphQL: counts, filters, limits per parent'
			run:  fn (st Setup, _ graph.Graph) ! {
				run(st.s, '{ usersCount(where: {hasPetsWith: [{nameHasPrefix: "r"}]}) petsCount users(where: {hasGroups: true, hasCardWith: [{numberHasPrefix: "4"}]}) { name } }')!
				run(st.s, '{ users(orderBy: {field: ID}, limit: 3) { name pets(orderBy: {field: NAME}, limit: 1, offset: 1) { name } groups(orderBy: {field: NAME, direction: DESC}, limit: 1) { name } } }')!
			}
		},
		Case{
			name: 'GraphQL: connections'
			run:  fn (st Setup, _ graph.Graph) ! {
				run(st.s, '{ gadgets(first: 3) { totalCount edges { cursor node { serialNo owner { name } likers { name } } } pageInfo { hasNextPage endCursor } } }')!
				run(st.s, '{ gadgets(last: 2, where: {hasLikers: true}) { totalCount edges { node { serialNo } } } }')!
				run(st.s, '{ users { gadgets(first: 2) { totalCount edges { node { serialNo likers { name } } } pageInfo { hasNextPage } } likedGadgets(first: 1) { totalCount edges { node { serialNo } } } } }')!
			}
		},
		Case{
			name:   'GraphQL: orders by an edge and a column'
			driver: true
			run:    fn (st Setup, _ graph.Graph) ! {
				run(st.s, '{ gadgets(first: 2, orderBy: {field: LIKERS_COUNT, direction: DESC}) { totalCount edges { node { serialNo } } } }')!
				run(st.s, '{ users(orderBy: {field: PETS_COUNT, direction: DESC}) { name } }')!
				run(st.s, '{ users { gadgets(first: 2, orderBy: {field: LEVEL, direction: DESC}) { totalCount edges { node { serialNo } } } } }')!
			}
		},
		Case{
			name: 'GraphQL: node and nodes'
			run:  fn (st Setup, w graph.Graph) ! {
				ids := w.gadgets().order_by_id().ids()!
				run(st.s, '{ node(id: "${ids[0]}") { id ... on Gadget { serialNo owner { name pets { name } } likers { name } } } }')!
				list := ids.map('"${it}"').join(', ')
				run(st.s, '{ nodes(ids: [${list}]) { id ... on Gadget { owner { name } likers { name } } } }')!
			}
		},
	]
}
