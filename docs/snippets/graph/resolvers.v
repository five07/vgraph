// Resolvers resolves the fields that this project's .graphql files add to the
// schema. `vgraph gen` wrote this file, and adds a method here for each new
// field; it never changes what is already here. Give `Resolvers` whatever
// its methods need, such as the graph. A method reads and writes through
// `graph.with_ctx(ctx)`: in a mutation, that is the request's transaction.
module graph

import context
import five07.vgraph.graphql

// snippet: resolvers
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

// end snippet
