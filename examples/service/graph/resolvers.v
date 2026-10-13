// Resolvers resolves the fields that this project's .graphql files add to the
// schema: the mutations of api.graphql. `vgraph gen` wrote this file and its
// stubs; the methods were then written by hand. Each calls the same store or
// service as the REST endpoint it mirrors, so both check and store writes the
// same way.
module graph

import five07.vgraph.graphql
import app
import articles.models as article_models
import comments.models as comment_models
import posts.models as post_models
import users.models as user_models

pub struct Resolvers {
pub:
	graph    Graph
	users    user_models.UserStore
	articles article_models.ArticleStore
	posts    post_models.PostStore
	comments comment_models.CommentStore
	// Comments are created through `comments.Service`, which checks their
	// owner; it imports this module, so the app passes its methods in.
	create_comment    fn (comment_models.CommentInput) !comment_models.Comment                      @[required]
	create_comment_on fn (string, string, comment_models.OwnedCommentInput) !comment_models.Comment @[required]
}

// input returns the mutation's `input` argument.
fn input(info graphql.FieldInfo) map[string]graphql.Value {
	return info.arg('input').as_map()
}

// text returns the string field `key` of an input; '' when it isn't set.
fn text(m map[string]graphql.Value, key string) string {
	return (m[key] or { graphql.null }).as_string()
}

// maybe returns the string field `key` of a patch: `none` when it isn't set.
fn maybe(m map[string]graphql.Value, key string) ?string {
	v := m[key] or { return none }
	if v is graphql.Null {
		return none
	}
	return v.as_string()
}

fn maybe_bool(m map[string]graphql.Value, key string) ?bool {
	v := m[key] or { return none }
	if v is graphql.Null {
		return none
	}
	return v.as_bool()
}

// failed returns `err` as the client may see it, as the REST API does.
fn failed(err IError) IError {
	return error(app.client_message(err))
}

// each returns `result` for each parent: a mutation has one, the root.
fn each(parents []graphql.Source, result graphql.Resolved) []graphql.Resolved {
	return parents.map(result)
}

fn (r Resolvers) user_node(u user_models.User) !graphql.Resolved {
	return graphql.obj(r.graph.users().nodes([u])![0])
}

fn (r Resolvers) article_node(a article_models.Article) !graphql.Resolved {
	return graphql.obj(r.graph.articles().nodes([a])![0])
}

fn (r Resolvers) post_node(p post_models.Post) !graphql.Resolved {
	return graphql.obj(r.graph.posts().nodes([p])![0])
}

fn (r Resolvers) comment_node(c comment_models.Comment) !graphql.Resolved {
	return graphql.obj(r.graph.comments().nodes([c])![0])
}

fn user_input(m map[string]graphql.Value) user_models.UserInput {
	return user_models.UserInput{
		name:  text(m, 'name')
		email: text(m, 'email')
	}
}

fn article_update(m map[string]graphql.Value) article_models.ArticleUpdate {
	return article_models.ArticleUpdate{
		title:     text(m, 'title')
		summary:   text(m, 'summary')
		body:      text(m, 'body')
		published: (m['published'] or { graphql.null }).as_bool()
	}
}

fn owned_comment(m map[string]graphql.Value) comment_models.OwnedCommentInput {
	return comment_models.OwnedCommentInput{
		user_slug:   text(m, 'userSlug')
		parent_slug: text(m, 'parentSlug')
		body:        text(m, 'body')
	}
}

// mutation_create_user resolves `Mutation.createUser`: `createUser(input: UserInput!): User!`.
pub fn (r Resolvers) mutation_create_user(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	user := r.users.insert(user_input(input(info))) or { return failed(err) }
	return each(parents, r.user_node(user)!)
}

// mutation_replace_user resolves `Mutation.replaceUser`: `replaceUser(slug: String!, input: UserInput!): User!`.
pub fn (r Resolvers) mutation_replace_user(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	user := r.users.replace(info.arg('slug').as_string(), user_input(input(info))) or {
		return failed(err)
	}
	return each(parents, r.user_node(user)!)
}

// mutation_update_user resolves `Mutation.updateUser`: `updateUser(slug: String!, input: UserPatch!): User!`.
pub fn (r Resolvers) mutation_update_user(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	m := input(info)
	user := r.users.patch(info.arg('slug').as_string(), user_models.UserPatch{
		name:  maybe(m, 'name')
		email: maybe(m, 'email')
	}) or { return failed(err) }
	return each(parents, r.user_node(user)!)
}

// mutation_delete_user resolves `Mutation.deleteUser`: `deleteUser(slug: String!): Boolean!`.
pub fn (r Resolvers) mutation_delete_user(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	r.users.soft_delete(info.arg('slug').as_string()) or { return failed(err) }
	return each(parents, graphql.Value(true))
}

// mutation_create_article resolves `Mutation.createArticle`: `createArticle(input: ArticleInput!): Article!`.
pub fn (r Resolvers) mutation_create_article(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	m := input(info)
	if text(m, 'userSlug') == '' {
		return error('an article needs a `user_slug`')
	}
	user_id := r.users.reference_id(text(m, 'userSlug')) or { return failed(err) }
	article := r.articles.insert(user_id, article_update(m)) or { return failed(err) }
	return each(parents, r.article_node(article)!)
}

