# Rails 2.3's PostgreSQL adapter hardcodes client_min_messages = 'panic' inside
# set_standard_conforming_strings (run on every connection via
# configure_connection). PostgreSQL 9.6+ removed 'panic' (and 'fatal') as valid
# client_min_messages values, so the SET raises and every connection dies —
# breaking both `rake db:schema:load` and the running server on modern Postgres
# (Railway runs 13+). Override the method to use a still-valid level.
#
# Named 00_ so it loads before any initializer that might open a DB connection.
if defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
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
end
