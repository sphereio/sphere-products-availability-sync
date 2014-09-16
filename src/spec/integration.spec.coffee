Q = require 'q'
_ = require 'underscore'
_.mixin require('sphere-node-utils')._u
SphereClient = require 'sphere-node-client'
{Logger} = require 'sphere-node-utils'
AvailabilityService = require '../lib/service/availability'
package_json = require '../package.json'
Config = require '../config'

newProductType = ->
  name: 'Clothing'
  description: 'A sample product type'
  attributes: [
    {
      type:
        name: 'boolean'
      name: 'isOnStock'
      label:
        en: 'Is on stock'
      attributeConstraint: 'None'
      isRequired: false
      isSearchable: true
    }
  ]

newInventoryEntry = (stock) ->
  sku: stock.sku
  quantityOnStock: stock.onStock

newProduct = (pType, inventoryEntries) ->
  name:
    en: 'Product without availability'
  slug:
    en: 'product-without-availability'
  productType:
    id: pType.id
    typeId: 'product-type'
  masterVariant:
    sku: 's0' # this sku should not be mapped
  variants: _.map inventoryEntries, (ie) -> sku: ie.sku

updatePublish = (version) ->
  version: version
  actions: [
    {action: "publish"}
  ]

updateUnpublish = (version) ->
  version: version
  actions: [
    {action: "unpublish"}
  ]

describe 'Integration specs', ->

  beforeEach (done) ->
    @logger = new Logger
      name: "#{package_json.name}-#{package_json.version}"
      streams: [
        { level: 'info', stream: process.stdout }
      ]
    @client = new SphereClient
      config: Config.config
      logConfig:
        logger: @logger
    @availability = new AvailabilityService @client, @logger,
      withInventoryCheck: true
      attributeName: 'isOnStock'

    @logger.debug 'Creating a ProductType'
    @client.productTypes.save(newProductType())
    .then (result) =>
      expect(result.statusCode).toBe 201
      @productType = result.body
      done()
    .fail (error) =>
      @logger.error error
      done(_.prettify(error))

  afterEach (done) ->
    @logger.debug 'Unpublishing all products'
    @client.products.sort('id').where('masterData(published = "true")').process (payload) =>
      Q.all _.map payload.body.results, (product) =>
        @client.products.byId(product.id).update(updateUnpublish(product.version))
    .then (results) =>
      @logger.info "Unpublished #{results.length} products"
      @logger.debug 'About to delete all products'
      @client.products.perPage(0).fetch()
    .then (payload) =>
      @logger.debug "Deleting #{payload.body.total} products"
      Q.all _.map payload.body.results, (product) =>
        @client.products.byId(product.id).delete(product.version)
    .then (results) =>
      @logger.info "Deleted #{results.length} products"
      @logger.debug 'About to delete all product types'
      @client.productTypes.perPage(0).fetch()
    .then (payload) =>
      @logger.debug "Deleting #{payload.body.total} product types"
      Q.all _.map payload.body.results, (productType) =>
        @client.productTypes.byId(productType.id).delete(productType.version)
    .then (results) =>
      @logger.debug "Deleted #{results.length} product types"
      @client.inventoryEntries.all().process (payload) =>
        Q.all _.map payload.body.results, (inventoryEntry) =>
          @client.inventoryEntries.byId(inventoryEntry.id).delete(inventoryEntry.version)
    .then (results) =>
      @logger.info "Deleted #{results.length} inventory entries"
      @logger = null
      @client = null
      @availability = null
      @productType = null
      done()
    .fail (error) =>
      @logger.error error
      done(_.prettify(error))
  , 60000 # 1min


  # 1. create inventories
  # 2. create product with variants
  # 3. publish product
  # 4. assert there is no availability
  # 5. run service
  # 6. assert that variants have correct flag

  it 'should sync availability with inventory check', (done) ->
    stocks = [{sku: 's1', onStock: 10}, {sku: 's2', onStock: 0}, {sku: 's3', onStock: 30}]
    Q.all _.map stocks, (stock) => @client.inventoryEntries.create(newInventoryEntry(stock))
    .then (result) =>
      @logger.debug "Created #{_.size result} inventory entries"
      inventoryEntries = _.map result, (r) -> r.body
      @client.products.create(newProduct(@productType, inventoryEntries))
    .then (result) =>
      product = result.body
      @logger.debug "Created product with id #{product.id}"
      @client.productProjections.byId(product.id).staged().fetch()
      .then (result) =>
        allVariants = [result.body.masterVariant].concat(result.body.variants)
        _.each allVariants, (v) -> expect(v.availability).not.toBeDefined()
        @logger.debug "About to publish product with id #{product.id}"
        @client.products.byId(product.id).update(updatePublish(product.version))
      .then =>
        @logger.debug 'About to run availability sync'
        @availability.run()
      .then =>
        @logger.info @availability.getSummaryReport()
        @client.productProjections.byId(product.id).staged().fetch()
      .then (result) =>
        @logger.debug result, 'Checking results...'
        product = result.body
        expect(product.version).toBeGreaterThan 1
        allVariants = [result.body.masterVariant].concat(result.body.variants)
        _.each allVariants, (v) ->
          matchingStock = _.find stocks, (stock) -> stock.sku is v.sku
          if matchingStock
            isOnStockAttribute = _.first(v.attributes)
            expect(isOnStockAttribute.value).toBe matchingStock.onStock > 0
          else
            expect(_.size(v.attributes)).toBe 0 # masterVariant case
        done()
    .fail (error) =>
      @logger.error error
      done(_.prettify(error))
