// Resolvers resolves the fields that this project's .graphql files add to the
// schema. `vgraph gen` wrote this file, and adds a method here for each new
// field; it never changes what is already here. Give `Resolvers` whatever
// its methods need, such as the graph. A method reads and writes through
// `graph.with_ctx(ctx)`: in a mutation, that is the request's transaction.
module graph

pub struct Resolvers {}
