module Sunspot
  module Query
    # 
    # The classes in this module implement query components that build sort
    # parameters for Solr. As well as regular sort on fields, there are several
    # "special" sorts that allow ordering for metrics calculated during the
    # search.
    # 
    module Sort #:nodoc: all
      DIRECTIONS = {
        :asc => 'asc',
        :ascending => 'asc',
        :desc => 'desc',
        :descending => 'desc'
      }

      class <<self
        # 
        # Certain field names are "special", referring to specific non-field
        # sorts, which are generally by other metrics associated with hits.
        #
        # XXX I'm not entirely convinced it's a good idea to prevent anyone from
        # ever sorting by a field named 'score', etc.
        #
        def special(name)
          special_class_name = "#{Util.camel_case(name.to_s)}Sort"
          if const_defined?(special_class_name) && special_class_name != 'FieldSort'
            const_get(special_class_name)
          end
        end
      end

      # 
      # Base class for sorts. All subclasses should implement the #to_param
      # method, which is a string that is then concatenated with other sort
      # strings by the SortComposite to form the sort parameter.
      #
      class Abstract
        def initialize(direction)
          @direction = (direction || :asc).to_sym
        end

        private

        # 
        # Translate fairly forgiving direction argument into solr direction
        #
        def direction_for_solr
          DIRECTIONS[@direction] || 
            raise(
              ArgumentError,
              "Unknown sort direction #{@direction}. Acceptable input is: #{DIRECTIONS.keys.map { |input| input.inspect } * ', '}"
          )
        end
      end

      # 
      # A FieldSort is the usual kind of sort, by the value of a particular
      # field, ascending or descending
      #
      class FieldSort < Abstract
        def initialize(field, direction = nil)
          if field.multiple?
            raise(ArgumentError, "#{field.name} cannot be used for ordering because it is a multiple-value field")
          end
          @field, @direction = field, (direction || :asc).to_sym
        end

        def to_param
          "#{@field.indexed_name.to_sym} #{direction_for_solr}"
        end
      end

      # 
      # A RandomSort uses Solr's random field functionality to sort results
      # (usually) randomly.
      #
      class RandomSort < Abstract
        def initialize(options_or_direction=nil)
          if options_or_direction.is_a?(Hash)
            @seed, @direction = options_or_direction[:seed], options_or_direction[:direction]
					else
            @direction = options_or_direction
          end

          @direction = (@direction || :asc).to_sym
        end

        def to_param
          "random_#{@seed || rand(1<<6)} #{direction_for_solr}"
        end
      end

      # 
      # A ScoreSort sorts by keyword relevance score. This is only useful when
      # performing fulltext search.
      #
      class ScoreSort < Abstract
        def to_param
          "score #{direction_for_solr}"
        end
      end

      #
      # A GeodistSort sorts by distance from a given point.
      #
      class GeodistSort < FieldSort
        def initialize(field, lat, lon, direction)
          @lat, @lon = lat, lon
          super(field, direction)
        end

        def to_param
          "geodist(#{@field.indexed_name.to_sym},#{@lat},#{@lon}) #{direction_for_solr}"
        end
      end

      #
      # A ChildSort sorts parents by a field of their children in a nested
      # association, among the children matching its block join's scope that
      # have a value for the field. The sort is by a block join query whose
      # score is those children's field values, combined by +:score+. A parent
      # with no such child doesn't match that query, and sorts after those that
      # do.
      #
      # The query takes its parts from parameters of its own, named by
      # SortComposite, which keeps each part's escaping to one level. Solr
      # compares scores as floats, so two times less than about two minutes
      # apart, or integers above 2**24, may tie.
      #
      class ChildSort < Abstract
        SCORES = [:min, :max, :avg, :total]

        def initialize(block_join, field, direction = nil, options = {})
          super(direction)
          if field.multiple?
            raise(ArgumentError, "#{field.name} cannot be used for ordering because it is a multiple-value field")
          end
          if field.type.is_a?(Type::DateRangeType) || !(field.type.is_a?(Type::TimeType) || field.type.is_a?(Type::IntegerType) || field.type.is_a?(Type::FloatType))
            raise(ArgumentError, "#{field.name} cannot be used for ordering children because it is not a numeric or time field")
          end
          @block_join, @field = block_join, field
          @score = (options[:score] || (direction_for_solr == 'asc' ? :min : :max)).to_sym
          unless SCORES.include?(@score)
            raise(ArgumentError, "Unknown score #{@score.inspect}. Acceptable input is: #{SCORES.map(&:inspect) * ', '}")
          end
        end

        def to_param(name = 'child_sort')
          "exists(query($#{name})) desc, query($#{name}) #{direction_for_solr}"
        end

        # The parameters #to_param refers to, by the same +name+
        def params(name)
          {
            :"#{name}" => %Q({!parent which="#{BlockJoin.escape(BlockJoin::ROOTS)}" score=#{@score} v=$#{name}_child}),
            :"#{name}_child" => "{!bool filter=$#{name}_filter filter=$#{name}_present must=$#{name}_value}",
            :"#{name}_filter" => @block_join.scope.to_boolean_phrase,
            :"#{name}_present" => "#{@field.indexed_name}:[* TO *]",
            :"#{name}_value" => "{!func}#{value_function}"
          }
        end

        private

        def value_function
          if @field.type.is_a?(Type::TimeType)
            "ms(#{@field.indexed_name})"
          else
            "field(#{@field.indexed_name})"
          end
        end
      end

      class SolrIdSort < Abstract
        def to_param
          "id #{direction_for_solr}"
        end
      end

      #
      # A FunctionSort sorts by solr function.
      # FunctionComp recursively parses arguments for nesting
      #
      class FunctionSort < Abstract
        attr_reader :comp
        def initialize(setup,args)
          @direction = args.pop
          @comp = FunctionComp.new(setup,args)
        end
        def to_param
          "#{comp.to_s} #{direction_for_solr}"
        end
      end
      class FunctionComp
        attr_accessor :function,:fields
        def initialize(setup,args)
          @function=args.shift
          @fields = []
          args.each do |argument|
            case argument.class.name
            when "Array"
              @fields<< FunctionComp.new(setup,argument)
            when "Symbol"
              @fields<< setup.field(argument).indexed_name
            else
              @fields<< argument
            end
          end
        end
        def to_s
          "#{function}(#{fields.map(&:to_s).join(",")})"
        end
      end
    end
  end
end
