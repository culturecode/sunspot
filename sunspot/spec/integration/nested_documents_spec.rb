require File.expand_path('../spec_helper', File.dirname(__FILE__))

# RSolr 1.x has no RSolr::Document, so it can't send child documents
describe 'nested documents', :if => defined?(RSolr::Document::CHILD_DOCUMENT_KEY) do
  def milestone(name, started_at, attrs = {})
    Milestone.new({ :name => name, :started_at => started_at }.merge(attrs))
  end

  def search(&block)
    Sunspot.search(Project, &block).results
  end

  # Raw count, straight from Solr, so leftover children can't hide behind Sunspot's type filter
  def solr_count(query)
    Sunspot.session.send(:connection).get('select', :params => { :q => query, :rows => 0 })['response']['numFound']
  end

  let(:q1) { Time.utc(2026, 1, 1)...Time.utc(2026, 4, 1) }

  # Solr before 8 replaces a document with children by _root_ and one without by id
  def skip_before_solr_8
    version = Sunspot.session.send(:connection).get('admin/system')['lucene']['solr-spec-version']
    skip "Solr #{version} doesn't replace a block whose children went from some to none or none to some" if version.to_i < 8
  end

  before :each do
    Sunspot.remove_all!

    @designed_in_q1 = Project.new(:name => 'designed in q1', :status => 'active', :milestones => [
      milestone('design', Time.utc(2026, 2, 1), :due_at => Time.utc(2026, 1, 15), :finished_at => Time.utc(2026, 2, 20), :owner_names => %w(ana))
    ])
    # A design milestone and a Q1 date, but on different milestones
    @designed_earlier = Project.new(:name => 'designed earlier', :status => 'active', :milestones => [
      milestone('design', Time.utc(2025, 6, 1), :due_at => Time.utc(2025, 7, 1), :finished_at => Time.utc(2025, 6, 20), :owner_names => %w(ben)),
      milestone('build', Time.utc(2026, 2, 1), :owner_names => %w(ana))
    ])
    @without_milestones = Project.new(:name => 'no milestones', :status => 'archived')

    # A document of another class between the blocks, sharing a field name with the children
    @memo = Memo.new(:name => 'design')

    Sunspot.index!(@designed_in_q1, @memo, @designed_earlier, @without_milestones)
  end

  describe 'with_child' do
    it 'requires one child to meet every condition' do
      q1 = self.q1
      expect(search { with_child(:milestones) { with :name, 'design'; with(:started_at, q1) } }).to eq([@designed_in_q1])
    end

    it 'matches any child with no conditions' do
      expect(search { with_child(:milestones) }).to match_array([@designed_in_q1, @designed_earlier])
    end

    it 'filters on a field computed from the child' do
      expect(search { with_child(:milestones) { with(:days_late).greater_than(0) } }).to eq([@designed_in_q1])
    end

    it 'matches a value of a multivalued child field' do
      expect(search { with_child(:milestones) { with :owner_names, 'ben' } }).to eq([@designed_earlier])
    end

    it 'matches a child by a negated condition' do
      expect(search { with_child(:milestones) { without :name, 'design' } }).to eq([@designed_earlier])
    end

    it 'matches a child by several negated conditions' do
      expect(search { with_child(:milestones) { without :name, 'design'; without :name, 'launch' } }).to eq([@designed_earlier])
    end

    it 'supports alternatives inside one child' do
      q1 = self.q1
      results = search do
        with_child :milestones do
          any_of do
            all_of { with :name, 'design'; with(:started_at, q1) }
            with :owner_names, 'ben'
          end
        end
      end
      expect(results).to match_array([@designed_in_q1, @designed_earlier])
    end

    it 'combines a child condition with a parent condition in any_of' do
      results = search do
        any_of do
          with_child(:milestones) { with :owner_names, 'ben' }
          with :status, 'archived'
        end
      end
      expect(results).to match_array([@designed_earlier, @without_milestones])
    end

    it 'combines with parent restrictions' do
      expect(search { with :status, 'active'; with_child(:milestones) { with :owner_names, 'ana' } }).to match_array([@designed_in_q1, @designed_earlier])
      expect(search { with :status, 'archived'; with_child(:milestones) }).to eq([])
    end

    it 'finds values that need escaping' do
      tricky = %q(say "hi" \ bye)
      odd = Project.new(:milestones => [milestone(tricky, Time.utc(2026, 1, 1))])
      Sunspot.index!(odd)
      expect(search { with_child(:milestones) { with :name, tricky } }).to eq([odd])
    end
  end

  describe 'without_child' do
    it 'matches parents with no child meeting the conditions, including parents with no children' do
      q1 = self.q1
      expect(search { without_child(:milestones) { with :name, 'design'; with(:started_at, q1) } }).to match_array([@designed_earlier, @without_milestones])
    end
  end

  describe 'searching the parents alone' do
    it 'returns parents, never children' do
      expect(search {}).to match_array([@designed_in_q1, @designed_earlier, @without_milestones])
    end

    it 'leaves other classes alone' do
      expect(Sunspot.search(Memo).results).to eq([@memo])
    end
  end

  describe 'reindexing' do
    it 'replaces the whole block' do
      @designed_earlier.milestones = [@designed_earlier.milestones.last]
      Sunspot.index!(@designed_earlier)

      expect(solr_count(%Q(_root_:"Project #{@designed_earlier.id}"))).to eq(2)
      expect(solr_count('_sunspot_nested_path_s:[* TO *]')).to eq(2)
      expect(search { with_child(:milestones) { with :owner_names, 'ben' } }).to eq([])
    end

    it 'removes every child when a parent is reindexed with none' do
      skip_before_solr_8
      @designed_earlier.milestones = []
      Sunspot.index!(@designed_earlier)

      expect(solr_count(%Q(_root_:"Project #{@designed_earlier.id}" AND _sunspot_nested_path_s:[* TO *]))).to eq(0)
      expect(solr_count(%Q(id:"Project #{@designed_earlier.id}"))).to eq(1)
    end

    it 'replaces a parent that had no children when it is reindexed with some' do
      skip_before_solr_8
      @without_milestones.milestones = [milestone('launch', Time.utc(2026, 3, 1))]
      Sunspot.index!(@without_milestones)

      expect(solr_count(%Q(id:"Project #{@without_milestones.id}"))).to eq(1)
      expect(Sunspot.search(Project).hits.length).to eq(3)
      expect(search { with_child(:milestones) { with :name, 'launch' } }).to eq([@without_milestones])
    end
  end

  describe 'removal' do
    def children
      solr_count('_sunspot_nested_path_s:[* TO *]')
    end

    it 'removes the children with their parent' do
      Sunspot.remove!(@designed_earlier)
      expect(children).to eq(1)
      expect(search { with_child(:milestones) }).to eq([@designed_in_q1])
    end

    it 'removes the children when removing by id' do
      Sunspot.remove_by_id!(Project, @designed_earlier.id)
      expect(children).to eq(1)
    end

    it 'removes the children when removing by scope' do
      Sunspot.remove!(Project) { with :name, 'designed earlier' }
      expect(children).to eq(1)
      expect(search {}).to match_array([@designed_in_q1, @without_milestones])
    end

    it 'removes the parents a child condition selects, with their children' do
      Sunspot.remove!(Project) { with_child(:milestones) { with :owner_names, 'ben' } }

      expect(solr_count(%Q(_root_:"Project #{@designed_earlier.id}"))).to eq(0)
      expect(children).to eq(1)
      expect(search {}).to match_array([@designed_in_q1, @without_milestones])
    end

    it 'removes the children of a subclass that has no setup of its own' do
      Sunspot.index!(Spinoff.new(:name => 'spun off', :milestones => [milestone('design', Time.utc(2026, 2, 1))]))
      Sunspot.remove_all!(Spinoff)
      expect(solr_count('id:Spinoff*')).to eq(0)

      Sunspot.index!(Spinoff.new(:name => 'spun off', :milestones => [milestone('design', Time.utc(2026, 2, 1))]))
      Sunspot.remove!(Spinoff) { with :name, 'spun off' }
      expect(solr_count('id:Spinoff*')).to eq(0)
    end

    it 'removes every child when removing the class, and nothing else' do
      Sunspot.remove_all!(Project)
      expect(children).to eq(0)
      expect(solr_count('*:*')).to eq(1)
      expect(Sunspot.search(Memo).results).to eq([@memo])
    end
  end

  describe 'an association read through another method' do
    it 'indexes and finds the children the :using method returns' do
      plan = Plan.new(:name => 'plan', :milestones => [milestone('design', Time.utc(2026, 2, 1))])
      Sunspot.index!(plan)

      expect(Sunspot.search(Plan) { with_child(:steps) { with :name, 'design' } }.results).to eq([plan])
      expect(solr_count('_sunspot_nested_path_s:"Plan.steps"')).to eq(1)
    end
  end

  describe 'other classes with the same association' do
    let(:t) { Time.utc(2026, 2, 1) }

    it 'finds a subclass that declares the association again through a search of its superclass' do
      sub_project = SubProject.new(:name => 'sub', :milestones => [milestone('review', t)])
      Sunspot.index!(sub_project)

      expect(search { with_child(:milestones) { with :name, 'review' } }).to eq([sub_project])
    end

    it 'matches children of every searched class that declares the association' do
      program = Program.new(:name => 'program', :milestones => [milestone('design', t)])
      Sunspot.index!(program)

      [[Project, Program], [Program, Project]].each do |types|
        results = Sunspot.search(*types) { with_child(:milestones) { with :name, 'design' } }.results
        expect(results).to match_array([@designed_in_q1, @designed_earlier, program])
      end
    end

    it 'resolves a child field declared by any searched class, whatever their order' do
      gadget = Gadget.new(:name => 'gadget', :milestones => [milestone('design', Time.utc(2026, 2, 1))])
      Sunspot.index!(gadget)

      [[Project, Gadget], [Gadget, Project]].each do |types|
        expect(Sunspot.search(*types) { with_child(:milestones) { with :only_here, 'yes' } }.results).to eq([gadget])
        expect(Sunspot.search(*types) { with_child(:milestones) { with :name, 'design' } }.results).to match_array([@designed_in_q1, @designed_earlier])
      end
    end

    it 'searches text fields on the children of several classes' do
      gadget = Gadget.new(:name => 'gadget', :milestones => [milestone('design', Time.utc(2026, 2, 1))])
      Sunspot.index!(gadget)

      expect(Sunspot.search(Project, Gadget) { with_child(:milestones) { text_fields { with :notes, 'gadget notes' } } }.results).to eq([gadget])
    end

    it "resolves a superclass's child fields from its own setup when a subclass declares the association again" do
      crate = Crate.new(:name => 'crate', :items => [OpenStruct.new(:at => Time.utc(2026, 2, 1), :body => 'design', :attrs => { :color => 'red' })])
      Sunspot.index!(crate)

      expect(Sunspot.search(Crate) { with_child(:items) { with(:at).greater_than(Time.utc(2026, 1, 1)) } }.results).to eq([crate])
      expect(Sunspot.search(Crate) { with_child(:items) { text_fields { with :body, 'design' } } }.results).to eq([crate])
      expect(Sunspot.search(Crate) { with_child(:items) { dynamic(:attrs) { with :color, 'red' } } }.results).to eq([crate])
    end

    it 'rejects a child field the searched classes declare differently' do
      expect { Sunspot.search(Project, Gadget) { with_child(:milestones) { with(:started_at).greater_than(0) } } }.to raise_error(Sunspot::UnrecognizedFieldError)
    end

    it 'removes the children of a nested subclass when removing through its superclass' do
      Sunspot.index!(Vehicle.new(:name => 'van', :parts => [milestone('wheel', t)]))
      Sunspot.remove_all!(Asset)
      expect(solr_count('_sunspot_nested_path_s:"Vehicle.parts"')).to eq(0)

      Sunspot.index!(Vehicle.new(:name => 'van', :parts => [milestone('wheel', t)]))
      Sunspot.remove!(Asset) { with :name, 'van' }
      expect(solr_count('_sunspot_nested_path_s:"Vehicle.parts"')).to eq(0)
    end
  end
end
