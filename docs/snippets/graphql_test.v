module main

import five07.vgraph.graphql
import graph

fn test_graphql() {
	b := blog()!
	g := b.g
	// snippet: server
	server := g.graphql(graph.Resolvers{ g: g }, default_page: 20, max_page: 100)!
	res := server.execute(graphql.Request{
		query: '{ articles(first: 2, orderBy: {field: VIEWS, direction: DESC}) { edges { node { title author { name } } } } }'
	}, Viewer{ id: 1 }) // the request's context, which hooks and privacy rules get
	println(res.json())
	// end snippet
	assert res.json() == '{"data":{"articles":{"edges":[{"node":{"title":"Hello, V","author":{"name":"Ada"}}},{"node":{"title":"Notes on SQL","author":{"name":"Bob"}}}]}}}'
	// snippet: http
	// from any web framework: the method, headers and body in, a response out
	answer := server.handle(graphql.HttpRequest{
		method:       'POST'
		content_type: 'application/json'
		body:         '{"query": "{ search(text: \\"SQL\\") { title } }"}'
	}, Viewer{})
	println('${answer.status} ${answer.content_type}: ${answer.body}')
	// end snippet
	assert answer.status == 200
	assert answer.body == '{"data":{"search":[{"title":"Notes on SQL"}]}}'
	// snippet: mutation
	created := server.execute(graphql.Request{
		query:     'mutation($input: CreateArticleInput!) { createArticle(input: $input) { title status } }'
		variables: {
			'input': graphql.Value({
				'title':  graphql.Value('From GraphQL')
				'userID': graphql.Value(b.ada.user.id.str())
			})
		}
	}, Viewer{ id: b.ada.user.id })
	// end snippet
	assert created.json() == '{"data":{"createArticle":{"title":"From GraphQL","status":"DRAFT"}}}'
	// snippet: node
	node := server.execute(graphql.Request{
		query: '{ node(id: "${b.hello.article.id}") { __typename ... on Article { title } } }'
	}, Viewer{})
	// end snippet
	assert node.json() == '{"data":{"node":{"__typename":"Article","title":"Hello, V"}}}'
}

fn test_introspection_off() {
	b := blog()!
	g := b.g
	// snippet: no-introspection
	mut server := g.graphql(graph.Resolvers{ g: g })!
	server.validation = graphql.ValidateOptions{
		no_introspection: true // `__schema` and `__type` fail; `__typename` still works
	}
	// end snippet
	res := server.execute(graphql.Request{ query: '{ __schema { queryType { name } } }' },
		Viewer{})
	assert res.errors.len > 0
}
