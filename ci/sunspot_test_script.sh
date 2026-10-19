#!/bin/sh

set +e

SOLR_PORT=8983
export SUNSPOT_LIB_HOME=`pwd`

solr_responding() {
  curl -o /dev/null "http://localhost:$SOLR_PORT/solr/admin/ping" > /dev/null 2>&1
}

# With SOLR_IMAGE set, runs that Docker image of Solr with the configset in ci/solr9, in place of the
# Solr that sunspot_solr bundles.
start_solr_container() {
  /bin/echo -n "Starting $SOLR_IMAGE on port $SOLR_PORT for Sunspot specs..."
  docker run -d --name sunspot-solr -p $SOLR_PORT:8983 $SOLR_IMAGE > /dev/null
  until curl -s -o /dev/null "http://localhost:$SOLR_PORT/solr/admin/cores"; do
    /bin/echo -n "."
    sleep 1
  done
  docker exec --user root sunspot-solr mkdir -p /var/solr/data/configsets
  docker cp "$SUNSPOT_LIB_HOME/ci/solr9" sunspot-solr:/var/solr/data/configsets/sunspot
  docker exec --user root sunspot-solr chown -R solr:solr /var/solr/data/configsets
  curl -s -f -X POST "http://localhost:$SOLR_PORT/solr/admin/cores?action=CREATE&name=default&configSet=sunspot" > /dev/null
  /bin/echo "done."
}

start_solr_server() {
  if [ -n "$SOLR_IMAGE" ]; then
    start_solr_container
    return
  fi

  # go to sunspot_solr folder and install dependencies
  current_path=`pwd`
  cd ../sunspot_solr
  bundle config set --local path 'vendor/bundle'
  bundle install --quiet

  # stop solr of already running (but it should not be)
  if [ -f sunspot-solr.pid ]; then stop_solr_server || true; fi
  /bin/echo -n "Starting Solr on port $SOLR_PORT for Sunspot specs..."

  # start solr
  bundle exec sunspot-solr start -p $SOLR_PORT

  # wait while Solr is up and running
  while ! solr_responding; do
    /bin/echo -n "."
    sleep 1
  done
  /bin/echo "done."

  cd $current_path
}

stop_solr_server() {
  if [ -n "$SOLR_IMAGE" ]; then
    docker rm -f sunspot-solr > /dev/null
    return
  fi

  cd ../sunspot_solr
  /bin/echo -n "Stopping Solr... "
  bundle exec sunspot-solr stop -p $SOLR_PORT
  /bin/echo "done."
}

case $GEM in
  "sunspot")

    cd sunspot
    bundle config set --local path 'vendor/bundle'
    bundle install --quiet

    start_solr_server

    # Invoke the sunspot specs
    bundle exec appraisal install && bundle exec appraisal rake spec
    rv=$?

    stop_solr_server

    exit $rv
    ;;

  "sunspot_rails")

    cd sunspot
    bundle config set --local path 'vendor/bundle'
    bundle install --quiet

    start_solr_server

    cd ../sunspot_rails
    bundle config set --local path 'vendor/bundle'
    bundle install --quiet
    gem list
    bundle exec appraisal install && bundle exec appraisal rspec
    rv=$?

    cd ../sunspot
    stop_solr_server

    exit $rv
    ;;

  "sunspot_solr")

    cd sunspot_solr
    bundle config set --local path 'vendor/bundle'
    bundle install --quiet
    bundle exec rake spec
    exit $?
    ;;
  *)
esac
