# vgraph: research and plan

An Ent-style ([entgo.io](https://entgo.io)) graph layer for V: edges declared once,
loaded in batches and traversed through a typed API, with schema changes applied
through V's own `v.migrations` module. It would be published on VPM as
`five07.vgraph`.

Questions are marked **Q** with a `> A:` line for your answer. Anything I've assumed is
marked **Default**.

---

## 1. Reference: V modules and VPM

### Links

| What | Where |
|------|-------|
| VPM, the package registry | <https://vpm.vlang.io> |
| Submit a package (GitHub login) | <https://vpm.vlang.io/new> |
| VPM's own source | <https://github.com/vlang/vpm> |
| Docs: creating modules | <https://docs.vlang.io/modules.html> |
| Docs: package management and publishing | <https://docs.vlang.io/package-management.html> (see "Publish package") |
| VPM guide: version ranges, lockfile | <https://github.com/vlang/v/blob/master/cmd/tools/vpm/README.md> |
| Standard library docs | <https://modules.vlang.io> |
| V ORM README (relations, `include`, joins) | <https://github.com/vlang/v/blob/master/vlib/orm/README.md> |

The same docs are in your checkout. It is V master at `53dd72c` (2026-10-12), which
reports itself as `V 0.5.2` but is 86 commits past the `0.5.2` tag (see Q13):
`~/Projects/vlang/v/doc/docs.md` ("Modules" around line 4285, "Package management"
around line 7664, "Publish package" around line 7912), `cmd/tools/vpm/README.md`, and
`vlib/orm/README.md`.

### What matters for a package

- **Module vs package:** a *module* is one folder of `.v` files sharing a `module`
  name. A *package* is one or more modules with a `v.mod` at the top, which also
  anchors imports (`import vgraph.load` resolves against the folder holding `v.mod`).
- **Names:** `snake_case`, and the docs say under 10 characters (`vgraph` is 6). VPM
  lowercases a name and turns `-` into `_` when installing.
- **Starting a project:** `v new --lib vgraph` creates `v.mod`, a library template
  and a git repository. `--agents-md` also writes an `AGENTS.md` contributor file.
- **`v.mod` fields:** `name`, `description`, `version`, `license`, `dependencies` (a
  string list, which may carry semver ranges such as `'vsl@^0.1.47'`), and optional
  `base_url` (the source folder) and `subdirs`.
- **Lockfile:** `v install` inside a project writes `v.mod.lock`. Commit it, and use
  `v install --locked` in CI.
- **Install locations:** `~/.vmodules` by default (`VMODULES` overrides it), or
  `v install --local` to install beside the project's own modules.
- **Publishing:**
  1. push a public GitHub repo with `v.mod` at its root;
  2. submit it at <https://vpm.vlang.io/new>, logged in with GitHub;
  3. it is then installed as `<github-user>.vgraph`.

  **The VPM entry can't be edited after submission, so check the name and repo URL
  first.** Tag the repo `vlang` and `vlang-package` on GitHub so it shows up in searches.
- **Releases:** semver tags (`v0.1.0`). VPM's version ranges select tags, and
  prereleases need an explicit prerelease constraint.
- **API docs:** `v doc` generates them from doc comments, so every `pub` item needs
  one, as in `rest-api`.

## 2. Prior art (checked 2026-10-12)

- **On VPM:** `v search` for `orm`, `graph`, `vgraph` and `dataloader` found no
  graph or edge-loading library. `vgraph` is unclaimed. The only near matches:
  - `luizfonseca.graphql`: a GraphQL *parser* only, work in progress, last updated
    about 3 years ago. It might serve as the parsing half of a GraphQL layer later.
  - `ghostnear.storm` / `ghostnear.vstorm`: an app framework for `gg` GUIs, unrelated.
- **V's ORM** (vlib, V 0.5.2) is relational:
  - has-many through `[]Child @[fkey: 'parent_id']`;
  - belongs-to through a struct-typed field;
  - implicit loading of those relations in `sql { }` blocks, or opt-in
    `include()` / `then_include()` in the `orm.new_query[T]` function API;
  - `join` / `left join` inside `sql { }`;
  - `@[references]` foreign keys.
  - **Gaps:** relation loading runs **one query per parent row** (stated in its
    README), there are no edge declarations, no generated client, and no polymorphic
    relations.
- **V's migrations** (`vlib/v/migrations`, added to master 2026-10-10, so **not** in
  the `0.5.2` tag): ordered, reversible migrations registered in V code
  (`migrations.new(mut db, [Migration{version, name, up, down}], Config{dialect: .sqlite})`),
  with `create_table`, `add_column`, `add_index` (normal and unique), `add_foreign_key`,
  `create_orm_table[T]`, and `migrate` / `rollback` / `redo` / `status`, for SQLite,
  Postgres and MySQL. Its tests pass on your local compiler. It doesn't diff a schema
  against the database or generate migration files: migrations are written by hand.
  The [announcement](https://vlang.veery.blog/post/25/introducing-orm-migrations-in-v)
  calls it `v3.migrations`; on master it is now `import v.migrations`.
- **Ent's model, which vgraph borrows:** a schema with `Fields()` and `Edges()`
  ([edges docs](https://entgo.io/docs/schema-edges)), a generator (`entc`) that writes
  a typed client, eager loading with `With<Edge>()` batched per level, traversal with
  `Query<Edge>()`, and migrations through [Atlas](https://atlasgo.io). vgraph uses
  `v.migrations` in place of Atlas (Q10).

## 3. Goals

1. **Batched edge loading:** loading an edge for N parents takes one query, not N. This
   is the core of the library, and what GraphQL resolvers need.
2. **Declared edges:** relationships are described once and checked when the program
   starts (`Client.new` validates every edge against the structs).
3. **Typed traversal and queries:** `client.articles().with_comments().all()!` and
   `article.query_comments().query_author().all()!`, through code generation.
4. **Built on `orm.Connection`**, so any adapter the ORM has (SQLite, Postgres, MySQL)
   works.

**Non-goals for v1:** Gremlin or other graph databases, hooks/privacy policies, GraphQL
execution (Q9: a separate `five07.graphql` package if wanted), and a migration engine of
its own (Q10: `v.migrations` runs them).

## 4. Design

### Edges

```v ignore
pub enum EdgeKind {
	one_to_many  // Article.comments: the child table holds the parent's id
	many_to_one  // Comment.author: this table holds the other record's id
	many_to_many // Article.tags: through a join table
	polymorphic  // Article.comments when Comment has owner_type + owner_id
}

pub struct Edge {
pub:
	name      string   // 'comments'
	kind      EdgeKind
	from      string   // table: 'articles'
	to        string   // table: 'comments'
	column    string   // the foreign key column: 'owner_id', 'user_id'
	type_col  string   // polymorphic only: 'owner_type'
	type_val  string   // polymorphic only: 'Article'
	through   string   // many_to_many only: the join table
	soft_del  string   // optional: 'deleted_at', filtered as IS NULL (Q7)
}
```

`rest-api` maps onto this directly: `users → articles` (one-to-many),
`comments → users` (many-to-one), `comments.parent_id` (a one-to-many self-edge), and
`articles/posts → comments` (polymorphic).

### Layers, in build order

| Layer | What | How | Phase |
|-------|------|-----|-------|
| `vgraph.load` | `load_many[P, C](conn, parents, edge) !map[int][]C` and `load_one[P, C](…) !map[int]C`: one `WHERE col IN (…)` per edge, de-duplicated ids | compile-time reflection (`$for field in T.fields`) plus the ORM function API | 1–2 |
| `vgraph.schema` | each entity declares `fn (Article) edges() []vgraph.Edge` (Default, see Q4); `Client.new` checks the edges against the struct fields | plain V, checked at startup | 2 |
| `vgraph gen` | a CLI that reads the schema and writes `client/*.v`: typed `with_<edge>()`, `query_<edge>()`, field predicates | code generation, like `entc` | 3 |
| GraphQL adapter | resolvers backed by `vgraph.load` batching | a separate `five07.graphql` package, maybe on top of `luizfonseca.graphql` | 4 (Q9) |
| migration helpers | turn declared edges into `v.migrations` steps: an index on every edge column, foreign keys, the join tables for many-to-many | helpers that return `migrations.Index` / `ForeignKey` / `Table`; `v.migrations` runs them | 5 (Q10) |

**Why split reflection and code generation:** V's compile-time reflection reads fields
and attributes, which is enough for generic loading. It **can't create methods**, so
typed traversals (`.query_comments()`) and predicates (`article.title_contains('V')`)
need a generator, which is the same reason Ent has `entc`.

**SQL:** `sql { }` blocks are fixed at compile time. Even `dynamic select` only switches
whole conditions on or off; the column names stay fixed. So vgraph can't use them for an
edge column it only knows at runtime. Two routes work (Phase 0 tested both), and Q17
chooses between them:
- `orm.new_query[T](conn).where('${col} IN ?', ids)`, the ORM's function API. It is
  **deprecated**: it leaves the standard library after 2027-08-17 (notices now,
  warnings from 2027-02-18; [vlang/v#27001](https://github.com/vlang/v/issues/27001)).
- `orm.Connection.select(SelectConfig, QueryData, where)`, the driver interface every
  adapter implements, with vgraph mapping the rows back into `T` through `$for`. It
  isn't deprecated, but vgraph then maps every field type itself.

Either way, vgraph avoids `@[fkey]` and the ORM's implicit relation loading, which makes
N+1 queries.

## 5. V 0.5.2 risks, from building `rest-api`

| Found in rest-api | What it means for vgraph | Mitigation |
|-------------------|--------------------------|------------|
| Generics across modules: codegen bugs `../web` works around; a false "unused function" notice | vgraph is mostly generics, so it will hit more | build against your local V master for now and pin a `0.5.x` release before `v0.1.0` (Q13); keep a `regressions/` test folder with one small test per compiler bug, each reported upstream with a fix PR where we can (Q11) |
| `@[index]` creates no index on SQLite | edge columns need indexes | `ctx.add_index` in a `v.migrations` migration (raw `CREATE INDEX IF NOT EXISTS` only before Phase 5) |
| `sqlite.DB.exec` ignores errors raised while a statement runs | silent failures in hand-written SQL | always `exec_param_many`, or the ORM |
| a variable named `update` inside `sql { }` silently skips the statement | — | mostly avoided by not using `sql { }`; a lint rule |
| the ORM's `last_insert_rowid()` races across threads | inserts return the wrong id | look rows up by a unique key; transactions |
| macOS libsqlite3 is in multi-thread mode | crashes under concurrency | document `connect_full(..., [.fullmutex])`; test with concurrent requests |
| `@[references]` columns are nullable | — | `sql_type: 'INTEGER NOT NULL'` |
| `orm.new_query` (the function API) leaves vlib after 2027-08-17 | the plan's query layer goes away | build on `orm.Connection.select` (Q17) |

Phase 0 checks the reflection that the loader depends on before anything else is built.

## 6. Phases

**Phase 0: reflection spike** (in this repo, under `spike/`, about a day).
Confirm that, on your local V master (Q13), a generic function in one module can:
- read `T`'s fields and attributes;
- run `orm.new_query[C](conn)` with a `where … in […]` condition built at runtime;
- group the rows by a column whose name it only knows at runtime.

Also write a short README.md for your first commit on `main` (this repo has none
yet).

*Exit:* a test that loads comments for 3 articles in one query.

*Result (2026-10-12, done):* `spike/` passes on local master `53dd72c`. A generic
`load_many[P, C]` in the `load` module reads `@[primary]`, `@[sql: 'col']` and
`@[table]` through `$for`, queries `owner_id IN (…)` once for 3 articles (one of them
repeated), and groups the rows by a column named at runtime. A `CountingConnection`
(Q16) asserts the query count. No compiler workarounds were needed. Both query routes
in Q17 pass the same test.

**Phase 1: dogfood in `example/`.** Copy `rest-api` into `example/` in this repo (Q14).
It becomes the test bed for each feature and, later, the published example. Then:
1. before changing anything, run its tests and record a baseline of the SQL each
   endpoint runs (Q16);
2. replace `slugs_of` + `app.distinct` + the `Owner` registry's loading with
   `vgraph.load`, in-tree at first (Q15).

`~/Projects/vlang/rest-api` itself is left alone.

*Exit:* every `example` test still passes, and the traced SQL shows the same number of
queries or fewer than the baseline.

**Phase 2: standalone package.** Add `v.mod` (`name: 'vgraph'`, MIT) to this repo's root;
`v new --lib` would make a new folder, so copy what it generates instead. Move the
`Edge` and `schema` layers there, with a SQLite test suite and a Postgres CI job (Q3).
Before publishing, pin to a `0.5.x` release that includes `v.migrations` (Q13), and
record it in the README and CI. Then publish `v0.1.0` to VPM from
`github.com/five07/vgraph`.
*Exit:* `v install five07.vgraph` works in a fresh project, and `example` imports it.

**Phase 3: generator.** First, the schema comparison from Q4: write the `example`
entities both as (a) `edges()` methods and as (c) a schema file, and choose one before
building `vgraph gen` on it. Then `vgraph gen` writes the typed client, and `example`
switches to it.
*Exit:* `example` uses no hand-written loading code.

**Phase 4: GraphQL** as a separate `five07.graphql` package, only if wanted (Q9).

**Phase 5: migration helpers** for `v.migrations` (Q10): from the declared edges,
produce the indexes, foreign keys and join tables as `migrations.Index` /
`ForeignKey` / `Table` values, for migrations written by hand. `example` moves its
table setup to `v.migrations`.

## 7. Questions

**Q1.** Repository and name: a GitHub repo `vgraph` under which account? The VPM name
becomes `<account>.vgraph`, and it can't be changed after submission.
> A: `five07` - this is the repo I will use.

**Q2.** V version: pin to 0.5.2 (stable to build against, but slower to get fixes),
or follow V master (fixes arrive sooner, along with API churn)? **Default:** pin, and
bump on purpose.
> A: yes, pin to 0.5.2 for now
>
> *Superseded by Q13: follow local master, and pin a `0.5.x` release before publishing.*

**Q3.** Databases: SQLite only for v1, or Postgres too (the `rest-api` stretch
goal)? **Default:** SQLite first, with Postgres in CI from Phase 2.
> A: SQLite first, with Postgres in CI from Phase 2.

**Q4.** How entities declare edges. **Default:** (a), plain and checkable.
- (a) a method, `fn (Article) edges() []vgraph.Edge`, like Ent's `Edges()`;
- (b) struct attributes, `@[edge: 'comments; to: Comment; fk: owner_id']`, which
  are compact but are stringly typed and only checked at runtime;
- (c) a separate schema file that `vgraph gen` reads.
> A: hmm, start with (a) and later let's test an example of (a) and (c) and then we'll decide. Works with Q5

**Q5.** Code generation in v1, or reflection-only loading first (Phases 0–2) with
the generator later? **Default:** reflection first; it shows sooner whether V's
generics hold up.
> A: default choice

**Q6.** Identifiers: assume an `int` primary key named `id` (Ent's default), with
slugs left to the app as in `rest-api`? **Default:** yes, with the key column
configurable per entity.
> A: default choice

**Q7.** Soft delete as a built-in edge option (`soft_del: 'deleted_at'`), since
`rest-api` filters it everywhere? **Default:** yes, opt-in per edge.
> A: default choice

**Q8.** Polymorphic edges in v1? They're the hardest kind and the one `rest-api`
needs most. **Default:** yes. Without them Phase 1 can't replace the `Owner` registry.
> A: default choice

**Q9.** GraphQL: build an executor in vgraph, adapt `luizfonseca.graphql` (parser
only, inactive for about 3 years), or keep GraphQL a separate project? **Default:**
separate; vgraph only provides the batching.
> A: default choice, we can pivot later if need be, but keeping this package lean is optimal. A separate five07.graphql package could be a good idea

**Q10.** Migrations (your Atlas TODO): inside vgraph, or a separate package (for
example `vmigrate`) that reads vgraph's schema? **Default:** separate.
> A: V ORM now has a migration tool and we should utilize it instead of an Atlas clone. (https://vlang.veery.blog/post/25/introducing-orm-migrations-in-v)

**Q11.** Upstream V bugs (`@[index]` on SQLite, `exec` swallowing errors, the
`update` name, `last_insert_rowid`): report or fix them in `vlang/v` as part of this
project, or only work around them? **Default:** report each one with the small
reproduction programs already written, and work around them in the meantime.
> A: like the changes I PR'd for veb/HMR, we'll potentially report issues with a PR ready.

**Q12.** License: MIT, matching `rest-api`? **Default:** MIT.
> A: MIT

### New questions from your answers

**Q13. Q2 and Q10 conflict.** `v.migrations` isn't in the `0.5.2` tag: it landed on
master on 2026-10-10. Your compiler, master `53dd72c`, has it and passes its tests, but
still reports `V 0.5.2`. **Default:** pin to master commit `53dd72c` instead of the tag.
Record it in the README and CI (`git checkout 53dd72c && make`), and bump it on purpose.
The other choice is to stay on the `0.5.2` tag and move Phase 5 until a release
includes `v.migrations`.
> A: let's use whatever master I have checked out for V. By the time we finish building, we will decide to pin on `0.5.X`

**Q14. Where `example/` lives, and what is copied.** **Default:** `vgraph/example/`, with
its own `v.mod` (`name: 'example'`), copied from `rest-api`'s last commit (`9d802d6`)
with `git archive`, which leaves out `.git`. That also leaves out `rest-api`'s
uncommitted `TODO.md` edit, its untracked `VGRAPH.md` (an older copy of this plan),
`PLAN.md` and any `.db` file. The name changes from `rest-api` to `example` in
`v.mod`, `.env.example` (`DB_PATH=example.db`) and the README.
> A: default choice

**Q15. How `example` imports vgraph during Phases 0–1.** A `v.mod` in `example/` makes
`example/` the import root, so it can't see `../load`. **Default:** keep the loader
inside `example/vgraph/load/` until Phase 2. Phase 2 then moves it to the package root
and symlinks `~/.vmodules/five07/vgraph` to this repo, so `example` already imports
`five07.vgraph` before anything is published. Or symlink from day one, which means
renaming nothing later but needs that symlink on every machine and in CI.
> A: default choice

**Q16. How queries are counted for the Phase 1 exit check.** `rest-api` has no SQL
tracing. **Default:** a small `CountingConnection` that wraps `orm.Connection` and
records each statement, used only in tests. Each endpoint test then asserts its query
count, so an N+1 regression fails the test instead of being caught by eye. It can later
become part of vgraph (`vgraph.trace`).
> A: sounds good

**Q17. Query layer: `orm.new_query`, or vgraph's own on `orm.Connection.select`?** Phase 0
found that the function API is deprecated. It leaves vlib after 2027-08-17 for a
separate repository that doesn't exist yet. **Default:** build on `Connection.select`.
vgraph already reflects over every field, the driver interface stays in vlib, and
Postgres/MySQL come with it. The cost is mapping each field type ourselves: options,
`time.Time`, enums, `sql_type` overrides. The spike maps int, i64, f64, bool and string
in about 60 lines (`spike/load/select.v`). The other choice is `new_query` for now,
switching when its new home is known.
> A:
