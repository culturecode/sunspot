module Sunspot
  #
  # The field setup for the children of one association declared with
  # DSL::Fields#nested. Children are indexed only as part of their parent's
  # block, so a nested setup has fields but no class of its own. Child
  # documents carry no +type+ or +class_name+ field. PATH_FIELD names their
  # association instead.
  #
  class NestedSetup < Setup #:nodoc:
    # PATH_FIELD marks each child document with the association it belongs
    # to. A document without it is the root of a block. Child queries are
    # scoped on it, which keeps children of other associations and documents
    # of other classes out of the block join.
    PATH_FIELD = '_sunspot_nested_path_s'.freeze

    attr_reader :name, :parent_setup

    def initialize(parent_setup, name, options = {}, path = nil)
      @parent_setup = parent_setup
      @name = name.to_sym
      @class_name = "#{parent_setup.type_names.first}.#{@name}"
      @path = path || @class_name
      @field_factories, @text_field_factories, @dynamic_field_factories,
        @field_factories_cache, @text_field_factories_cache,
        @dynamic_field_factories_cache = *Array.new(6) { Hash.new }
      @stored_field_factories_cache = Hash.new { |h, k| h[k] = [] }
      @more_like_this_field_factories_cache = Hash.new { |h, k| h[k] = [] }
      @nested_setups = {}
      @dsl = DSL::NestedFields.new(self)
      @children_extractor = DataExtractor::AttributeExtractor.new(options[:using] || @name)
    end

    #
    # Returns the value stored in PATH_FIELD on every child of this
    # association: the declaring class and the association name, such as
    # "Project.milestones".
    #
    def path
      @path
    end

    # Returns the model's children, each once, so an association that lists a
    # record twice doesn't give two child documents the same id.
    def children_for(model)
      Util.Array(@children_extractor.value_for(model)).compact.uniq
    end

    def clazz
      raise NotImplementedError, "Nested association #{path} has no class of its own"
    end

    protected

    def parent
      nil
    end
  end
end
