module main

fn test_quick_start() {
	// snippet: quick-start
	g := open()!
	ada := g.users().create().set_name('Ada').set_email('ada@example.com').save()!
	g.articles().create().set_author(ada).set_title('Hello, V').exec()!
	g.articles().create().set_author(ada).set_title('Batched loads').exec()!

	// two queries, however many articles: the articles, then their authors
	articles := g.articles().with_author().order_by_id().all()!
	for a in articles {
		author := a.author or { continue }
		println('${a.article.title} by ${author.user.name}')
	}
	// end snippet
	assert articles.map(it.article.title) == ['Hello, V', 'Batched loads']
	assert articles.map(it.author or { panic('not loaded') }.user.name) == ['Ada', 'Ada']
}