// mutation_replace_article resolves `Mutation.replaceArticle`: `replaceArticle(slug: String!, input: ArticleUpdate!): Article!`.
pub fn (r Resolvers) mutation_replace_article(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	article := r.articles.replace(info.arg('slug').as_string(), article_update(input(info))) or {
		return failed(err)
	}
	return each(parents, r.article_node(article)!)
}

// mutation_update_article resolves `Mutation.updateArticle`: `updateArticle(slug: String!, input: ArticlePatch!): Article!`.
pub fn (r Resolvers) mutation_update_article(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	m := input(info)
	article := r.articles.patch(info.arg('slug').as_string(), article_models.ArticlePatch{
		title:     maybe(m, 'title')
		summary:   maybe(m, 'summary')
		body:      maybe(m, 'body')
		published: maybe_bool(m, 'published')
	}) or { return failed(err) }
	return each(parents, r.article_node(article)!)
}

// mutation_delete_article resolves `Mutation.deleteArticle`: `deleteArticle(slug: String!): Boolean!`.
pub fn (r Resolvers) mutation_delete_article(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	r.articles.soft_delete(info.arg('slug').as_string()) or { return failed(err) }
	return each(parents, graphql.Value(true))
}

// mutation_create_article_comment resolves `Mutation.createArticleComment`: `createArticleComment(slug: String!, input: OwnedCommentInput!): Comment!`.
pub fn (r Resolvers) mutation_create_article_comment(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	comment := r.create_comment_on(comment_models.owner_type[article_models.Article](),
		info.arg('slug').as_string(), owned_comment(input(info))) or { return failed(err) }
	return each(parents, r.comment_node(comment)!)
}

// mutation_create_post resolves `Mutation.createPost`: `createPost(input: PostInput!): Post!`.
pub fn (r Resolvers) mutation_create_post(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	m := input(info)
	if text(m, 'userSlug') == '' {
		return error('a post needs a `user_slug`')
	}
	user_id := r.users.reference_id(text(m, 'userSlug')) or { return failed(err) }
	post := r.posts.insert(user_id, post_models.PostUpdate{ body: text(m, 'body') }) or {
		return failed(err)
	}
	return each(parents, r.post_node(post)!)
}

// mutation_replace_post resolves `Mutation.replacePost`: `replacePost(slug: String!, input: PostUpdate!): Post!`.
pub fn (r Resolvers) mutation_replace_post(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	post := r.posts.replace(info.arg('slug').as_string(), post_models.PostUpdate{
		body: text(input(info), 'body')
	}) or { return failed(err) }
	return each(parents, r.post_node(post)!)
}

// mutation_update_post resolves `Mutation.updatePost`: `updatePost(slug: String!, input: PostPatch!): Post!`.
pub fn (r Resolvers) mutation_update_post(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	post := r.posts.patch(info.arg('slug').as_string(), post_models.PostPatch{
		body: maybe(input(info), 'body')
	}) or { return failed(err) }
	return each(parents, r.post_node(post)!)
}

// mutation_delete_post resolves `Mutation.deletePost`: `deletePost(slug: String!): Boolean!`.
pub fn (r Resolvers) mutation_delete_post(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	r.posts.soft_delete(info.arg('slug').as_string()) or { return failed(err) }
	return each(parents, graphql.Value(true))
}

// mutation_create_post_comment resolves `Mutation.createPostComment`: `createPostComment(slug: String!, input: OwnedCommentInput!): Comment!`.
pub fn (r Resolvers) mutation_create_post_comment(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	comment := r.create_comment_on(comment_models.owner_type[post_models.Post](), info.arg('slug').as_string(),
		owned_comment(input(info))) or { return failed(err) }
	return each(parents, r.comment_node(comment)!)
}

// mutation_create_comment resolves `Mutation.createComment`: `createComment(input: CommentInput!): Comment!`.
pub fn (r Resolvers) mutation_create_comment(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	m := input(info)
	comment := r.create_comment(comment_models.CommentInput{
		user_slug:   text(m, 'userSlug')
		owner_type:  text(m, 'ownerType')
		owner_slug:  text(m, 'ownerSlug')
		parent_slug: text(m, 'parentSlug')
		body:        text(m, 'body')
	}) or { return failed(err) }
	return each(parents, r.comment_node(comment)!)
}

// mutation_replace_comment resolves `Mutation.replaceComment`: `replaceComment(slug: String!, input: CommentUpdate!): Comment!`.
pub fn (r Resolvers) mutation_replace_comment(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	comment := r.comments.replace(info.arg('slug').as_string(), comment_models.CommentUpdate{
		body: text(input(info), 'body')
	}) or { return failed(err) }
	return each(parents, r.comment_node(comment)!)
}

// mutation_update_comment resolves `Mutation.updateComment`: `updateComment(slug: String!, input: CommentPatch!): Comment!`.
pub fn (r Resolvers) mutation_update_comment(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	comment := r.comments.patch(info.arg('slug').as_string(), comment_models.CommentPatch{
		body: maybe(input(info), 'body')
	}) or { return failed(err) }
	return each(parents, r.comment_node(comment)!)
}

// mutation_delete_comment resolves `Mutation.deleteComment`: `deleteComment(slug: String!): Boolean!`.
pub fn (r Resolvers) mutation_delete_comment(_ graphql.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	r.comments.soft_delete(info.arg('slug').as_string()) or { return failed(err) }
	return each(parents, graphql.Value(true))
}
