module Sunspot
  module Query
    # 
    # The SortComposite class encapsulates an ordered collection of Sort
    # objects. It's necessary to keep this as a separate class as Solr takes
    # the sort as a single parameter, so adding sorts as regular components
    # would not merge correctly in the #to_params method.
    #
    class SortComposite #:nodoc:
      def initialize
        @sorts = []
      end

      # 
      # Add a sort to the composite
      #
      def <<(sort)
        @sorts << sort
      end

      #
      # Check sort presence
      #
      def include?(sort)
        @sorts.any? { |s| s.to_param.include?(sort) }
      end

      #
      # Combine the sorts into a single param by joining them. A sort with
      # parameters of its own, such as a Sort::ChildSort, has them named by
      # its position, so two of them can't collide.
      #
      def to_params(prefix = "")
        unless @sorts.empty?
          key = "#{prefix}sort".to_sym
          params = {}
          clauses = @sorts.each_with_index.map do |sort, index|
            if sort.respond_to?(:params)
              name = "child_sort_#{index}"
              params.merge!(sort.params(name))
              sort.to_param(name)
            else
              sort.to_param
            end
          end
          params.merge(key => clauses * ', ')
        else
          {}
        end
      end
    end
  end
end
