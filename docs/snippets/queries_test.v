module main

import five07.vgraph
import five07.vgraph.load
import graph
import models

fn test_queries() {
	b := blog()!
	g := b.g
	// snippet: query
	published := g.articles()
		.where_status(.published)
		.where_title_contains('V')
		.order_by_views_desc()
		.limit(10)
		.all()! // []graph.ArticleNode
	// end snippet
	assert published.map(it.article.title) == ['Hello, V']
	// snippet: results
	first := g.articles().order_by_id().first()! // NotFoundError when there is none
	hello := g.articles().where_title('Hello, V').only()! // and NotSingularError when there are more
	ids := g.articles().order_by_id().ids()! // []i64
	n := g.articles().where_status(.draft).count()!
	any := g.articles().where_views_gt(100).exist()!
	// end snippet
	assert first.article.title == 'Hello, V' && hello.article.id == first.article.id
	assert ids.len == 3 && n == 1 && any
}

fn test_eager_loading() {
	b := blog()!
	g := b.g
	// snippet: with
	articles := g.articles()
		.with_author()
		.with_tags()
		.with_comments(fn (q graph.CommentQuery) graph.CommentQuery {
			return q.with_author().order_by_id() // nested: still one query per edge
		})
		.order_by_id()
		.all()!
	for a in articles {
		names := a.tags.map(it.tag.name).join(', ')
		println('${a.article.title} [${names}]: ${a.comments.len} comments')
		for c in a.comments {
			author := c.author or { continue }
			println('  ${author.user.name}: ${c.comment.body}')
		}
	}
	// end snippet
	assert articles[0].comments.map(it.author or { panic('') }.user.name) == ['Bob', 'Ada']
	assert articles[1].tags.map(it.tag.name) == ['v', 'sql']
	// snippet: with-limit
	// each user's newest article: the limit applies per user
	users := g.users().with_articles(fn (q graph.ArticleQuery) graph.ArticleQuery {
		return q.order_by_id_desc().limit(1)
	}).order_by_id().all()!
	// end snippet
	assert users.map(it.articles.map(it.article.title)) == [['Batched loads'], ['Notes on SQL']]
	// snippet: named
	u := g.users().where_name('Ada').with_named_articles('drafts', fn (q graph.ArticleQuery) graph.ArticleQuery {
		return q.where_status(.draft)
	}).only()!
	drafts := u.named_articles['drafts']
	u.articles_or_err() or { println(err) } // NotLoadedError: no with_articles()
	// end snippet
	assert drafts.map(it.article.title) == ['Batched loads']
	// snippet: nodes
	// rows read elsewhere: load their edges only
	rows := [b.hello.article, b.notes.article]
	with_authors := g.articles().with_author().nodes(rows)!
	// end snippet
	assert with_authors.map(it.author or { panic('') }.user.name) == ['Ada', 'Bob']
}

fn test_predicates_and_traversals() {
	b := blog()!
	g := b.g
	// snippet: predicates
	// OR, NOT and the rest, with a function per field and operator
	popular_or_v := g.articles().where(load.or(graph.article_views_gt(100), graph.article_title_has_prefix('Notes'))).all()!
	untagged := g.articles().where(load.not(graph.article_has_tags())).all()!
	// edge predicates
	commented := g.articles().has_comments().all()!
	by_ada := g.articles().has_author_with(fn (q graph.UserQuery) graph.UserQuery {
		return q.where_name('Ada')
	}).all()!
	// SQL of your own, with parameters
	short := g.articles().where(load.raw('length(title) < ?', 12)).all()!
	// end snippet
	assert popular_or_v.len == 2 && untagged.len == 1 && commented.len == 1 && by_ada.len == 2
	assert short.map(it.article.title) == ['Hello, V']
	// snippet: traversals
	// from a query: the tags of Ada's articles
	tags := g.users().where_name('Ada').query_articles().query_tags().order_by_name().all()!
	// from a node
	comments := b.hello.query_comments().order_by_id().all()!
	// end snippet
	assert tags.map(it.tag.name) == ['sql', 'v'] // each tag once
	assert comments.len == 2
}

// TitleOnly receives the columns `scan` selects.
struct TitleOnly {
	title string
}

fn test_aggregates() {
	b := blog()!
	g := b.g
	// snippet: aggregates
	total := g.articles().sum_views()!
	most := g.articles().max_views()!
	titles := g.articles().order_by_title().select('title').all()! // other columns left at zero
	scanned := g.articles().order_by_title().scan[TitleOnly]()!
	by_author := g.articles().group_by('user_id').aggregate(vgraph.count(), vgraph.sum('views')).all()!
	// end snippet
	assert total == 160 && most == 120
	assert titles.map(it.article.title) == ['Batched loads', 'Hello, V', 'Notes on SQL']
	assert titles[0].article.views == 0
	assert scanned.map(it.title) == ['Batched loads', 'Hello, V', 'Notes on SQL']
	assert by_author.len == 2
	// snippet: orders
	// several orders, by an edge's count, and nulls last
	busiest := g.articles().order_by_comments_count_desc().order_by_id().all()!
	by_author_name := g.articles().order_by_author_name().order_by_title().all()!
	newest_deleted := g.articles().order_by(vgraph.desc('deleted_at').nulls_last()).all()!
	// end snippet
	assert busiest[0].article.title == 'Hello, V'
	assert by_author_name.map(it.article.title) == ['Batched loads', 'Hello, V', 'Notes on SQL']
	assert newest_deleted.len == 3
}

fn test_load_without_the_client() {
	b := blog()!
	conn := b.g.client.conn
	// snippet: client-load
	mut schema := vgraph.Schema{}
	schema.add[models.User]()!
	schema.add[models.Article]()!
	schema.add[models.Comment]()!
	schema.add[models.Tag]()!
	client := vgraph.Client.new(conn, schema)! // checks every edge against the structs

	articles := load.select_where[models.Article](conn, load.Query{ order: 'id' })!
	authors := client.load_one[models.Article, models.User](articles, 'author')! // map[string]models.User
	by_user := client.load_many[models.User, models.Article](authors.values(), 'articles')!
	first_author := authors[articles[0].user_id.str()] // keyed by the key's string form
	// end snippet
	assert first_author.name == 'Ada'
	assert by_user[first_author.id.str()].len == 2
}
