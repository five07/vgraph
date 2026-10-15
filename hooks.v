module vgraph

import context
import load
import five07.otel

// Hooks, interceptors and privacy. A model declares them in `hooks()`,
// `interceptors()` and `policy()`, beside `edges()`; an app registers more on
// its graph at startup (`use`, `intercept`, `policy`). Each gets the context
// that `with_ctx` gave.

// Mutate runs a write, or the rest of the hooks before it.
pub type Mutate = fn (ctx context.Context, mut m Mutation) !

// Hook wraps the writes of a table: it can change the mutation before `next`,
// check it after, or return an error, which stops the write and rolls back its
// transaction.
pub struct Hook {
pub:
	// name lets `skip` leave the hook out.
	name string
	// on: the operations the hook runs for; all of them when empty.
	on []Op
	// cond: the hook runs only when it returns true.
	cond ?fn (ctx context.Context, m Mutation) bool
	run  fn (next Mutate) Mutate @[required]
}

// on returns `h`, run only for the operations `ops`.
pub fn on(h Hook, ops ...Op) Hook {
	return Hook{
		...h
		on: ops
	}
}

// only_if returns `h`, run only when `cond` returns true, and its own condition
// holds.
pub fn only_if(h Hook, cond fn (ctx context.Context, m Mutation) bool) Hook {
	inner := h.cond
	return Hook{
		...h
		cond: fn [inner, cond] (ctx context.Context, m Mutation) bool {
			if c := inner {
				if !c(ctx, m) {
					return false
				}
			}
			return cond(ctx, m)
		}
	}
}

// unless returns `h`, run only when `cond` returns false, and its own condition
// holds.
pub fn unless(h Hook, cond fn (ctx context.Context, m Mutation) bool) Hook {
	return only_if(h, fn [cond] (ctx context.Context, m Mutation) bool {
		return !cond(ctx, m)
	})
}

// wrap returns `next` behind `h`, which decides on each write whether it runs.
fn (h Hook) wrap(next Mutate) Mutate {
	run := h.run(next)
	return fn [h, run, next] (ctx context.Context, mut m Mutation) ! {
		mut applies := h.on.len == 0 || m.operation() in h.on
		if applies {
			if c := h.cond {
				applies = c(ctx, m)
			}
		}
		if applies {
			run(ctx, mut m)!
		} else {
			next(ctx, mut m)!
		}
	}
}

// Intercept changes a query of `table` before it runs, or returns an error,
// which fails it.
pub type Intercept = fn (ctx context.Context, table string, mut q load.Query) !

// Interceptor runs before every select of its table: root queries, counts, edge
// loads and traversals.
pub struct Interceptor {
pub:
	name string // lets `skip` leave it out
	run  Intercept @[required]
	// edges: it runs on edge loads too. With `false` it runs on root queries,
	// counts, traversals and edge predicates only, so an edge still reaches
	// the rows it hides, such as an article's soft-deleted author.
	edges bool = true
}

// Decision is what a privacy rule decides.
pub enum Decision {
	allow // the operation runs; later rules don't
	deny  // the operation fails with a `PrivacyError`
	skip  // the next rule decides
}

// QueryRule decides on a query of `table`. It may narrow `q` and skip, as a
// filter.
pub type QueryRule = fn (ctx context.Context, table string, mut q load.Query) !Decision

// MutationRule decides on a write.
pub type MutationRule = fn (ctx context.Context, m Mutation) !Decision

// Policy is the privacy rules of queries and writes. Rules run in order, and the
// first that allows or denies decides; when they all skip, the operation runs,
// so end a list with `always_deny` where nothing else should.
pub struct Policy {
pub:
	query    []QueryRule
	mutation []MutationRule
}

// merged returns `p`'s rules, then `other`'s.
pub fn (p Policy) merged(other Policy) Policy {
	mut query := p.query.clone()
	query << other.query
	mut mutation := p.mutation.clone()
	mutation << other.mutation
	return Policy{
		query:    query
		mutation: mutation
	}
}

// always_allow allows any write.
pub fn always_allow(_ context.Context, _ Mutation) !Decision {
	return .allow
}

// always_deny denies any write.
pub fn always_deny(_ context.Context, _ Mutation) !Decision {
	return .deny
}

// always_allow_query allows any query.
pub fn always_allow_query(_ context.Context, _ string, mut _ load.Query) !Decision {
	return .allow
}

// always_deny_query denies any query.
pub fn always_deny_query(_ context.Context, _ string, mut _ load.Query) !Decision {
	return .deny
}

// PrivacyError is the error of a query or a write that a privacy rule denied.
pub struct PrivacyError {
	Error
pub:
	table string
	op    string // `query`, or the write's operation
}

