{SphereClient} = require 'sphere-node-sdk'
{Logger, ProjectCredentialsConfig} = require 'sphere-node-utils'
package_json = require '../package.json'
AvailabilityService = require './service/availability'

argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret --logDir dir --logLevel level --timeout timeout')
  .describe('projectKey', 'your SPHERE.IO project-key')
  .describe('clientId', 'your SPHERE.IO OAuth client id')
  .describe('clientSecret', 'your SPHERE.IO OAuth client secret')
  .describe('attributeName', 'the name of the product attribute to sync')
  .describe('withInventoryCheck', 'whether to check availability directly from inventory entries instead of variant availability (use careful, it may affect performances)')
  .describe('timeout', 'timeout for requests')
  .describe('sphereHost', 'SPHERE.IO API host to connecto to')
  .describe('logLevel', 'log level for file logging')
  .describe('logDir', 'directory to store logs')
  .default('attributeName', 'isOnStock')
  .default('withInventoryCheck', false)
  .default('timeout', 60000)
  .default('logLevel', 'info')
  .default('logDir', '.')
  .demand(['projectKey'])
  .argv

logger = new Logger
  name: "#{package_json.name}-#{package_json.version}"
  streams: [
    { level: 'error', stream: process.stderr }
    { level: argv.logLevel, path: "#{argv.logDir}/#{package_json.name}.log" }
  ]

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
  options.host = argv.sphereHost if argv.sphereHost?

  client = new SphereClient options
  availability = new AvailabilityService client, logger,
    withInventoryCheck: argv.withInventoryCheck
    attributeName: argv.attributeName

  availability.run()
  .then =>
    availability.sendMetrics()
    logger.info availability.getSummaryReport()
    @exitCode = 0
  .catch (error) =>
    logger.error error, 'Oops, something went wrong!'
    @exitCode = 1
  .done()
.catch (error) =>
  logger.error error, 'Problems on getting client credentials from config files.'
  @exitCode = 1
.done()
