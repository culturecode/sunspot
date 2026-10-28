module Sunspot
  module Search
    #
    # The rows of a Query::ChildFieldJsonFacet, read by its name. Each row's
    # count is a number of parents, and the rows come in Solr's order: by that
    # count, unless the facet was sorted by :index.
    #
    class ChildFieldJsonFacet < FieldJsonFacet
      def initialize(field, search, options)
        super
        @name = (options[:name] || field.name).to_sym
      end

      def rows
        @rows ||= begin
          data = no_data? ? [] : @search.json_facet_response[@name.to_s]['buckets']
          rows = data.map {|bucket| JsonFacetRow.new(bucket, self) }
          rows = rows.select {|row| row.count >= @options[:minimum_count] } if @options[:minimum_count]
          rows
        end
      end

      def no_data?
        @search.json_facet_response[@name.to_s].nil?
      end
    end
  end
end