// msg names what was denied.
pub fn (e PrivacyError) msg() string {
	return 'privacy: ${e.op} of `${e.table}` denied'
}

// Registry holds what an app registers on a graph at startup. Every copy of a
// client shares it; registering while queries run is not safe across threads.
@[heap]
struct Registry {
mut:
	hooks        []Hook
	table_hooks  map[string][]Hook
	intercepts   []Interceptor
	table_ints   map[string][]Interceptor
	policies     []Policy
	table_policy map[string][]Policy
}

// use registers hooks for the writes of every table.
pub fn (c Client) use(hooks ...Hook) {
	mut r := c.registry
	r.hooks << hooks
}

// use_on registers hooks for the writes of `table`.
pub fn (c Client) use_on(table string, hooks ...Hook) {
	mut r := c.registry
	mut list := r.table_hooks[table] or { []Hook{} }
	list << hooks
	r.table_hooks[table] = list
}

// intercept registers interceptors for the queries of every table.
pub fn (c Client) intercept(interceptors ...Interceptor) {
	mut r := c.registry
	r.intercepts << interceptors
}

// intercept_on registers interceptors for the queries of `table`.
pub fn (c Client) intercept_on(table string, interceptors ...Interceptor) {
	mut r := c.registry
	mut list := r.table_ints[table] or { []Interceptor{} }
	list << interceptors
	r.table_ints[table] = list
}

// policy registers privacy rules for every table.
pub fn (c Client) policy(policies ...Policy) {
	mut r := c.registry
	r.policies << policies
}

// policy_on registers privacy rules for `table`.
pub fn (c Client) policy_on(table string, policies ...Policy) {
	mut r := c.registry
	mut list := r.table_policy[table] or { []Policy{} }
	list << policies
	r.table_policy[table] = list
}

// skip returns a client that leaves out the hooks and interceptors named
// `names`, such as `soft_delete`.
pub fn (c Client) skip(names ...string) Client {
	mut skipped := c.skipped.clone()
	skipped << names
	return Client{
		...c
		skipped: skipped
	}
}

// privileged returns a client that skips privacy rules, for seeds, migrations
// and system jobs.
pub fn (c Client) privileged() Client {
	return Client{
		...c
		privileged: true
	}
}

// bypass returns a client that skips privacy rules and interceptors, for
// reading back the rows a write stored.
pub fn (c Client) bypass() Client {
	return Client{
		...c
		privileged: true
		bypassed:   true
	}
}

// policies_of returns the policies of `table`: the graph's, the table's, then
// the model's.
fn (c Client) policies_of(table string) []Policy {
	mut all := c.registry.policies.clone()
	all << c.registry.table_policy[table] or { []Policy{} }
	if p := c.schema.policies[table] {
		all << p
	}
	return all
}

// prepare_query returns `q` as the privacy rules and interceptors of `table`
// leave it, in that order, or the error of a rule that denies it.
pub fn (c Client) prepare_query(table string, q load.Query) !load.Query {
	return c.prepare(table, q, false)
}

// prepare_edge_query returns `q`, a query of the targets of an edge load, as
// `prepare_query` does, but without the interceptors that leave edge loads out
// (`Interceptor.edges`).
pub fn (c Client) prepare_edge_query(table string, q load.Query) !load.Query {
	return c.prepare(table, q, true)
}

fn (c Client) prepare(table string, q load.Query, edge bool) !load.Query {
	mut query := load.Query{
		...q
		conds: q.conds.clone()
	}
	if c.bypassed {
		return query
	}
	// a `full` model's rules and interceptors each have a span
	full := c.full_spans(table)
	if !c.privileged {
		policies := c.policies_of(table)
		if !full || policies.all(it.query.len == 0) {
			c.decide_query(c.ctx, table, policies, mut query)!
		} else {
			ctx, span := c.tracer.start(c.ctx, 'privacy ${table}',
				attributes: [otel.string_attr(db_collection_name, table),
					otel.string_attr(vgraph_operation, 'query')]
			)
			decision := c.decide_query(ctx, table, policies, mut query) or {
				span_failed(span, err)
				span.end()
				return err
			}
			span.set_attributes(otel.string_attr(vgraph_decision, decision))
			span.end()
		}
	}
	mut all := c.registry.intercepts.clone()
	all << c.registry.table_ints[table] or { []Interceptor{} }
	all << c.schema.interceptors[table] or { []Interceptor{} }
	for i in all {
		if (i.name != '' && i.name in c.skipped) || (edge && !i.edges) {
			continue
		}
		if !full {
			i.run(c.ctx, table, mut query)!
			continue
		}
		mut attrs := [otel.string_attr(db_collection_name, table)]
		if i.name != '' {
			attrs << otel.string_attr(vgraph_interceptor, i.name)
		}
		ctx, span := c.tracer.start(c.ctx, 'intercept ${table}', attributes: attrs)
		i.run(ctx, table, mut query) or {
			span_failed(span, err)
			span.end()
			return err
		}
		span.end()
	}
	if query.lock.mode != .off && !c.in_tx {
		return error('`for_update` and `for_share` lock rows until a transaction ends: run them in `tx`')
	}
	// the subqueries of edge predicates and traversals: their tables' rules
	query.conds = c.prepare_conds(query.conds)!
	return query
}

