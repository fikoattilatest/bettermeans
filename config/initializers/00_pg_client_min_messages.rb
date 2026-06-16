# Rails 2.3's PostgreSQL adapter hardcodes client_min_messages = 'panic' inside
# set_standard_conforming_strings (run on every connection via
# configure_connection). PostgreSQL 9.6+ removed 'panic' (and 'fatal') as valid
# client_min_messages values, so the SET raises and every connection dies —
# breaking both `rake db:schema:load` and the running server on modern Postgres
# (Railway runs 13+). Override the method to use a still-valid level.
#
# The adapter is normally loaded lazily on first connect, so require it now to
# force the real class to load BEFORE we reopen it (otherwise our override would
# be clobbered when the gem's definition loads afterwards). Named 00_ so it runs
# before any initializer that might open a DB connection.
require 'active_record/connection_adapters/postgresql_adapter'

module ActiveRecord
  module ConnectionAdapters
    class PostgreSQLAdapter
      def set_standard_conforming_strings
        old, self.client_min_messages = client_min_messages, 'warning'
        execute('SET standard_conforming_strings = on', 'SCHEMA') rescue nil
      ensure
        self.client_min_messages = old
      end
    end
  end
end
