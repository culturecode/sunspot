module Sunspot
  #
  # The fields of one association's children across the NestedSetups of the
  # classes in a multi-class search. A field resolves when every setup that
  # declares it agrees on its Solr field name and type, as with CompositeSetup,
  # and raises UnrecognizedFieldError when none declares it or they declare it
  # differently.
  #
  class CompositeNestedSetup #:nodoc:
    def initialize(nested_setups)
      @nested_setups = nested_setups
    end

    def field(field_name)
      fields = @nested_setups.map do |setup|
        begin
          setup.field(field_name)
        rescue UnrecognizedFieldError
          nil
        end
      end.compact.uniq { |field| [field.indexed_name, field.type.class] }
      return fields.first if fields.one?

      raise(
        UnrecognizedFieldError,
        fields.empty? ? "No field configured for #{paths} with name '#{field_name}'" :
          "Field '#{field_name}' is configured differently for #{paths}"
      )
    end

    # Returns the text fields with the given name, one per distinct Solr field.
    # Raises UnrecognizedFieldError when no setup declares it. TextFieldSetup
    # raises when there is more than one.
    def text_fields(field_name)
      fields = @nested_setups.flat_map do |setup|
        begin
          setup.text_fields(field_name)
        rescue UnrecognizedFieldError
          []
        end
      end.uniq(&:indexed_name)
      return fields if fields.any?

      raise UnrecognizedFieldError, "No text field configured for #{paths} with name '#{field_name}'"
    end

    def type_names
      @nested_setups.map(&:path).uniq
    end

    # Returns the dynamic field factory with the given base name. Unlike
    # #field, it requires every setup to declare it, as CompositeSetup does
    # for parents' dynamic fields. Raises UnrecognizedFieldError when one
    # doesn't, or when they build different Solr fields.
    def dynamic_field_factory(field_name)
      factories = @nested_setups.map { |setup| setup.dynamic_field_factory(field_name) }
      return factories.first if factories.map { |factory| factory.build('x').indexed_name }.uniq.one?

      raise UnrecognizedFieldError, "Dynamic field '#{field_name}' is configured differently for #{paths}"
    end

    def nested_setups_named(name)
      raise UnrecognizedFieldError, "No nested association configured for #{paths} with name '#{name}'"
    end

    alias_method :nested_setup, :nested_setups_named

    private

    def paths
      type_names * ', '
    end
  end
end
