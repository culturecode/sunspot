require 'sunspot/batcher'

module Sunspot
  # 
  # This class presents a service for adding, updating, and removing data
  # from the Solr index. An Indexer instance is associated with a particular
  # setup, and thus is capable of indexing instances of a certain class (and its
  # subclasses).
  #
  class Indexer #:nodoc:

    def initialize(connection)
      @connection = connection
    end

    # 
    # Construct a representation of the model for indexing and send it to the
    # connection for indexing
    #
    # ==== Parameters
    #
    # model<Object>:: the model to index
    #
    def add(model)
      models = Util.Array(model)
      documents = models.map { |m| prepare_full_update(m) }
      remove_replaced_blocks(models, documents)
      add_batch_documents(documents)
    end

    #
    # Construct a representation of the given class instances for atomic properties update
    # and send it to the connection for indexing
    #
    # ==== Parameters
    #
    # clazz<Class>:: the class of the models to be updated
    # updates<Hash>:: hash of updates where keys are model ids
    #                 and values are hash with property name/values to be updated
    #
    def add_atomic_update(clazz, updates={})
      documents = updates.map { |id, m| prepare_atomic_update(clazz, id, m) }
      add_batch_documents(documents)
    end

    # 
    # Remove the given model from the Solr index
    #
    def remove(*models)
      ids = models.map { |model| Adapters::InstanceAdapter.adapt(model).index_id }
      @connection.delete_by_id(ids)
      remove_blocks(ids.select.with_index { |_, i| nested?(models[i].class) })
    end

    # 
    # Remove the model from the Solr index by specifying the class and ID
    #
    def remove_by_id(class_name, *ids)
      if class_name.is_a?(String) and class_name.index("!")
        partition  = class_name.rpartition("!")
        id_prefix  = partition[0..1].join
        class_name = partition[2]
      else
        clazz_setup = setup_for_class(Util.full_const_get(class_name))
        id_prefix = if clazz_setup.id_prefix_defined?
                      if clazz_setup.id_prefix_requires_instance?
                        warn(Sunspot::RemoveByIdNotSupportCompositeIdMessage.call(class_name))
                      else
                        clazz_setup.id_prefix_for_class
                      end
                    end
      end

      ids.flatten!
      index_ids = ids.map { |id| Adapters::InstanceAdapter.index_id_for("#{id_prefix}#{class_name}", id) }
      @connection.delete_by_id(index_ids)
      remove_blocks(index_ids) if nested_class_name?(class_name)
    end

    #
    # Delete all documents of the class indexed by this indexer from Solr.
    #
    def remove_all(clazz = nil)
      if clazz
        @connection.delete_by_query(with_children("type:#{Util.escape(clazz.name)}", [clazz]))
      else
        @connection.delete_by_query("*:*")
      end
    end

    # 
    # Remove all documents that match the scope given in the Query
    #
    def remove_by_scope(scope, types = [])
      @connection.delete_by_query(with_children(scope.to_boolean_phrase, types))
    end

    # 
    # Start batch processing
    #
    def start_batch
      batcher.start_new
    end

    #
    # Write batch out to Solr and clear it
    #
    def flush_batch
      add_documents(batcher.end_current)
    end

    private

    def batcher
      @batcher ||= Batcher.new
    end

    # 
    # Convert documents into hash of indexed properties
    #
    def prepare_full_update(model)
      document = document_for_full_update(model)
      setup = setup_for_object(model)
      if boost = setup.document_boost_for(model)
        document.attrs[:boost] = boost
      end
      setup.all_field_factories.each do |field_factory|
        field_factory.populate_document(document, model)
      end
      setup.nested_setups.each do |nested_setup|
        add_child_documents(document, nested_setup, model)
      end
      document
    end

    #
    # Adds a child document to +document+ for each of the model's children in
    # the association, so Solr indexes the parent and its children as one
    # block. Raises NestedDocumentsNotSupportedError when there are children
    # and RSolr cannot send child documents.
    #
    # A child's id is the parent's id followed by the association name and
    # #child_key, so it is unique within the index and carries the parent's
    # id prefix.
    #
    def add_child_documents(document, nested_setup, model)
      children = nested_setup.children_for(model)
      return if children.empty?
      ensure_child_documents_supported!

      parent_id = document.field_by_name(:id).value
      children.each_with_index do |child, position|
        child_document = RSolr::Xml::Document.new(
          id: "#{parent_id}/#{nested_setup.name}/#{child_key(child, position)}",
          NestedSetup::PATH_FIELD.to_sym => nested_setup.path
        )
        nested_setup.all_field_factories.each do |field_factory|
          field_factory.populate_document(child_document, child)
        end
        document.add_field(RSolr::Document::CHILD_DOCUMENT_KEY, child_document)
      end
    end

    # Returns the child's index id when it has an adapter, so a child document
    # can be traced back to its record. Returns its position in the
    # association otherwise.
    def child_key(child, position)
      Adapters::InstanceAdapter.adapt(child).index_id
    rescue NoAdapterError
      position
    end

    def ensure_child_documents_supported!
      return if defined?(RSolr::Document::CHILD_DOCUMENT_KEY)
      raise NestedDocumentsNotSupportedError, "Nested documents require an RSolr version that defines RSolr::Document::CHILD_DOCUMENT_KEY"
    end

    def nested?(clazz)
      setup = Setup.for(clazz)
      !setup.nil? && setup.nested_setups.any?
    end

    # Returns true when the named class has nested associations, or when it
    # no longer exists and any class does, since its documents may have
    # children.
    def nested_class_name?(class_name)
      nested?(Util.full_const_get(class_name))
    rescue NameError
      Setup.nested_anywhere?
    end

    #
    # Deletes the blocks the given models' documents replace. Solr before 8
    # replaces a document with children by +_root_+ and one without by +id+,
    # so reindexing a parent whose children went from some to none, or from
    # none to some, would leave the old children or the old parent behind.
    # Deleting a parent with children by id, and one without by +_root_+,
    # clears either case.
    #
    def remove_replaced_blocks(models, documents)
      with_children, without_children = [], []
      models.each_with_index do |model, i|
        next unless nested?(model.class)
        id = documents[i].field_by_name(:id).value
        (child_documents?(documents[i]) ? with_children : without_children) << id
      end
      @connection.delete_by_id(with_children) if with_children.any?
      remove_blocks(without_children)
    end

    def child_documents?(document)
      defined?(RSolr::Document::CHILD_DOCUMENT_KEY) && document.fields_by_name(RSolr::Document::CHILD_DOCUMENT_KEY).any?
    end

    #
    # Deletes every document in the blocks rooted at the given ids. Solr 9
    # deletes a parent's children along with it on a delete by id, and Solr 6
    # leaves them in the index. A child left behind is joined to whichever
    # parent follows it in the index.
    #
    def remove_blocks(ids)
      return if ids.empty?
      @connection.delete_by_query("_root_:(#{ids.map { |id| %Q("#{Util.escape(id)}") }.join(' OR ')})")
    end

    #
    # Returns a query matching the documents +query+ matches and, when one of
    # +classes+ or a subclass of one has nested associations, their children
    # too. Solr evaluates it once, so a delete by it removes the parents and
    # children together, and a parent condition that refers to children still
    # matches the parents. The block mask is every document that is not a
    # child, so documents of other classes indexed between blocks are never
    # matched as children.
    #
    def with_children(query, classes)
      return query unless Setup.nested_under?(classes)
      escape = Query::BlockJoin.method(:escape)
      children = %Q({!child of="#{escape.(Query::BlockJoin::ROOTS)}" v="#{escape.(query)}"})
      %Q((#{query}) OR _query_:"#{escape.(children)}")
    end

    def prepare_atomic_update(clazz, id, updates = {})
      if nested?(clazz)
        raise ArgumentError, "Atomic updates are not supported for #{clazz.name}, which has nested documents. " \
          "Index the whole record instead, which reindexes its children with it"
      end
      document = document_for_atomic_update(clazz, id)
      setup_for_class(clazz).all_field_factories.each do |field_factory|
        if updates.has_key?(field_factory.name)
          field_factory.populate_document(document, nil, value: updates[field_factory.name], update: :set)
        end
      end
      document
    end

    def add_documents(documents)
      @connection.add(documents)
    end

    def add_batch_documents(documents)
      if batcher.batching?
        batcher.concat(documents)
      else
        add_documents(documents)
      end
    end

    # 
    # All indexed documents index and store the +id+ and +type+ fields.
    # These methods construct the document hash containing those key-value
    # pairs.
    #
    def document_for_full_update(model)
      RSolr::Xml::Document.new(
        id: Adapters::InstanceAdapter.adapt(model).index_id,
        type: Util.superclasses_for(model.class).map(&:name)
      )
    end

    def document_for_atomic_update(clazz, key)
      return unless Adapters::InstanceAdapter.for(clazz)

      clazz_setup = setup_for_class(clazz)
      id_prefix = if clazz_setup.id_prefix_defined?
                    if clazz_setup.id_prefix_requires_instance?
                      if key.respond_to?(:id)
                        clazz_setup.id_prefix_for(key)
                      else
                        warn(Sunspot::AtomicUpdateRequireInstanceForCompositeIdMessage.call(clazz.name))
                      end
                    else
                      clazz_setup.id_prefix_for_class
                    end
                  end

      instance_id = key.respond_to?(:id) ? key.id : key
      RSolr::Xml::Document.new(
        id: Adapters::InstanceAdapter.index_id_for("#{id_prefix}#{clazz.name}", instance_id),
        type: Util.superclasses_for(clazz).map(&:name)
      )
    end
    # 
    # Get the Setup object for the given object's class.
    #
    # ==== Parameters
    #
    # object<Object>:: The object whose setup is to be retrieved
    #
    # ==== Returns
    #
    # Sunspot::Setup:: The setup for the object's class
    #
    def setup_for_object(object)
      setup_for_class(object.class)
    end

    #
    # Get the Setup object for the given class.
    #
    # ==== Parameters
    #
    # clazz<Class>:: The class whose setup is to be retrieved
    #
    # ==== Returns
    #
    # Sunspot::Setup:: The setup for the class
    #
    def setup_for_class(clazz)
      Setup.for(clazz) || raise(NoSetupError, "Sunspot is not configured for #{clazz.inspect}")
    end
  end
end
