# vgraph: plan to v0.1.0

## 0. Context for agents

**What vgraph is.** An [Ent](https://entgo.io)-style graph layer for V, published
(once VPM allows) as `five07.vgraph` from `github.com/five07/vgraph`. Models are plain
V structs whose `edges()`, `fields()`, `hooks()`, `interceptors()`, `policy()`,
`indexes()` and `graphql()` methods declare the schema. `vgraph gen` writes a typed
client (queries, eager loads, traversals, write builders) and a GraphQL server with
entgql's conventions. Edges load in one query per edge per level, never one per row.

**Where it stands (2026-10-13).** Phases 0–7 are done on `develop`: batched loading,
the generator, non-int keys, a GraphQL implementation of its own, migration helpers
for `v.migrations`, Ent parity (writes, hooks, interceptors, privacy, the query API,
schema options, global ids, entgql's Node, connections and mutations), and
`examples/service` running on vgraph alone. Their plan, results and every decision
(Q1–Q120) are in git history: `git show bb105cd:PLAN.md`, the last version before
this rewrite. Comments in the code that cite `PLAN.md, Q<n>` with `n` up to 120 refer
to that version. This plan's questions start at Q121.

**Layout.**
- `edge.v`, `schema.v`, `field.v`, `client.v`, `driver.v`, `mutation.v`, `write.v`,
  `hooks.v`, `trace.v`, `gql.v`, `migrate.v`: the `vgraph` module.
- `load/`: batched selects, conditions, the keys-first plan for SQL the ORM can't
  run, per-parent windows, keyset cursors.
- `graphql/`: lexer, parser, validator, executor, introspection, HTTP handler,
  Relay helpers. It never imports vgraph, so it can move to `five07.graphql`.
- `gen/`, `cmd/vgraph/`: the generator (`vgraph gen`, `vgraph describe`).
- `sqlite/`, `pg/`: drivers that run vgraph's own parameterized SQL.
- `examples/relations/`: every Ent relationship kind and schema option, tested on
  SQLite and PostgreSQL. `examples/service/`: a GraphQL API on vgraph alone.
- `regressions/`: one small program per V compiler bug vgraph works around (8 so far).

**How to work here.**
- **Never commit.** The user makes every commit, on `develop`; `main` gets merges.
- **Decisions go in this file**, as numbered **Q** with a **Default** and an empty
  `> A:` line the user fills in. Read the answers before starting a goal; record
  each goal's result under it, with what was decided along the way.
- **V:** built against V master `53dd72c` (CI's `V_COMMIT`), which has
  `v.migrations`. Generics across modules and comptime are where compiler bugs have
  been: prefer generated code to generics, and add a `regressions/` program for each
  new bug.
- **Tests:** `v test .` (SQLite; about 80 seconds). PostgreSQL:
  `v -d vgraph_pg test pg_test.v examples/relations/pg_test.v`, with `PGHOST`,
  `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE`; the tests drop and recreate their
  tables, so use a throwaway database. graphql-js: `graphql/testdata/check_schema.js`,
  with `graphql@16.11.0` from npm on `NODE_PATH`.
- **After changing the generator or a model:** run `v run cmd/vgraph gen` on
  `examples/service` and `examples/relations`; CI fails when the checked-in output is
  stale. A change to `examples/service`'s schema needs `testdata/introspection.json`
  re-recorded from graphql-js (`graphql/testdata/README.md`).
- **CI** (`.github/workflows/ci.yml`) runs only on pushes to `main`: `v fmt -verify`,
  `v vet`, generated code up to date, `v test`, PostgreSQL, graphql-js. It hasn't run
  yet: `develop` hasn't been merged.
- **Style:** doc comments on every `pub` item (`v vet` checks them); plain, short
  sentences in comments and docs that say what a thing does and why.

## 1. Goals for v0.1.0

From `TODO.md` (2026-10-13), which this plan replaces; after v0.1.0, new work comes
from GitHub issues. Each goal lists its tasks, then its questions.

**Order.** quality first, then features, then docs and the
release: G1 N+1 audit → G2 coverage → G3 polymorphic foreign keys → G4 schema check →
G5 pagination example → G6 auth example → G7 OpenTelemetry → G8 Federation → G9 docs
→ G10 README sections → G11 issue templates → G13 release. G12 (fixes in V) runs
alongside, and doesn't hold up the release.


### G1. No N+1 queries, verified

Every read path should run a fixed number of selects, whatever the number of rows.
`examples/relations` and `examples/service` assert the selects of many queries, but
not of every path.

Tasks:
- a test helper that runs a query on small and larger data, and asserts the selects
  are the same list (as `examples/service`'s
  `test_queries_run_a_fixed_set_of_selects` does);
- run it over each path: root lists, every edge kind (`with_<edge>`, nested and
  named), traversals, edge predicates, counts, aggregates, `node` / `nodes`,
  connections at the root and nested (with `totalCount`), per-parent limits, privacy
  and interceptor subqueries, and the GraphQL resolvers of each;
- fix what grows, and list the paths in the README.

**Q122. Writes too?** A bulk create on SQLite is one insert per row (its `RETURNING`
doesn't promise the rows' order), a create's edge writes are a statement per edge,
and hooks run per row. **Default:** reads are fixed; writes are documented as
statements per row or per edge, and the audit only checks that they don't grow with
rows they don't touch. The other choice is batching SQLite's bulk writes too.
> A: No, writes (or any queries post-write in a transaction) are not included

### G2. Coverage

**Q123. How it's measured, and the bar.** V master has `v -cov` (line coverage of
tests). **Default:** measure the `vgraph`, `load`, `graphql`, `gen`, `sqlite` and `pg`
modules with it, keep the report out of git, add tests where whole features turn out
untested, and record the numbers here. No CI gate for v0.1.0: the number is a guide,
not a target. The other choice is a minimum, such as 80%, that CI enforces.
> A: default

### G3. Polymorphic foreign keys

A polymorphic edge (`owner_type` / `owner_id`) can't have a database foreign key, so
nothing in vgraph checks that `owner_id` names a row of the table `owner_type` names.
`examples/service` checks it with a hook of its own (`hooks.v`).

**Q124. What vgraph does.** **Default:** (a) and (b).
- (a) The write engine checks it: a create or update that sets a polymorphic
  many_to_one edge's column reads the target by key, through the target table's root
  query (so a soft-deleted target counts as missing), and fails with a
  `ValidationError` when there is none. `examples/service`'s hook then keeps only the
  reply's parent check.
- (b) The migration helpers add database triggers that check it on insert and update,
  on SQLite and PostgreSQL, for apps that also write outside vgraph:
  `vgraph.add_polymorphic_checks(mut ctx, schema)`.
- (c) Only (a).
> A: default

### G4. Schema discovery and validation

**Q125. What this means.** **Default:** (a) now; (b) after v0.1.0, if an issue asks.
- (a) `vgraph check <project>`: compares a database (its URL in an environment
  variable) with the schema, and reports what differs: missing tables or columns,
  types, nullability, the indexes edges need, foreign keys, global-id ranges. It reads
  SQLite's `sqlite_master` and pragmas, and PostgreSQL's `information_schema`. Useful
  in CI after migrations, and before a deploy.
- (b) Discovery: read an existing database and write V models with `edges()` from its
  foreign keys, as Ent's `entimport` does.
> A: Sorry, this was my fault for the ambiguity. What I mean is Introspection - https://graphql.org/learn/introspection/

### G5. Pagination example

GraphQL lists already page two ways: `limit` / `offset` lists, and, per table with
`relay: true`, Relay connections (`first` / `after`, `last` / `before`, `edges`,
`node`, `cursor`, `pageInfo`, `totalCount`). What's missing is an example, and docs
that compare them (<https://graphql.org/learn/pagination/>).

Tasks: `examples/pagination`, with two tables, one with connections and one with
lists, a seed of a few hundred rows, tests that page through both (forwards,
backwards, ordered by a field, nested per parent), and a README that says when to use
which, with the queries a client sends.

**Q126. `offset` on connections?** The `TODO.md` item lists "first, after, offset".
**Default:** no: a connection pages by cursor, as Relay and entgql do, and offset
pages are what lists are for. The other choice adds `offset` to connections.
> A: default

### G6. Auth example: a JWT and access rules

**Q127. The example.** **Default:** `examples/auth`, on veb:
- a `login` mutation (hand-written, in the example's `.graphql` file) checks a
  password (a `sensitive` field, hashed in a hook) and returns an HS256 JWT, signed
  with a secret from the environment;
- the HTTP handler reads `Authorization: Bearer <token>`, verifies it, and passes a
  `Viewer` context; no token is an anonymous viewer, a bad or expired one an error;
- privacy policies: anyone reads published posts, only their author drafts; only the
  author updates or deletes a post; an `admin` claim may do anything; a hook sets the
  author from the viewer on create;
- tests for each rule over HTTP, and a README walkthrough with `curl`.
> A: Agreed, just make sure that hooks are demonstrated for privleged vs non-privleged users.

**Q128. The JWT code.** **Default:** in the example, about 100 lines with
`crypto.hmac`, `crypto.sha256` and `encoding.base64`, since vgraph doesn't do
authentication. The other choices: a small `five07.vgraph.auth` module, or a VPM
package.
> A: just scaffold what is needed in the example. I don't want to rely on external VPM deps but have a look at `https://vpm.vlang.io/packages/deatil.vjwt` for fitness.

### G7. OpenTelemetry

`vgraph.trace` reports each statement (kind, table, duration, failure; no values).
V has no OpenTelemetry SDK.

**Q129. Shape.** **Default:** a module, `five07.vgraph.otel`, so the core gets no
dependency:
- a span per statement, from `vgraph.trace`, with the semantic conventions'
  `db.system`, `db.operation.name` and `db.collection.name`, and no values; a span per
  GraphQL request and resolver (`graphql.operation.type`, `graphql.operation.name`),
  from a hook the `graphql` module's executor gains;
- the parent span from the request's `traceparent` header (W3C Trace Context), passed
  on through `with_ctx`;
- an OTLP/HTTP exporter (JSON), batched, to a collector URL;
- tests against a fake collector, and a check by hand against the OpenTelemetry
  Collector in Docker.
> A: I like that idea. We'll hold this idea until we create the `five07.vgraph.otel` package - it looks like no package exists.

### G8. Federation v2 subgraphs

**Q130. Scope.** **Default:** a `vgraph gen --federation` flag makes the schema an
Apollo Federation v2 subgraph:
- `extend schema @link(url: "https://specs.apollo.dev/federation/v2.x", import: [...])`;
- each `node` table is an entity, `@key(fields: "id")`, and `_entities` resolves
  representations by id, one query per table, as `nodes` does;
- `_service { sdl }` returns the schema with its applied directives
  (`print_schema_with`), with `_Any`, `_Entity` and `_service` added;
- tested by composing `examples/service` with a second small subgraph through
  `@apollo/composition` from npm in CI, and once by hand behind Apollo Router.
> A: agreed

### G9. Docs

**Q131. Where and what.** **Default:**
- a `docs/` folder of Markdown guides, linked from the README: getting started;
  schema (fields, edges, options, mixins, views, global ids); queries; writes; hooks,
  interceptors and privacy; transactions; GraphQL (schema, connections, mutations,
  options, operations folders, federation); migrations; drivers; tracing and
  OpenTelemetry; differences from Ent;
- the README cut down to an overview, a quick start and links;
- API docs from doc comments (`v doc`), built in CI without warnings;
- the guides' code taken from, or compiled in, the tests and examples, so it can't
  drift.
> A: agreed

### G10. README: Contributing and Credits

**Q132. Content.** **Default:**
- **Contributing:** the development setup (the `~/.vmodules/five07/vgraph` link,
  tests, PostgreSQL, graphql-js), branches (`develop` for work, `main` for releases),
  regenerating the examples, a `regressions/` program for each compiler bug, doc
  comments and style, and issues and PRs through GitHub (G11);
- **Credits:** Ent and entgql (the design and names vgraph follows), graphql-js (the
  reference its GraphQL module is tested against), the GraphQL and Relay specs, V, its
  ORM and `v.migrations`, and `rest-api`, which `examples/service` started from.
  Anyone else to name?
> A: graphql.org and vlang.io

### G11. GitHub issue templates

**Q133. Which.** **Default:** adapted from `vlang/v`'s `.github/ISSUE_TEMPLATE/`:
- a bug report: V version and commit, vgraph version, database and driver, the model
  and the query that fail, the SQL `vgraph.trace` shows, expected and actual;
- a feature request: what it's for, and the Ent or entgql feature it maps to, if any;
- `config.yml`: blank issues off, and a link to the docs;
- a pull request template: tests, regenerated examples, docs;
- labels as in `vlang/v` where they fit (`bug`, `feature request`, `docs`), and
  `upstream` for a V bug.
> A: agreed

### G12. Fixes in V

vgraph works around these; fixing them in V lets it drop code.
- **`orm.RawConnection`:** an optional interface (`exec_raw(query, params
  []Primitive) ![][]Primitive`, `dialect()`) that the SQLite, PostgreSQL and MySQL
  drivers implement through their typed bind paths (`sqlite_stmt_binder`,
  `pg_stmt_binder`), so raw SQL gets typed parameters, NULL and typed results. Then
  vgraph's `sqlite` and `pg` adapters can go.
- **`[]u8` columns:** the ORM can bind one, but can't create one on SQLite (`Unknown
  type`) or read one back (`sqlite_select_column`, `db.pg`). Then vgraph can add bytes
  fields.
- **`db.pg` and `u32` / `u64`:** decoded wrongly (`*unsafe { &u32(&data) }` after
  `str.int()`); vgraph reads them as `i64`.
- **The 8 compiler bugs in `regressions/`.**

**Q134. How far.** **Default:** an issue for each, with a fix PR where the fix is
clear (the `db.pg` decode, `[]u8` on SQLite), and `RawConnection` proposed in an issue
first. vgraph drops a workaround only once its fix is in the V commit it pins. None
holds up v0.1.0.
> A: agreed, but we'll touch back on this last

### G13. Release v0.1.0

Carried over from the old plan (its Q13 and Q119).

**Q135. Steps.** **Default:**
1. merge `develop` into `main`, so CI runs for the first time, and fix what fails;
2. pin V: a `0.5.x` release that includes `v.migrations` when there is one; else keep
   the master commit, and say so in the README and `v.mod`;
3. check the README and docs against the code, and set `v.mod`'s version;
4. tag `v0.1.0` on `main`;
5. submit to VPM once its GitHub login works again, with the `vlang` and
   `vlang-package` topics on the repository; until then, install from GitHub.
> A: yes, I am kinda waiting on `0.5.3` first

**Q136. Exit criteria for each goal.** **Default:** its tasks are done, or moved on
purpose with a reason; tests on SQLite and PostgreSQL where it touches the database;
`v fmt -verify`, `v vet`, the generated examples up to date and graphql-js all pass;
the README or docs describe it; its result is recorded under the goal.
> A: agreed
