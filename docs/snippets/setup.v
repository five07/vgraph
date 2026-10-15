// The snippets' setup: the migration, a graph on a new SQLite database, and
// a small blog to read. The guides copy the regions between `snippet:`
// comments; `docs_test.v` checks they stay the same.
module main

import context
import db.sqlite
import v.migrations
import five07.vgraph
import five07.vgraph.sqlite as vsqlite
import graph

// snippet: migration
// initial creates the tables from the schema `vgraph gen` wrote, then the
// join table, the indexes the edges need, and each table's range of global ids.
const initial = migrations.Migration{
	version: 1
	name:    'initial'
	up:      fn (mut ctx migrations.Context) ! {
		s := graph.schema()!
		for table in ['users', 'articles', 'comments', 'tags'] {
			vgraph.create_table(mut ctx, s, table)!
		}
		ctx.create_table(s.join_table('articles', 'tags')!)!
		vgraph.add_edge_indexes(mut ctx, s)!
		vgraph.global_ids(mut ctx, s)!
	}
	down:    fn (mut ctx migrations.Context) ! {
		for table in ['article_tags', 'comments', 'tags', 'articles', 'users', 'vgraph_types'] {
			ctx.drop_table(table)!
		}
	}
}

// end snippet

// snippet: open
// open returns a graph on a new in-memory SQLite database, migrated. vgraph's
// driver wraps the connection, for what the ORM can't run: keys read back
// from inserts, upserts, several orders, per-parent limits.
fn open() !graph.Graph {
	mut db := sqlite.connect(':memory:')!
	mut m := migrations.new(mut db, [initial], dialect: .sqlite)!
	m.migrate()!
	return graph.Graph.new(vsqlite.new(db))!
}

// end snippet

// Blog is a seeded graph, and the nodes the snippets refer to. The nodes are
// references: a struct field of a node type makes V's cgen expand the node
// types' zero values through their edges, which took ~45 GB and 40 s.
struct Blog {
	g     graph.Graph
	ada   &graph.UserNode
	bob   &graph.UserNode
	hello &graph.ArticleNode // by Ada, published, tagged v, with two comments
	loads &graph.ArticleNode // by Ada, a draft, tagged v and sql
	notes &graph.ArticleNode // by Bob, published, no comments
}

// blog returns a graph with two users, three articles, comments and tags.
fn blog() !Blog {
	g := open()!
	ada := g.users().create().set_name('Ada').set_email('ada@example.com').save()!
	bob := g.users().create().set_name('Bob').set_email('bob@example.com').save()!
	v := g.tags().create().set_name('v').save()!
	sql_tag := g.tags().create().set_name('sql').save()!
	hello := g.articles().create().set_author(ada).set_title('Hello, V').set_status(.published).set_views(120).add_tags(v).save()!
	loads := g.articles().create().set_author(ada).set_title('Batched loads').add_tags(v,
		sql_tag).save()!
	notes := g.articles().create().set_author(bob).set_title('Notes on SQL').set_status(.published).set_views(40).save()!
	g.comments().create().set_article(hello).set_author(bob).set_body('Nice!').exec()!
	g.comments().create().set_article(hello).set_author(ada).set_body('Thanks.').exec()!
	return Blog{
		g:     g
		ada:   &ada
		bob:   &bob
		hello: &hello
		loads: &loads
		notes: &notes
	}
}

// snippet: viewer
// Viewer is the app's own value: who is asking. It rides in a context, which
// `g.with_ctx(ctx)` passes to hooks, interceptors and privacy rules; the
// GraphQL server passes each request's.
struct Viewer {
	id    i64
	admin bool
}

// viewer_key_cell exists for its address, the context key of the viewer.
const viewer_key_cell = u8(1)

fn as_viewer(v Viewer) context.Context {
	return context.with_value(context.background(), voidptr(&viewer_key_cell), v)
}

fn viewer_of(ctx context.Context) Viewer {
	if value := ctx.value(voidptr(&viewer_key_cell)) {
		if value is Viewer {
			return value
		}
	}
	return Viewer{}
}

// end snippet
