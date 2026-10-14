module main

// A GraphQL API whose requests carry a JSON Web Token: `login` issues one,
// and each request runs as the viewer its token names, whose privacy rules
// and hooks decide what it may read and write. `v run .`, then follow the
// walkthrough in README.md.
import veb
import db.sqlite
import net.http
import os
import time
import v.migrations
import five07.vgraph
import five07.vgraph.graphql
import five07.vgraph.sqlite as vsqlite
import auth
import graph

pub struct Context {
	veb.Context
}

pub struct App {
	secret []u8
	gql    &graphql.Server = unsafe { nil }
}

// Config is what the app reads from the environment.
struct Config {
	db_path string = ':memory:'
	secret  string
	seed    bool = true
	port    int  = 8080
}

fn main() {
	cfg := config_from_env() or {
		eprintln('config: ${err}')
		exit(1)
	}
	mut api := new_app(cfg) or {
		eprintln('startup: ${err}')
		exit(1)
	}
	veb.run_at[App, Context](mut api, port: cfg.port) or {
		eprintln('server: ${err}')
		exit(1)
	}
}

// config_from_env reads `JWT_SECRET` (required: at least 32 bytes),
// `DB_PATH`, `SEED` and `PORT`.
fn config_from_env() !Config {
	return Config{
		db_path: os.getenv_opt('DB_PATH') or { ':memory:' }
		secret:  os.getenv('JWT_SECRET')
		seed:    (os.getenv_opt('SEED') or { 'true' }) == 'true'
		port:    (os.getenv_opt('PORT') or { '8080' }).int()
	}
}

// new_app opens and migrates the database, registers the rule that reads
// other rows, seeds the example's users when asked, and returns the app.
fn new_app(cfg Config) !&App {
	if cfg.secret.len < 32 {
		return error('JWT_SECRET must be at least 32 bytes')
	}
	mut db := sqlite.connect(cfg.db_path)!
	mut m := migrations.new(mut db, [initial], dialect: .sqlite)!
	m.migrate()!
	g := graph.Graph.new(vsqlite.new(db))!
	g.posts().policy(vgraph.Policy{
		mutation: [owner_only(g)]
	})
	if cfg.seed {
		seed(g)!
	}
	key := cfg.secret.bytes()
	return &App{
		secret: key
		gql:    g.graphql(graph.Resolvers{
			g:      g
			secret: key
		}, default_page: 20, max_page: 100)!
	}
}

// owner_only lets a member update or delete only their own posts: it reads
// the authors of the rows the write reaches through a privileged graph,
// which sees other members' drafts too. Rules registered on the graph run
// before the model's, so it leaves admins and the anonymous to those: the
// model's `allow_admin` and `deny_anonymous` decide them.
fn owner_only(g graph.Graph) vgraph.MutationRule {
	return fn [g] (ctx graphql.Context, m vgraph.Mutation) !vgraph.Decision {
		viewer := auth.viewer_of(ctx)
		if m.operation() == .create || viewer.admin || viewer.anonymous() {
			return .skip
		}
		keys := m.keys()!.map(it.i64())
		if g.privileged().posts().where_id_in(keys).where_author_id_ne(viewer.id).exist()! {
			return .deny
		}
		return .skip
	}
}

const initial = migrations.Migration{
	version: 1
	name:    'initial'
	up:      fn (mut ctx migrations.Context) ! {
		s := graph.schema()!
		vgraph.create_table(mut ctx, s, 'users')!
		vgraph.create_table(mut ctx, s, 'posts')!
		vgraph.add_edge_indexes(mut ctx, s)!
	}
	down:    fn (mut ctx migrations.Context) ! {
		ctx.drop_table('posts')!
		ctx.drop_table('users')!
	}
}

// seed adds an admin, Ada, and a member, Bob, with a published post and a
// draft, unless there are users already. Making an admin needs an admin, and
// posting as Bob needs one too, so the seed runs as an admin viewer of its own:
// the rules and hooks that check a request check the seed the same way.
fn seed(g graph.Graph) ! {
	if g.users().count()! > 0 {
		return
	}
	g.with_ctx(auth.Viewer{ admin: true }).tx(fn (tx graph.Graph) ! {
		tx.users().create().set_name('Ada').set_email('ada@example.com').set_password('ada-password').set_admin(true).exec()!
		bob := tx.users().create().set_name('Bob').set_email('bob@example.com').set_password('bob-password').save()!
		tx.posts().create().set_author(bob).set_title('Hello').set_body('My first post.').set_published_at(time.now()).exec()!
		tx.posts().create().set_author(bob).set_title('Draft').set_body('Not ready yet.').exec()!
	})!
}

// serve_graphql answers GraphQL requests as the viewer of their token: no
// `Authorization` header is the anonymous viewer, and a token that doesn't
// verify is a 401, before the request runs.
@['/graphql'; get; post]
pub fn (a &App) serve_graphql(mut ctx Context) veb.Result {
	viewer := a.viewer(ctx.req.header.get(.authorization) or { '' }) or {
		ctx.res.set_status(.unauthorized)
		ctx.set_custom_header('WWW-Authenticate', 'Bearer error="invalid_token"') or {}
		body := graphql.Value({
			'errors': graphql.Value([
				graphql.Value({
					'message': graphql.Value(err.msg())
				}),
			])
		}).json()
		return ctx.send_response_to_client('application/json; charset=utf-8', body)
	}
	res := a.gql.handle(graphql.HttpRequest{
		method:       ctx.req.method.str()
		content_type: ctx.req.header.get(.content_type) or { '' }
		accept:       ctx.req.header.get(.accept) or { '' }
		query_string: if ctx.req.url.contains('?') { ctx.req.url.all_after('?') } else { '' }
		body:         ctx.req.data
	}, viewer)
	for key, value in res.headers {
		ctx.set_custom_header(key, value) or {}
	}
	ctx.res.set_status(http.status_from_int(res.status))
	return ctx.send_response_to_client(res.content_type, res.body)
}

// viewer returns the viewer of the `Authorization` header `header`.
fn (a &App) viewer(header string) !auth.Viewer {
	if header == '' {
		return auth.Viewer{}
	}
	if !header.starts_with('Bearer ') {
		return error('Authorization must be `Bearer <token>`')
	}
	claims := auth.verify(header.all_after('Bearer ').trim_space(), a.secret, time.now())!
	return auth.Viewer{
		id:    claims.sub
		admin: claims.admin
	}
}
