module Sunspot
  module Query
    #
    # A restriction matching parents with at least one child in a nested
    # association that satisfies every restriction in #scope. Negated, it
    # matches parents with no such child.
    #
    # Renders as a Solr block join embedded with +_query_+, so it can sit in a
    # filter query, a connective, a query facet row or a delete-by-query like
    # any other restriction.
    #
    class BlockJoin #:nodoc:
      include Filter

      # ROOTS is Solr's block mask: every document without
      # NestedSetup::PATH_FIELD, whatever its class. A document of another class
      # indexed between blocks is therefore a root to Solr, never a child.
      ROOTS = "*:* -#{NestedSetup::PATH_FIELD}:[* TO *]".freeze

      # The restrictions a child must satisfy. Its first component is the
      # condition on NestedSetup::PATH_FIELD, so every restriction added to it,
      # negated ones included, is joined to that condition.
      attr_reader :scope

      def initialize(nested_setup, negated = false, scope = nil, paths = [nested_setup.path])
        @nested_setup, @negated, @paths = nested_setup, negated, paths
        @scope = scope || Connective::Conjunction.new.tap { |conjunction| conjunction.add_component(PathRestriction.new(paths)) }
      end

      def to_boolean_phrase
        phrase = %Q(_query_:"#{escape(%Q({!parent which="#{escape(ROOTS)}" v="#{escape(child_query)}"}))}")
        negated? ? "-#{phrase}" : phrase
      end

      def negated?
        @negated
      end

      def negate
        self.class.new(@nested_setup, !negated?, @scope, @paths)
      end

      private

      #
      # Returns the query for this association's children: #scope, whose first
      # component requires NestedSetup::PATH_FIELD to match the association.
      # Solr joins every document the child query matches to the next parent
      # in the index, including documents of other classes and children of
      # other associations, so that condition is always required.
      #
      def child_query
        @scope.to_boolean_phrase
      end

      def escape(value)
        self.class.escape(value)
      end

      # Backslash-escapes quotes and backslashes for a quoted Solr string.
      # #to_boolean_phrase applies it at both levels of nesting: to the local
      # param values, then to the whole +_query_+ phrase.
      def self.escape(value)
        value.gsub(/(["\\])/, '\\\\\1')
      end

      # The condition matching the children of a nested association, on any
      # of the given PATH_FIELD values.
      class PathRestriction #:nodoc:
        def initialize(paths)
          @paths = paths
        end

        def to_boolean_phrase
          phrases = @paths.map { |path| %Q(#{NestedSetup::PATH_FIELD}:"#{BlockJoin.escape(path)}") }
          phrases.one? ? phrases.first : "(#{phrases.join(' OR ')})"
        end

        def negated?
          false
        end
      end
    end
  end
end
