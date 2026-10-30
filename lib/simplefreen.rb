# frozen_string_literal: true

# Simplefreen — SimpleFIN bridge for Actual Budget (and other SimpleFIN
# clients). Manages profiles, schedules syncs, serves the SimpleFIN
# protocol, and delegates bank scraping to a separate freentonic server
# reached via HTTP. Zero runtime gem dependencies.

module Simplefreen
end

require_relative "simplefreen/version"
require_relative "simplefreen/errors"

require_relative "simplefreen/crypto"
require_relative "simplefreen/paths"
require_relative "simplefreen/atomic_file"
require_relative "simplefreen/profile_health"
require_relative "simplefreen/profile_store"
require_relative "simplefreen/state_store"
require_relative "simplefreen/cache_store"
require_relative "simplefreen/claim_store"
require_relative "simplefreen/run_log"
require_relative "simplefreen/history_store"
require_relative "simplefreen/reshape"
require_relative "simplefreen/consolidation"
require_relative "simplefreen/consolidation_store"
require_relative "simplefreen/consolidation_groups_store"
require_relative "simplefreen/consolidated_reshape"
require_relative "simplefreen/http"

require_relative "simplefreen/freentonic_client"
require_relative "simplefreen/freentonic_health"
require_relative "simplefreen/push_tokens"
require_relative "simplefreen/notifier"

require_relative "simplefreen/feature"
require_relative "simplefreen/scheduler"
require_relative "simplefreen/watchdog"
require_relative "simplefreen/protocol"
require_relative "simplefreen/push_receiver"
require_relative "simplefreen/workflows_refresher"
require_relative "simplefreen/admin_api"
require_relative "simplefreen/admin_ui"
require_relative "simplefreen/router"
require_relative "simplefreen/server"
