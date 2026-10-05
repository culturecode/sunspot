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

    it 'removes every child when removing the class, and nothing else' do
      Sunspot.remove_all!(Project)
      expect(children).to eq(0)
      expect(solr_count('*:*')).to eq(1)
      expect(Sunspot.search(Memo).results).to eq([@memo])
    end
  end
end
