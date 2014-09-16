Q = require 'q'
_ = require 'underscore'
SphereClient = require 'sphere-node-client'
{Logger} = require 'sphere-node-utils'
AvailabilityService = require '../../lib/service/availability'
package_json = require '../../package.json'
Config = require '../../config'

VARIANTS = [
  {id: 1, sku: 's1', attributes: [{name: 'isOnStock', value: false}]}
  {id: 2, sku: 's2', availability: {isOnStock: true}, attributes: [{name: 'isOnStock', value: true}]}
  {id: 3, sku: 's3'}
]

EXPANDED_VARIANTS = [
  {id: 1, sku: 's1', availability: {isOnStock: true}, attributes: [{name: 'isOnStock', value: false}]}
  {id: 2, sku: 's2', attributes: [{name: 'isOnStock', value: true}]}
  {id: 3, sku: 's3', availability: {isOnStock: false}}
]

INVENTORY_ENTRIES = [
  {id: 1, sku: 's1', quantityOnStock: 10}
  {id: 3, sku: 's3', quantityOnStock: 0}
]

PRODUCTS = [
  {id: '123', masterVariant: VARIANTS[0]}
]


describe 'Availability service', ->

  beforeEach ->
    logger = new Logger
      name: "#{package_json.name}-#{package_json.version}"
      streams: [
        { level: 'info', stream: process.stdout }
      ]
    client = new SphereClient
      config: Config.config
      logConfig:
        logger: logger
    @availability = new AvailabilityService client, logger,
      withInventoryCheck: false
      attributeName: 'isOnStock'

  it 'should initialize', ->
    expect(@availability.withInventoryCheck).toBe false
    expect(@availability.attributeName).toBe 'isOnStock'
    expect(@availability.totalProducts).not.toBeDefined()
    expect(@availability.summary).toEqual
      variants:
        count: 0
        event_add: 0
        event_change: 0
        event_remove: 0
        event_not_needed: 0
      total: 0
      synced: 0
      failed: 0

  _.each ['Summary', 'Progress'], (prefix) ->
    it "should generate summary report with prefix #{prefix}", ->
      @availability.totalProducts = 10
      @availability.summary =
        variants:
          count: 25
          event_add: 5
          event_change: 10
          event_remove: 2
          event_not_needed: 8
        total: 10
        synced: 8
        failed: 2
      "#{prefix}: 8 synced / 2 failed from 10 / 10 products. (Events from 25 variants: ADD[5], CHANGE[10], REMOVE[2], NOT_NEEDED[8])"

  it 'should expand variants (no inventory check)', (done) ->
    @availability.expandVariants VARIANTS
    .then (expanded) ->
      expect(expanded).toEqual VARIANTS
      done()
    .fail (e) -> done(e)

  it 'should expand variants (with inventory check)', (done) ->
    spyOn(@availability.client.inventoryEntries, 'fetch').andCallFake ->
      Q
        statusCode: 200
        body:
          count: _.size(INVENTORY_ENTRIES)
          total: _.size(INVENTORY_ENTRIES)
          results: INVENTORY_ENTRIES
    @availability.withInventoryCheck = true
    @availability.expandVariants VARIANTS
    .then (expanded) ->
      expect(expanded).toEqual EXPANDED_VARIANTS
      done()
    .fail (e) -> done(e)

  it 'should build actions', ->
    actions = @availability.buildActions EXPANDED_VARIANTS
    expect(actions).toEqual [
      {
        action: 'setAttribute'
        variantId: 1
        name: 'isOnStock'
        value: true
        staged: false
      },
      {
        action: 'setAttribute'
        variantId: 2
        name: 'isOnStock'
        value: undefined
        staged: false
      },
      {
        action: 'setAttribute'
        variantId: 3
        name: 'isOnStock'
        value: false
        staged: false
      }
    ]

  it 'should process products', (done) ->
    spyOn(@availability.client.productProjections, 'process').andCallFake (fn, opts) ->
      fn {statusCode: 200, body: {total: 1, results: PRODUCTS}}
    spyOn(@availability.client.inventoryEntries, 'fetch').andCallFake ->
      Q
        statusCode: 200
        body:
          count: _.size(INVENTORY_ENTRIES)
          total: _.size(INVENTORY_ENTRIES)
          results: INVENTORY_ENTRIES
    spyOn(@availability.client.products, 'update').andCallFake -> Q {statusCode: 200}
    @availability.run()
    .then (result) =>
      expect(_.isEmpty(result)).toBe true
      expect(@availability.summary).toEqual
        variants:
          count: 1
          event_add: 0
          event_change: 1
          event_remove: 0
          event_not_needed: 0
        total: 1
        synced: 1
        failed: 0
      done()
    .fail (e) -> done(e)

