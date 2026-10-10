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
      # condition on NestedSetup::PATH_FIELD, and every restriction added to it
      # is ANDed with that condition. The child query therefore matches only
      # this association's children, and a negated restriction can't match a
      # parent or a child of another association.
      attr_reader :scope

      def initialize(nested_setup, negated = false, scope = nil, paths = [nested_setup.path])
        @nested_setup, @negated, @paths = nested_setup, negated, paths
        @scope = scope || Connective::Conjunction.new.tap { |conjunction| conjunction.add_component(PathRestriction.new(paths)) }
      end

      # Escapes twice: the local param values, then the whole +_query_+ phrase.
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

      def child_query
        @scope.to_boolean_phrase
      end

      def escape(value)
        self.class.escape(value)
      end

      # Backslash-escapes quotes and backslashes for a quoted Solr string:
      # <tt>say "hi"</tt> becomes <tt>say \"hi\"</tt>.
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
