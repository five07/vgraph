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
		'articles.models.Article',
		'comments.models.Comment',
		'posts.models.Post',
		'users.models.User',
	]
	assert found[0].alias() == 'articles_models'
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
