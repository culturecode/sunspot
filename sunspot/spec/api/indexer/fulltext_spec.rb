require File.expand_path('spec_helper', File.dirname(__FILE__))

describe 'indexing fulltext fields' do
  it 'indexes text field' do
    session.index(post(:title => 'A Title'))
    expect(connection).to have_add_with(:title_text => 'A Title')
  end

  it 'indexes stored text field' do
    session.index(post(:body => 'Test body'))
    expect(connection).to have_add_with(:body_textsv => 'Test body')
  end

  it 'indexes text field with boost' do
    session.index(post(:title => 'A Title'))
    expect(connection.adds.last.first.field_by_name(:title_text).attrs[:boost]).to eq(2)
  end

  it 'indexes multiple values for a text field' do
    session.index(post(:body => %w(some title)))
    expect(connection).to have_add_with(:body_textsv => %w(some title))
  end

  it 'indexes text via a block accessor' do
    session.index(post(:title => 'backwards'))
    expect(connection).to have_add_with(:backwards_title_text => 'sdrawkcab')
  end

  it 'indexes document level boost using block' do
    session.index(post(:ratings_average => 4.0))
    expect(connection.adds.last.first.attrs[:boost]).to eq(1.25)
  end

  it 'indexes document level boost using attribute' do
    session.index(Namespaced::Comment.new(:boost => 1.5))
    expect(connection.adds.last.first.attrs[:boost]).to eq(1.5)
  end

  it 'indexes document level boost defined statically' do
    session.index(Photo.new)
    expect(connection.adds.last.first.attrs[:boost]).to eq(0.75)
  end

  describe 'with index_time_boosts off' do
    before { config.solr.index_time_boosts = false }

    it 'sends no field boost' do
      session.index(post(:title => 'A Title'))
      expect(connection.adds.last.first.field_by_name(:title_text).attrs).not_to have_key(:boost)
    end

    it 'sends no document boost' do
      session.index(Photo.new)
      expect(connection.adds.last.first.attrs).not_to have_key(:boost)
    end

    it 'sends no field boost from a batch' do
      session.batch { session.index(post(:title => 'A Title')) }
      expect(connection.adds.last.first.field_by_name(:title_text).attrs).not_to have_key(:boost)
    end

    it 'sends no field boost in an atomic update' do
      session.atomic_update(Post, post.id => { :title => 'A Title' })
      expect(connection.adds.last.first.field_by_name(:title_text).attrs).not_to have_key(:boost)
    end
  end

  it 'sends no field boost once index_time_boosts is turned off after indexing' do
    session.index(post(:title => 'A Title'))
    config.solr.index_time_boosts = false
    session.index(Post.new(:title => 'Another Title'))
    expect(connection.adds.last.first.field_by_name(:title_text).attrs).not_to have_key(:boost)
  end
end
