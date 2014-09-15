SphereClient = require 'sphere-node-client'
{Logger} = require 'sphere-node-utils'
AvailabilityService = require '../../lib/service/availability'
package_json = require '../../package.json'
Config = require '../../config'

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

  it 'should generate summary report', ->
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
    'Summary: 8 synced / 2 failed from 10 / 10 products. (Events from 25 variants: ADD[5], CHANGE[10], REMOVE[2], NOT_NEEDED[8])'

