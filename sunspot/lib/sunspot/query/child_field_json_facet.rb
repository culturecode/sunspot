module Sunspot
  module Query
    #
    # A terms facet over the children of the matching documents: the children
    # in one nested association that satisfy a block join's restrictions. Each
    # row counts the documents with such a child, not the children, and the
    # rows are ranked by that count.
    #
    # With +:matches+, only children whose value of the field matches it are
    # counted. It is a Lucene regular expression, matched against the whole
    # indexed value, case-sensitively. Util.escape_lucene_regexp escapes text
    # to match literally.
    #
    class ChildFieldJsonFacet < FieldJsonFacet
      OPTIONS = [:name, :limit, :offset, :sort, :sort_type, :minimum_count, :prefix, :missing, :all_buckets, :matches].freeze

      # The count each row reports: the number of parents with such a child
      PARENT_COUNT = 'distinct'.freeze

      attr_reader :name

      def initialize(field, options, setup, block_join)
        unknown = options.keys - OPTIONS
        raise ArgumentError, "child_facet doesn't take #{unknown.map(&:inspect).join(', ')}" if unknown.any?
        unless field.type.is_a?(Sunspot::Type::StringType) || !options.key?(:matches)
          raise ArgumentError, "child_facet's :matches needs a string field, but #{field.name} isn't one"
        end
        raise ArgumentError, "child_facet's :matches takes a Lucene regular expression as a String" if options.key?(:matches) && !options[:matches].is_a?(String)

        super(field, options, setup)
        @block_join = block_join
        @name = (options[:name] || field.name).to_sym
      end

      def field_name_with_local_params
        params = init_params.merge(:type => 'terms', :field => @field.indexed_name)
        # Solr ranks buckets by its own count, the children, unless told to use the parent count
        params[:sort] = { PARENT_COUNT => @options[:sort_type] || 'desc' } if @options[:sort].nil? || @options[:sort] == :count
        params.delete(:mincount) # Solr's mincount counts children; rows apply :minimum_count to parents

        filters = [@block_join.child_query]
        filters << "#{@field.indexed_name}:/#{@options[:matches].gsub('/', '\\/')}/" if @options[:matches]

        { @name => params.merge(
          :domain => { :blockChildren => BlockJoin::ROOTS, :filter => filters },
          :facet => { PARENT_COUNT => 'uniqueBlock(_root_)' }
        ) }
      end

      def get_params
        field_name_with_local_params
      end
    end
  end
end
