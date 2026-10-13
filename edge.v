module vgraph

// EdgeKind is the shape of an edge, which decides where its column lives.
pub enum EdgeKind {
	// one_to_one: each record has at most one target, which holds its key in
	// `column`, such as a user's card. The other direction, the card's owner, is
	// a many_to_one edge on the card.
	one_to_one
	// one_to_many: each record has many targets, which hold its key in
	// `column`, such as an article's comments.
	one_to_many
	// many_to_one: each record holds one target's key in its own `column`,
	// such as a comment's author.
	many_to_one
	// many_to_many: records and targets are linked through the join table
	// `through`, whose `column` holds the record's key and `through_to` the
	// target's, such as an article's tags.
	many_to_many
}

// Edge is a relationship from the struct that declares it, in its `edges()`
// method, to the table `to`.
//
// An edge is polymorphic when it has `type_col`: a `one_to_many` or
// `one_to_one` edge then only reaches the targets whose `type_col` is
// `type_val` (an article's comments, where comments have `owner_type` and
// `owner_id`), and a `many_to_one` edge only follows the records whose own
// `type_col` is `type_val` (a comment's article).
//
// A bidirectional edge, such as a spouse or a friend, sets `bidi`, and writes
// store both directions: both foreign keys, or both join rows.
pub struct Edge {
pub:
	name       string   @[required] // the name loads use, such as `comments`
	kind       EdgeKind @[required]
	to         string   @[required] // the target table, such as `comments`
	column     string   @[required] // the column that holds the key, as `kind` says
	type_col   string // polymorphic edges: the column that names the type
	type_val   string // polymorphic edges: the type this edge reaches
	through    string // many_to_many: the join table
	through_to string // many_to_many: the join table's column for the target key
	// soft_del names a target column that marks a target deleted when it is not
	// null, such as `deleted_at`. Deleted targets are not loaded. Leave it unset
	// to load them, as for the author of an old comment.
	soft_del string
	// ref names the inverse edge on `to`, as Ent's `Ref`: `validate` checks that
	// the two are the two sides of one relationship.
	ref string
	// unique: a many_to_one edge whose target at most one row holds, as Ent's
	// `Unique()`: the side of a one-to-one relationship that holds the key, such
	// as a spouse. Its column gets a unique index.
	unique bool
	// bidi: a self edge stored both ways, such as a spouse (many_to_one, which
	// must be unique) or friends (many_to_many): a write to one side writes the
	// other.
	bidi bool
	// required: a many_to_one edge a create must set.
	required bool
	// immutable: only a create sets the edge; updates can't change it.
	immutable bool
}

// Edges is implemented by structs that declare edges. vgraph finds the method
// through reflection, so declaring it is enough.
pub interface Edges {
	edges() []Edge
}
