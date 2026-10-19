module IntegrationHelper
  def self.included(base)
    base.before(:all) do
      Sunspot.config.solr.url = ENV['SOLR_URL'] || 'http://localhost:8983/solr/default'
      Sunspot.config.solr.update_format = ENV['UPDATE_FORMAT'].to_sym if ENV['UPDATE_FORMAT']
      Sunspot.reset!(true)
    end
  end

  # Skips the example on Solr `major` and later, for behaviour that version changed
  def skip_from_solr(major, reason)
    version = Sunspot.session.send(:connection).get('admin/system')['lucene']['solr-spec-version']
    skip "#{reason} (Solr #{version})" if version.to_i >= major
  end

  def featured_for_posts(method, param, negated = false)
    with_method = negated ? :without : :with
    param = date_ranges[param] if param.is_a? String

    Sunspot.search(Post) do
      send(with_method, :featured_for).send(method, param)
    end.results
  end
end
