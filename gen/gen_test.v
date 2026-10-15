module gen

import os

fn test_edges_receiver() {
	assert edges_receiver('pub fn (u User) edges() []vgraph.Edge {')? == 'User'
	assert edges_receiver('fn (a &Article) edges() []vgraph.Edge {')? == 'Article'
	assert edges_receiver('	pub fn (mut t Tag) edges()  []vgraph.Edge {')? == 'Tag'
	assert edges_receiver('pub fn (u User) view() UserView {') == none
	assert edges_receiver('// pub fn (u User) edges() []vgraph.Edge') == none
	assert edges_receiver('pub fn edges() []vgraph.Edge {') == none
}

fn test_snake() {
	assert snake('User') == 'user'
	assert snake('ArticleTag') == 'article_tag'
}

fn test_discover_finds_the_service_entities() {
	root := os.join_path(@VMODROOT, 'examples', 'service')
	found := discover(root, ['graph'])!
	assert found.map('${it.module_path}.${it.struct_name}') == [
		'models.Article',
		'models.Comment',
		'models.Post',
		'models.User',
	]
	assert found[0].alias() == 'models'
	// a nested module gets an alias without dots
	assert Entity{
		module_path: 'shop.models'
		struct_name: 'User'
	}.alias() == 'shop_models'
}

fn test_loader_source() {
	src := loader_source([
		Entity{'a.models', 'A'},
		Entity{'a.models', 'B'},
	])
	assert src.contains('import a.models as a_models\n')
	assert src.count('import a.models') == 1
	assert src.contains('schema.add[a_models.A]() or { problems(err) }')
	assert src.contains('schema.add[a_models.B]() or { problems(err) }')
	assert src.contains('schema.validate() or { problems(err) }')
}

fn test_generate_rejects_an_edge_to_an_unknown_table() {
	tables := [
		Table{
			name:    'as'
			struct_: 'models.A'
			key:     'id'
			columns: [Column{
				name:  'id'
				field: 'id'
				typ:   'int'
				kind:  'int'
			}]
			edges:   [Edge{
				name:   'bs'
				kind:   'one_to_many'
				to:     'bs'
				column: 'a_id'
			}]
		},
	]
	generate('graph', [Entity{'x.models', 'A'}], tables) or {
		assert err.msg() == '`as.bs` leads to `bs`, which has no struct'
		return
	}
	assert false
}

fn test_import_line() {
	assert import_line('users.models') == 'users.models as users_models'
	assert import_line('models') == 'models'
}

fn test_generate_rejects_names_it_needs() {
	id := Column{
		name:  'id'
		field: 'id'
		typ:   'int'
		kind:  'int'
	}
	client := [Table{
		name:    'client'
		struct_: 'models.A'
		key:     'id'
		columns: [id]
	}]
	if _ := generate('graph', [Entity{'x.models', 'A'}], client) {
		assert false
	} else {
		assert err.msg() == 'table `client`: `Graph.client` is taken; rename the table'
	}
	self_named := [
		Table{
			name:    'as'
			struct_: 'models.A'
			key:     'id'
			columns: [id]
			edges:   [Edge{
				name:   'a'
				kind:   'many_to_one'
				to:     'as'
				column: 'id'
			}]
		},
	]
	if _ := generate('graph', [Entity{'x.models', 'A'}], self_named) {
		assert false
	} else {
		assert err.msg() == '`as.a`: `ANode.a` is taken; rename the edge'
	}
}

fn test_camel_follows_entgql() {
	assert camel('created_at') == 'createdAt'
	assert camel('user_id') == 'userID'
	assert camel('id') == 'id'
	assert camel('owner_type') == 'ownerType'
	assert camel('api_url') == 'apiURL'
	assert camel('group_users') == 'groupUsers'
}

fn test_parse_signature() {
	sig := parse_signature('fn (q ArticleQuery) load_author(rows []models.Article, fns []fn (UserQuery) UserQuery) !map[string][]UserNode {') or {
		panic('not read')
	}
	assert sig.vis == ''
	assert sig.recv == 'q' && sig.typ == 'ArticleQuery' && sig.method == 'load_author'
	assert sig.params == 'rows []models.Article, fns []fn (UserQuery) UserQuery'
	assert sig.ret == '!map[string][]UserNode'
	scan := parse_signature('pub fn (q ArticleQuery) scan[T]() ![]T {') or { panic('not read') }
	assert scan.vis == 'pub ' && scan.generic == '[T]' && scan.params == '' && scan.ret == '![]T'
	// a method with no result, and other lines, aren't operations
	assert parse_signature('pub fn (q ArticleQuery) use(hooks ...ArticleHook) {') == none
	assert parse_signature('pub fn (q ArticleQuery) limit(count int) ArticleQuery {') == none
	assert parse_signature('	return q') == none
}

// A model of level `none` keeps its code as it was; any other level wraps its
// operations in spans, by its level.
fn test_instrument_by_level() {
	text := '// all returns the rows.\npub fn (q ArticleQuery) all() ![]ArticleNode {\n\treturn q.nodes([])\n}\n'
	mut info := Info{
		table:  Table{
			name: 'articles'
			otel: Otel{
				level: 'none'
			}
		}
		entity: Entity{
			struct_name: 'Article'
		}
	}
	assert instrument(text, info) == text
	info = Info{
		...info
		table: Table{
			...info.table
			otel: Otel{
				level: 'default'
			}
		}
	}
	out := instrument(text, info)
	assert out.contains("// all returns the rows.\npub fn (q ArticleQuery) all() ![]ArticleNode {\n\tclient, span := q.graph.client.start_span(.default, 'query articles', 'articles', 'all')")
	assert out.contains('\n// all_untraced is `all`, without its span.\nfn (q ArticleQuery) all_untraced() ![]ArticleNode {\n\treturn q.nodes([])\n}\n')
	assert out.contains('vgraph.span_rows(span, result.len)')
}

// A full or default model's resolvers each get a span; an ops model's don't,
// nor do columns.
fn test_trace_resolvers() {
	text := "\ts.resolve('Query', 'articles', fn [g] (ctx context.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {\n\t\treturn fn () {\n\t\t}()\n\t})\n\tfor name in ['title'] {\n\t\ts.resolve('Article', name, resolve_article_field)\n\t}\n"
	assert trace_resolvers(text, 'ops') == text
	out := trace_resolvers(text, 'default')
	assert out.starts_with("\ts.resolve('Query', 'articles', g.client.traced_resolver(.default, 'Query', 'articles', fn [g] (")
	assert out.contains('\t\t}()\n\t}))\n')
	assert out.contains("s.resolve('Article', name, resolve_article_field)")
}
