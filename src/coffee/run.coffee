Q = require 'q'
_ = require 'underscore'
Lynx = require 'lynx'
SphereClient = require 'sphere-node-client'
{Qutils, Logger, ProjectCredentialsConfig} = require 'sphere-node-utils'
package_json = require '../package.json'

argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret --logDir dir --logLevel level --timeout timeout')
  .describe('projectKey', 'your SPHERE.IO project-key')
  .describe('clientId', 'your SPHERE.IO OAuth client id')
  .describe('clientSecret', 'your SPHERE.IO OAuth client secret')
  .describe('timeout', 'timeout for requests')
  .describe('sphereHost', 'SPHERE.IO API host to connecto to')
  .describe('logLevel', 'log level for file logging')
  .describe('logDir', 'directory to store logs')
  .default('timeout', 60000)
  .default('logLevel', 'info')
  .default('logDir', '.')
  .demand(['projectKey'])
  .argv

@summary =
  variants:
    count: 0
    event_add: 0
    event_change: 0
    event_remove: 0
    event_not_needed: 0
  total: 0
  synced: 0
  failed: 0

getSummaryReport = (prefix = 'Summary') =>
  "#{prefix}: #{@summary.synced} synced / #{@summary.failed} failed from #{@summary.total} / #{@totalProducts} products. " +
  "(Events from #{@summary.variants.count} variants: ADD[#{@summary.variants.event_add}], CHANGE[#{@summary.variants.event_change}], " +
  "REMOVE[#{@summary.variants.event_remove}], NOT_NEEDED[#{@summary.variants.event_not_needed}])"

IS_ON_STOCK_ATTR_NAME = 'isOnStock'

logger = new Logger
  name: "#{package_json.name}-#{package_json.version}"
  streams: [
    { level: 'error', stream: process.stderr }
    { level: argv.logLevel, path: "#{argv.logDir}/#{package_json.name}.log" }
  ]

metrics = new Lynx 'localhost', 8125,
  on_error: -> #noop

process.on 'SIGUSR2', -> logger.reopenFileStreams()
process.on 'exit', => process.exit(@exitCode)

ProjectCredentialsConfig.create()
.then (credentials) =>
  options =
    config: credentials.enrichCredentials
      project_key: argv.projectKey
      client_id: argv.clientId
      client_secret: argv.clientSecret
    timeout: argv.timeout
    user_agent: "#{package_json.name} - #{package_json.version}"
    logConfig:
      logger: logger
  options.host = argv.sphereHost if argv.sphereHost?

  @totalProducts = undefined
  client = new SphereClient options
  client.productProjections.staged(false).sort('id').all().process (payload) =>
    @totalProducts = payload.body.total unless @totalProducts
    products = payload.body.results
    logger.info "Processing #{_.size products} products"

    Qutils.processList products, (chunk) =>
      logger.info "Updating #{_.size chunk} products in CHUNKS"
      Q.allSettled _.map chunk, (product) =>

        allVariants = [product.masterVariant].concat(product.variants or [])

        buildActions = =>
          _.chain(allVariants).map (variant) =>
            @summary.variants.count++
            metrics.increment 'variants_update.count'
            # check if it needs update
            isOnStockAttr = _.find variant.attributes, (a) -> a.name is IS_ON_STOCK_ATTR_NAME

            _action = (val) ->
              action: 'setAttribute'
              variantId: variant.id
              name: IS_ON_STOCK_ATTR_NAME
              value: val
              staged: false

            if variant.availability and isOnStockAttr
              if variant.availability.isOnStock is isOnStockAttr.value
                # same value, no update needed
                @summary.variants.event_not_needed++
                metrics.increment 'variants_update.not_needed'
                null
              else
                # different value => update attribute
                @summary.variants.event_change++
                metrics.increment 'variants_update.changed'
                _action variant.availability.isOnStock
            else
              if isOnStockAttr
                # no availability anymore => remove attribute
                @summary.variants.event_remove++
                metrics.increment 'variants_update.removed'
                _action undefined
              else
                if variant.availability
                  # availability is present but no attribute => add attribute
                  @summary.variants.event_add++
                  metrics.increment 'variants_update.added'
                  _action variant.availability.isOnStock
                else
                  # both availability and attribute are not preset => no update needed
                  @summary.variants.event_not_needed++
                  metrics.increment 'variants_update.not_needed'
                  null
          .filter (action) -> not _.isNull action
          .value()

        payload =
          version: product.version
          actions: buildActions()
        @summary.total++
        metrics.increment 'products_update.count'
        client.products.byId(product.id).update(payload)
      .then (results) =>
        failures = []
        _.each results, (result) =>
          if result.state is 'fulfilled'
            @summary.synced++
            metrics.increment 'products_update.synced'
          else
            @summary.failed++
            metrics.increment 'products_update.failed'
            failures.push result.reason
        logger.debug getSummaryReport('Progress')
        if _.size(failures) > 0
          logger.error errors: failures, 'Errors while syncing products'
        Q()
    , {accumulate: false, maxParallel: 10}
  , {accumulate: false}
  .then =>
    logger.info getSummaryReport()
    @exitCode = 0
  .fail (error) =>
    logger.error error, 'Oops, something went wrong!'
    @exitCode = 1
  .done()
.fail (error) =>
  logger.error error, 'Problems on getting client credentials from config files.'
  @exitCode = 1
.done()
