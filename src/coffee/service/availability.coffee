_ = require 'underscore'
_.mixin require('underscore-mixins')
Promise = require 'bluebird'
Lynx = require 'lynx'

module.exports = class

  constructor: (@client, @logger, opts = {}) ->
    {@withInventoryCheck, @attributeName} = opts
    @totalProducts = undefined
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

  getSummaryReport: (prefix = 'Summary') ->
    "#{prefix}: #{@summary.synced} synced / #{@summary.failed} failed from #{@summary.total} / #{@totalProducts} products. " +
    "(Events from #{@summary.variants.count} variants: ADD[#{@summary.variants.event_add}], CHANGE[#{@summary.variants.event_change}], " +
    "REMOVE[#{@summary.variants.event_remove}], NOT_NEEDED[#{@summary.variants.event_not_needed}])"

  sendMetrics: ->
    metrics = new Lynx 'localhost', 8125,
      on_error: -> #noop
    # send metrics in batches (gauges)
    metrics.send
      'products_update.total': "#{@summary.total}|g"
      'products_update.synced': "#{@summary.synced}|g"
      'products_update.failed': "#{@summary.failed}|g"
      'variants_update.count': "#{@summary.variants.count}|g"
      'variants_update.added': "#{@summary.variants.event_add}|g"
      'variants_update.changed': "#{@summary.variants.event_change}|g"
      'variants_update.removed': "#{@summary.variants.event_remove}|g"
      'variants_update.not_needed': "#{@summary.variants.event_not_needed}|g"
    , 1

  run: ->
    @logger.info "Running with inventory check flag (#{@withInventoryCheck})"
    @client.productProjections.staged(false).sort('id').perPage(10).process (payload) =>
      @totalProducts = payload.body.total unless @totalProducts
      products = payload.body.results
      @logger.debug "Processing #{_.size products} products"

      Promise.settle _.map products, (product) =>

        allVariants = [product.masterVariant].concat(product.variants or [])

        Promise.map _.batchList(allVariants, 15), (variantsChunk) =>
          @expandVariants variantsChunk
        , {concurrency: 1} # run 1 batch at a time
        .then (expandedVariants) =>
          actions = @buildActions _.flatten(expandedVariants)
          if _.size(actions) > 0
            payload =
              version: product.version
              actions: actions
            @summary.total++
            @client.products.byId(product.id).update(payload)
          else
            Promise.resolve()
      .then (results) =>
        failures = []
        _.each results, (result) =>
          if result.isFulfilled()
            @summary.synced++
          if result.isRejected()
            @summary.failed++
            failures.push result.reason()
        @logger.debug @getSummaryReport('Progress')
        if _.size(failures) > 0
          @logger.error errors: failures, 'Errors while syncing products'
        Promise.resolve()
    , {accumulate: false}

  expandVariants: (variants) ->
    if @withInventoryCheck

      skus = ""
      _.each variants, (v) ->
        skus += "\"#{v.sku}\"" if v.sku

      predicate = "sku in (#{skus.join(', ')})"

      @client.inventoryEntries.all()
      .where(predicate)
      .fetch()
      .then (result) =>
        @logger.debug "Found #{result.body.count} inventories (tot: #{result.body.total}) out of #{_.size variants} given variants"
        Promise.resolve _.map variants, (v) ->
          inventory = _.find result.body.results, (r) -> r.sku is v.sku
          if inventory
            v.availability =
              isOnStock: inventory.quantityOnStock > 0
          else
            v.availability = undefined
          v
    else
      Promise.resolve variants

  buildActions: (variants) ->
    _.chain(variants).map (variant) =>
      @summary.variants.count++
      # check if it needs update
      isOnStockAttr = _.find variant.attributes, (a) => a.name is @attributeName

      _action = (val) =>
        action: 'setAttribute'
        variantId: variant.id
        name: @attributeName
        value: val
        staged: false

      if variant.availability and isOnStockAttr
        if variant.availability.isOnStock is isOnStockAttr.value
          # same value, no update needed
          @summary.variants.event_not_needed++
          null
        else
          # different value => update attribute
          @summary.variants.event_change++
          _action variant.availability.isOnStock
      else
        if isOnStockAttr
          # no availability anymore => remove attribute
          @summary.variants.event_remove++
          _action undefined
        else
          if variant.availability
            # availability is present but no attribute => add attribute
            @summary.variants.event_add++
            _action variant.availability.isOnStock
          else
            # both availability and attribute are not preset => no update needed
            @summary.variants.event_not_needed++
            null
    .filter (action) -> not _.isNull action
    .value()
