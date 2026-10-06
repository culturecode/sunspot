module Sunspot
  #
  # The fields of one association's children across several NestedSetups:
  # one per searched class, and one per subclass that declares the association
  # again. A field resolves when every setup that declares it agrees on its
  # Solr field, as with CompositeSetup, and raises UnrecognizedFieldError when
  # none declares it or they declare it differently.
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
      end.compact.uniq(&:indexed_name)
      return fields.first if fields.one?

      raise(
        UnrecognizedFieldError,
        fields.empty? ? "No field configured for #{paths} with name '#{field_name}'" :
          "Field '#{field_name}' is configured differently for #{paths}"
      )
    end

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
      @nested_setups.map(&:path).uniq * ', '
    end
  end
end
