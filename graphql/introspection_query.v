module graphql

// introspection_query is the full introspection query, as graphql-js's
// `getIntrospectionQuery` writes it with every option on: descriptions, the
// specifiedBy URL, repeatable directives, the schema's description, deprecated
// input values, and oneOf. GraphiQL and Apollo's tools ask a server this to
// learn its schema.
pub const introspection_query = '
    query IntrospectionQuery {
      __schema {
        description
        queryType { name kind }
        mutationType { name kind }
        subscriptionType { name kind }
        types {
          ...FullType
        }
        directives {
          name
          description
          isRepeatable
          
          
          locations
          args(includeDeprecated: true) {
            ...InputValue
          }
        }
      }
    }

    fragment FullType on __Type {
      kind
      name
      description
      specifiedByURL
      isOneOf
      fields(includeDeprecated: true) {
        name
        description
        args(includeDeprecated: true) {
          ...InputValue
        }
        type {
          ...TypeRef
        }
        isDeprecated
        deprecationReason
      }
      inputFields(includeDeprecated: true) {
        ...InputValue
      }
      interfaces {
        ...TypeRef
      }
      enumValues(includeDeprecated: true) {
        name
        description
        isDeprecated
        deprecationReason
      }
      possibleTypes {
        ...TypeRef
      }
    }

    fragment InputValue on __InputValue {
      name
      description
      type { ...TypeRef }
      defaultValue
      isDeprecated
      deprecationReason
    }

    fragment TypeRef on __Type {
      kind
      name
      ofType {
        name
        kind
        ofType {
          name
          kind
          ofType {
            name
            kind
            ofType {
              name
              kind
              ofType {
                name
                kind
                ofType {
                  name
                  kind
                  ofType {
                    name
                    kind
                    ofType {
                      name
                      kind
                      ofType {
                        name
                        kind
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  '