// decide_query runs the query rules of `policies` on `query`, until one allows
// or denies it, and returns what decided: `allow`, or `skip` when every rule
// skipped. A rule that denies it is a `PrivacyError`.
fn (c Client) decide_query(ctx context.Context, table string, policies []Policy, mut query load.Query) !string {
	for p in policies {
		for rule in p.query {
			match rule(ctx, table, mut query)! {
				.allow {
					return 'allow'
				}
				.deny {
					return PrivacyError{
						table: table
						op:    'query'
					}
				}
				.skip {}
			}
		}
	}
	return 'skip'
}

// prepare_conds returns `conds` with each subquery of a registered table
// prepared as a query of it (`prepare_query`): its privacy rules and
// interceptors apply, as they do to an edge load.
fn (c Client) prepare_conds(conds []load.Cond) ![]load.Cond {
	mut out := []load.Cond{cap: conds.len}
	for cond in conds {
		match cond.junction {
			.and, .or, .not {
				out << load.Cond{
					...cond
					children: c.prepare_conds(cond.children)!
				}
			}
			.sub {
				s := cond.sub[0]
				prepared := if s.table in c.schema.tables {
					c.prepare_query(s.table, load.Query{
						conds: s.conds
					})!.conds
				} else {
					c.prepare_conds(s.conds)!
				}
				out << load.Cond{
					...cond
					sub: [load.Sub{
						...s
						conds: prepared
					}]
				}
			}
			else {
				out << cond
			}
		}
	}
	return out
}

// hooks_of returns the hooks of `table`, outermost first: privacy, the graph's,
// the table's, then the model's.
fn (c Client) hooks_of(table string) []Hook {
	mut all := []Hook{}
	if !c.privileged {
		mut rules := []MutationRule{}
		for p in c.policies_of(table) {
			rules << p.mutation
		}
		if rules.len > 0 {
			all << privacy_hook(table, rules)
		}
	}
	all << c.registry.hooks
	all << c.registry.table_hooks[table] or { []Hook{} }
	all << c.schema.hooks[table] or { []Hook{} }
	return all.filter(it.name == '' || it.name !in c.skipped)
}

fn privacy_hook(table string, rules []MutationRule) Hook {
	return Hook{
		name: 'privacy'
		run:  fn [table, rules] (next Mutate) Mutate {
			return fn [table, rules, next] (ctx context.Context, mut m Mutation) ! {
				decide: for rule in rules {
					match rule(ctx, m)! {
						.allow { break decide }
						.deny {
							return PrivacyError{
								table: table
								op:    m.operation().str()
							}
						}
						.skip {}
					}
				}
				next(ctx, mut m)!
			}
		}
	}
}

// soft_delete_query returns an interceptor that leaves out the rows whose
// `column` is set. With `soft_delete_hook`, it makes a table's deletes soft.
// Both are named `soft_delete`: `skip('soft_delete')` reads and changes deleted
// rows.
pub fn soft_delete_query(column string) Interceptor {
	return Interceptor{
		name: 'soft_delete'
		run:  fn [column] (_ context.Context, _ string, mut q load.Query) ! {
			q.conds << load.is_null(column)
		}
	}
}

// soft_delete_hook returns a hook that turns a delete into an update setting
// `column` to the current time, and keeps updates and deletes away from rows
// already deleted.
pub fn soft_delete_hook(column string) Hook {
	return Hook{
		name: 'soft_delete'
		on:   [.update_one, .update, .delete_one, .delete]
		run:  fn [column] (next Mutate) Mutate {
			return fn [column, next] (ctx context.Context, mut m Mutation) ! {
				m.where(load.is_null(column))
				match m.operation() {
					.delete_one {
						m.set_op(.update_one)
						m.set_field_value(column, now())
					}
					.delete {
						m.set_op(.update)
						m.set_field_value(column, now())
					}
					else {}
				}
				next(ctx, mut m)!
			}
		}
	}
}
