module Sunspot
  module Query
    #
    # A terms facet over the children of the matching documents: the children
    # in one nested association that satisfy a block join's restrictions. Each
    # row counts the documents with such a child, not the children.
    #
    # With +:matches+, only children whose value of the field matches it are
    # counted. It is a Lucene regular expression, matched against the whole
    # indexed value.
    #
    class ChildFieldJsonFacet < FieldJsonFacet
      def initialize(field, options, setup, block_join)
        super(field, options, setup)
        @block_join = block_join
      end

      def field_name_with_local_params
        params = super
        filters = [@block_join.child_query]
        filters << "#{@field.indexed_name}:/#{@options[:matches].gsub('/', '\\/')}/" if @options[:matches]

        params[@field.name].merge!(
          :domain => { :blockChildren => BlockJoin::ROOTS, :filter => filters },
          # JsonFacetRow counts a row by its distinct sub-facet when it has one
          :facet => { :distinct => 'uniqueBlock(_root_)' }
        )
        params
      end
    end
  end
end
