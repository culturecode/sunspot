require File.expand_path('spec_helper', File.dirname(__FILE__))

# RSolr 1.x has no RSolr::Document, so it can't send child documents
child_documents = defined?(RSolr::Document::CHILD_DOCUMENT_KEY)

describe 'nested documents' do
  let(:connection) { Mock::Connection.new }
  let(:session) { Sunspot::Session.new(Sunspot::Configuration.build, connection) }
  let(:roots) { '*:* -_sunspot_nested_path_s:[* TO *]' }

  def last_fq
    connection.searches.last[:fq]
  end

  describe 'setup' do
    it 'resolves child fields against the association, not the parent' do
      nested_setup = Sunspot::Setup.for(Project).nested_setup(:milestones)
      expect(nested_setup.field(:started_at).indexed_name).to eq('started_at_d')
      expect { nested_setup.field(:status) }.to raise_error(Sunspot::UnrecognizedFieldError)
    end

    it "keeps each association's fields separate" do
      setup = Sunspot::Setup.for(Project)
      expect(setup.nested_setups.map(&:name)).to eq([:milestones, :reviews])
      expect { setup.nested_setup(:milestones).field(:verdict) }.to raise_error(Sunspot::UnrecognizedFieldError)
    end

    it 'names each association by its declaring class' do
      expect(Sunspot::Setup.for(Project).nested_setup(:milestones).path).to eq('Project.milestones')
    end

    it 'raises for an association that was never declared' do
      expect { Sunspot::Setup.for(Project).nested_setup(:tasks) }.to raise_error(Sunspot::UnrecognizedFieldError)
    end

    it 'rejects boosts, nested associations and joins in a nested block' do
      expect { Sunspot::Setup.for(Project).add_nested(:x) { boost 2 } }.to raise_error(ArgumentError)
      expect { Sunspot::Setup.for(Project).add_nested(:x) { nested(:y) {} } }.to raise_error(ArgumentError)
      expect { Sunspot::Setup.for(Project).add_nested(:x) { join(:y, :target => Post, :type => :string, :join => { :from => :a, :to => :b }) } }.to raise_error(ArgumentError)
    end
  end

  describe 'indexing', :if => child_documents do
    let(:milestone) { Milestone.new(:name => 'design', :started_at => Time.utc(2026, 2, 1), :owner_names => %w(ana ben)) }
    let(:project) { Project.new(:name => 'Bridge', :milestones => [milestone], :reviews => [OpenStruct.new(:verdict => 'approved')]) }

    def indexed_project
      session.index(project)
      connection.adds.last.first
    end

    def children(document)
      document.fields_by_name(RSolr::Document::CHILD_DOCUMENT_KEY).map(&:value)
    end

    it 'sends children inside the parent document' do
      expect(children(indexed_project).length).to eq(2)
    end

    it 'gives each child an id derived from its parent, and its own index id when it has an adapter' do
      milestone_doc = children(indexed_project).first
      expect(milestone_doc.field_by_name(:id).value).to eq("Project #{project.id}/milestones/Milestone #{milestone.id}")
    end

    it 'falls back to the position in the association for children without an adapter' do
      review_doc = children(indexed_project).last
      expect(review_doc.field_by_name(:id).value).to eq("Project #{project.id}/reviews/0")
    end

    it 'marks each child with its association and gives it no type of its own' do
      milestone_doc = children(indexed_project).first
      expect(milestone_doc.field_by_name(:_sunspot_nested_path_s).value).to eq('Project.milestones')
      expect(milestone_doc.field_by_name(:type)).to be_nil
      expect(milestone_doc.field_by_name(:class_name)).to be_nil
    end

    it 'indexes the child fields, evaluating blocks against the child' do
      milestone_doc = children(indexed_project).first
      expect(milestone_doc.field_by_name(:name_s).value).to eq('design')
      expect(milestone_doc.field_by_name(:started_at_d).value).to eq('2026-02-01T00:00:00Z')
      expect(milestone_doc.fields_by_name(:owner_names_sm).map(&:value)).to eq(%w(ana ben))
      expect(milestone_doc.field_by_name(:days_late_i).value).to eq('0')
    end

    it 'keeps the parent fields on the parent' do
      expect(indexed_project.field_by_name(:name_s).value).to eq('Bridge')
    end

    it 'sends a record the association lists twice as one child' do
      session.index(Project.new(:name => 'Twice', :milestones => [milestone, milestone]))
      expect(children(connection.adds.last.first).length).to eq(1)
    end

    it 'sends no children for an empty association' do
      session.index(Project.new(:name => 'Empty'))
      expect(children(connection.adds.last.first)).to be_empty
    end

  end

  describe 'indexing with an RSolr that has no child documents', :unless => child_documents do
    it 'raises for a parent with children' do
      project = Project.new(:name => 'Bridge', :milestones => [Milestone.new(:name => 'design')])
      expect { session.index(project) }.to raise_error(Sunspot::NestedDocumentsNotSupportedError)
    end

    it 'indexes a parent with no children' do
      session.index(Project.new(:name => 'Empty'))
      expect(connection.adds.last.first.field_by_name(:name_s).value).to eq('Empty')
    end
  end

  describe 'atomic updates' do
    it 'refuses atomic updates to a class with nested associations' do
      expect { session.atomic_update(Project, 1 => { :name => 'x' }) }.to raise_error(ArgumentError, /nested documents/)
    end
  end

  describe 'declaring the same association twice on one class' do
    it 'keeps the fields of both blocks' do
      Object.const_set(:TwiceDeclared, Class.new(MockRecord))
      Sunspot.setup(TwiceDeclared) { nested(:kids) { string :a } }
      Sunspot.setup(TwiceDeclared) { nested(:kids) { string :b } }

      expect(Sunspot::Setup.for(TwiceDeclared).nested_setup(:kids).fields.map(&:name)).to match_array([:a, :b])
    ensure
      Object.send(:remove_const, :TwiceDeclared)
    end
  end

  describe 'a subclass declaring an association again after its setup has been read' do
    it "keeps the subclass's fields off the superclass's children" do
      Object.const_set(:ReadBase, Class.new(MockRecord))
      Object.const_set(:ReadSub, Class.new(ReadBase))
      Sunspot.setup(ReadBase) { nested(:kids) { string :name } }
      Sunspot.setup(ReadSub) { string :title }
      Sunspot::Setup.for(ReadSub).nested_setups # copies the inherited entry into ReadSub's own table
      Sunspot.setup(ReadSub) { nested(:kids) { string :only_sub } }

      expect(Sunspot::Setup.for(ReadBase).nested_setup(:kids).fields.map(&:name)).to eq([:name])
      expect(Sunspot::Setup.for(ReadSub).nested_setup(:kids).fields.map(&:name)).to eq([:only_sub])
    ensure
      Object.send(:remove_const, :ReadSub)
      Object.send(:remove_const, :ReadBase)
    end
  end

  describe 'querying' do
    it 'finds parents by conditions a single child meets together' do
      session.search(Project) do
        with_child :milestones do
          with :name, 'design'
          with(:started_at).greater_than(Time.utc(2026, 1, 1))
        end
      end
      expect(last_fq).to include(
        %q(_query_:"{!parent which=\\"*:* -_sunspot_nested_path_s:[* TO *]\\" v=\\"(_sunspot_nested_path_s:\\\\\\"Project.milestones\\\\\\" AND name_s:design AND started_at_d:{2026\\\\\\\\-01\\\\\\\\-01T00\\\\\\\\:00\\\\\\\\:00Z TO *})\\"}")
      )
    end

    it 'scopes a block with no restrictions to the association alone' do
      session.search(Project) { with_child(:milestones) }
      expect(last_fq.last).to include('v=\\"_sunspot_nested_path_s:\\\\\\"Project.milestones\\\\\\"\\"')
    end

    it 'negates with without_child' do
      session.search(Project) { without_child(:milestones) { with :name, 'launch' } }
      expect(last_fq.last).to start_with('-_query_:"{!parent')
    end

    it 'joins each negated restriction directly to the association condition' do
      session.search(Project) { with_child(:milestones) { without :name, 'launch'; without :name, 'design' } }
      expect(last_fq.last).to include('Project.milestones\\\\\\" AND -name_s:launch AND -name_s:design)')
    end

    it 'rejects an instance restriction inside a child block' do
      milestone = Milestone.new(:name => 'design')
      expect { session.search(Project) { with_child(:milestones) { with(milestone) } } }.to raise_error(ArgumentError, /Instance restrictions/)
      expect { session.search(Project) { with_child(:milestones) { without(milestone) } } }.to raise_error(ArgumentError, /Instance restrictions/)
    end

    it 'works in a query facet row' do
      session.search(Project) do
        facet :designed do
          row(:yes) { with_child(:milestones) { with :name, 'design' } }
        end
      end
      expect(Array(connection.searches.last[:'facet.query'])).to include(a_string_starting_with('_query_:"{!parent'))
    end

    it 'can be excluded from a facet' do
      session.search(Project) do
        designed = with_child(:milestones) { with :name, 'design' }
        facet :status, :exclude => designed
      end
      tag = last_fq.last[/\A\{!tag=([^}]+)\}/, 1]
      expect(tag).not_to be_nil
      expect(last_fq.last).to include('_query_:"{!parent')
      expect(connection.searches.last[:'facet.field']).to include("{!ex=#{tag}}status_s")
    end

    it 'combines with parent restrictions as separate filters' do
      session.search(Project) do
        with :status, 'active'
        with_child(:milestones) { with :name, 'design' }
      end
      expect(last_fq).to include('status_s:active')
      expect(last_fq.last).to start_with('_query_:"{!parent')
    end

    it 'works inside any_of, including negated alternatives' do
      session.search(Project) do
        any_of do
          with_child(:milestones) { with :name, 'design' }
          without_child(:milestones) { with :name, 'launch' }
        end
      end
      expect(last_fq.last).to match(/\A-\(-_query_:"\{!parent .*name_s:design.* AND _query_:"\{!parent .*name_s:launch.*\)\z/)
    end

    it 'supports connectives inside the block' do
      session.search(Project) do
        with_child :milestones do
          any_of do
            with :name, 'design'
            with :name, 'build'
          end
        end
      end
      expect(last_fq.last).to include('(name_s:design OR name_s:build)')
    end

    it 'escapes quotes and backslashes through both levels of nesting' do
      value = %q(say "hi" \ bye)
      session.search(Project) { with_child(:milestones) { with :name, value } }

      # Undo the escaping the way Solr's parsers will: the _query_ phrase, then the local param
      unescape = ->(string) { string.gsub(/\\(.)/, '\1') }
      local_params = unescape.(last_fq.last[/\A_query_:"(.*)"\z/, 1])
      child_query = unescape.(local_params[/ v="(.*)"\}\z/, 1])

      expect(child_query).to eq(%Q((_sunspot_nested_path_s:"Project.milestones" AND name_s:#{Sunspot::Util.escape(value)})))
    end

    it 'raises for an association that was never declared' do
      expect { session.search(Project) { with_child(:tasks) {} } }.to raise_error(Sunspot::UnrecognizedFieldError)
    end

    it 'resolves the association across a multi-class search' do
      session.search(Project, Post) { with_child(:milestones) { with :name, 'design' } }
      expect(last_fq.last).to include('Project.milestones')
    end
  end

  describe 'removal' do
    it 'removes the whole block when removing a parent' do
      project = Project.new
      session.remove(project)
      expect(connection).to have_delete("Project #{project.id}")
      expect(connection).to have_delete_by_query(%Q(_root_:("Project\\ #{project.id}")))
    end

    it 'splits the block deletes to stay under the boolean clause limit' do
      session.remove_by_id(Project, (1..1100).to_a)
      expect(connection.deletes_by_query.length).to eq(3)
    end

    it 'removes the whole block when removing by id' do
      session.remove_by_id(Project, 1, 2)
      expect(connection).to have_delete('Project 1', 'Project 2')
      expect(connection).to have_delete_by_query('_root_:("Project\\ 1" OR "Project\\ 2")')
    end

    it 'removes the parents and their children in one query when removing a class' do
      session.remove_all(Project)
      expect(connection.deletes_by_query).to eq([
        %q{(type:Project) OR _query_:"{!child of=\"*:* -_sunspot_nested_path_s:[* TO *]\" v=\"type:Project\"}"}
      ])
    end

    it 'removes the parents and their children in one query when removing by scope' do
      session.remove(Project) { with :status, 'archived' }
      expect(connection.deletes_by_query).to eq([
        %q{((type:Project AND status_s:archived)) OR _query_:"{!child of=\"*:* -_sunspot_nested_path_s:[* TO *]\" v=\"(type:Project AND status_s:archived)\"}"}
      ])
    end

    it "removes a nested subclass's children when removing a class without nested associations" do
      session.remove_all(Asset)
      expect(connection.deletes_by_query).to eq([
        %q{(type:Asset) OR _query_:"{!child of=\"*:* -_sunspot_nested_path_s:[* TO *]\" v=\"type:Asset\"}"}
      ])
    end

    it 'removes a class with no nested associations anywhere beneath it by its plain query' do
      session.remove_all(Post)
      session.remove(Post) { with :title, 'monkeys' }
      expect(connection.deletes_by_query).to eq(['type:Post', '(type:Post AND title_ss:monkeys)'])
    end

    it 'removes a class without nested associations when another registered class no longer resolves' do
      Object.const_set(:GoneThing, Class.new(MockRecord))
      Sunspot.setup(GoneThing) { string :name }
      Object.send(:remove_const, :GoneThing)

      session.remove_all(Post)
      session.remove(Post) { with :title, 'monkeys' }
      expect(connection.deletes_by_query).to eq(['type:Post', '(type:Post AND title_ss:monkeys)'])
    end

    it 'sends no block delete when removing a record of a class without nested associations' do
      session.remove(Post.new)
      expect(connection.deletes_by_query).to be_empty
    end
  end
end
