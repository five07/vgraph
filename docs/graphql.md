# GraphQL

`vgraph gen` writes a GraphQL schema for the tables, `graph/schema.graphql`, and
a server for it, `g.graphql()`. The schema follows
[entgql](https://entgo.io/docs/graphql)'s conventions: a type per table, with
camelCase fields (`createdAt`, `userID`), keys and foreign keys as `ID`, edges as
fields; and per table a root list, a count, a `WhereInput`, an order and three
mutations.

```graphql
type Query {
  articles(after: Cursor, first: Int, before: Cursor, last: Int, orderBy: [ArticleOrder!], where: ArticleWhereInput): ArticleConnection!
  tags(where: TagWhereInput, orderBy: [TagOrder!], limit: Int, offset: Int): [Tag!]!
  tagsCount(where: TagWhereInput): Int!
}

type Mutation {
  createArticle(input: CreateArticleInput!): Article!
  updateArticle(id: ID!, input: UpdateArticleInput!): Article!
  deleteArticle(id: ID!): ID!
}
```

## The server

<!-- snippet: docs/snippets/graphql_test.v#server -->
```v
server := g.graphql(graph.Resolvers{ g: g }, default_page: 20, max_page: 100)!
res := server.execute(graphql.Request{
	query: '{ articles(first: 2, orderBy: {field: VIEWS, direction: DESC}) { edges { node { title author { name } } } } }'
}, as_viewer(Viewer{ id: 1 })) // the request's context: hooks and privacy rules get it
println(res.json())
```

The second argument of `execute` and `handle` is the request's `context.Context`,
which hooks, interceptors and privacy rules get ([Hooks, interceptors and
privacy](hooks-and-privacy.md)). Resolvers read through the generated client:
one query per edge per level of a request, however many rows.

`handle` answers a request over HTTP, as the GraphQL over HTTP spec describes
(POST with JSON, or GET for queries), from any web framework:

<!-- snippet: docs/snippets/graphql_test.v#http -->
```v
// from any web framework: the method, headers and body in, a response out
answer := server.handle(graphql.HttpRequest{
	method:       'POST'
	content_type: 'application/json'
	body:         '{"query": "{ search(text: \\"SQL\\") { title } }"}'
}, as_viewer(Viewer{}))
println('${answer.status} ${answer.content_type}: ${answer.body}')
```

[`examples/service`](../examples/service) and the others serve it on veb.

## Lists, connections and page sizes

A table's lists take `where`, `orderBy`, and `limit` and `offset`, at the root
and on edges, where they apply per parent. A table with `relay: true` has Relay
connections instead: `first` and `after`, `last` and `before`, returning
`edges { node cursor }`, `pageInfo` and `totalCount` (counted only when asked
for). Cursors hold the row's order values and key, so a page follows from where
the last one ended. [`examples/pagination`](../examples/pagination) compares
the two.

A negative size is an error. `default_page` and `max_page`, for every table in
`g.graphql(r, ...)` or per table in `graphql()`, give a page without a size the
default, or else the maximum, and refuse a request past the maximum.

## Filters and orders

`where` takes entgql's `WhereInput`: `not`, `and`, `or`; per field `title`,
`titleNEQ`, `titleIn`, `titleNotIn`, `titleGT`, `titleGTE`, `titleLT`,
`titleLTE`, `titleContains`, `titleHasPrefix`, `titleHasSuffix`,
`titleEqualFold`, `titleContainsFold`, `titleIsNil` and `titleNotNil`, as the
field's type allows; per edge `hasAuthor` and `hasAuthorWith`. `orderBy` takes
one order or a list, by a field, or by a list edge's count (`TAGS_COUNT`).
Several orders, or an order by an edge, need a driver.

## Mutations

`create<Type>`, `update<Type>` and `delete<Type>`, with entgql's inputs:
`CreateArticleInput` has each writable field, required when the create needs
it, and `tagIDs`; `UpdateArticleInput` has each mutable field, `clear<Field>` for
nullable ones, and `addTagIDs`, `removeTagIDs`, `clearTags`. They run the
generated builders, so defaults, checks, hooks and privacy apply. A request's
mutations run in one transaction, when the client can begin one: an error in any
rolls back all.

<!-- snippet: docs/snippets/graphql_test.v#mutation -->
```v
created := server.execute(graphql.Request{
	query:     'mutation($input: CreateArticleInput!) { createArticle(input: $input) { title status } }'
	variables: {
		'input': graphql.Value({
			'title':  graphql.Value('From GraphQL')
			'userID': graphql.Value(b.ada.user.id.str())
		})
	}
}, as_viewer(Viewer{ id: b.ada.user.id }))
```

## Node

A table with `node: true` implements `Node`, and `node(id:)` and `nodes(ids:)`
find its rows by global id ([Schema](schema.md#views-indexes-global-ids)):

<!-- snippet: docs/snippets/graphql_test.v#node -->
```v
node := server.execute(graphql.Request{
	query: '{ node(id: "${b.hello.article.id}") { __typename ... on Article { title } } }'
}, as_viewer(Viewer{}))
```

## Options

`graphql()` on a model returns its options; fields and edges have theirs in
`fields()` and `edges()`:

- `type_name`, `query_field` (`-` for no root field), `node`, `relay`,
  `mutations` (`[.create, .update]`; `[]` for none), `directives`,
  `default_page`, `max_page`;
- on a field: `comment` (its description), `deprecated`, `sensitive` (out of the
  output, in the inputs), `graphql_skip`, `graphql_skip_in` (`.object`, `.where`,
  `.order`, `.create_input`, `.update_input`), `order_field`, `directives`;
- on an edge: `graphql_skip`, `order_field` (order by a field of the target, as
  `AUTHOR_NAME`), `directives`;
- `@[graphql: '-']` on a field or a struct leaves it out.

## Your own fields

Fields and mutations of your own go in `.graphql` files anywhere in the project:

<!-- snippet: docs/snippets/schema/blog.graphql -->
```graphql
extend type Query {
  """The articles whose title contains `text`."""
  search(text: String!): [Article!]!
}
```

`vgraph gen` merges them into the schema, and adds a stub for each new field to
`graph/resolvers.v`, a file it creates once and never changes after, but to add
stubs. The methods of `Resolvers` are yours, and `Resolvers` holds what they
need:

<!-- snippet: docs/snippets/graph/resolvers.v#resolvers -->
```v
// Resolvers has what its methods need: here, the graph.
pub struct Resolvers {
pub:
	g Graph
}

// query_search resolves `Query.search`: `search(text: String!): [Article!]!`.
pub fn (r Resolvers) query_search(ctx context.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	found := r.g.with_ctx(ctx).articles().where_title_contains(info.arg('text').as_string()).order_by_id().all()!
	result := graphql.list(found.map(graphql.obj(it)))
	return parents.map(result)
}
```

A resolver that writes goes through `r.g.with_ctx(ctx)`, which in a mutation is
the request's transaction. Operations and fragments in `operations/` folders are
checked against the schema by `vgraph gen`, so a schema change that breaks a
client's query fails at its file and line.

## Introspection

The server answers [introspection](https://graphql.org/learn/introspection/)
(`__schema`, `__type`, `__typename`) as graphql-js does, so GraphiQL, Apollo
Sandbox and code generators read the schema from it. A non-null or list type is
a wrapper with no name: `title: String!` is `NON_NULL` with `ofType`
`{name: "String", kind: SCALAR}`, so ask for `ofType` a level per wrapper.
Descriptions come from `comment`, and `@deprecated` from `deprecated`. For a
public API in production, turn it off:

<!-- snippet: docs/snippets/graphql_test.v#no-introspection -->
```v
mut server := g.graphql(graph.Resolvers{ g: g })!
server.validation = graphql.ValidateOptions{
	no_introspection: true // `__schema` and `__type` fail; `__typename` still works
}
```

## The `graphql` module

The GraphQL implementation is `five07.vgraph.graphql`, which doesn't depend on
the rest of vgraph: a lexer and parser for the whole language, schemas from SDL,
every validation rule of the spec, an executor that gives each resolver all the
parents of a level at once, introspection, Relay connections and the HTTP
handler. It is tested against cases recorded from graphql-js, and matches its
messages, locations, printed schemas and introspection.
