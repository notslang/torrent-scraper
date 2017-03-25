Transform = require 'concurrent-transform-stream'
amqp = require 'amqplib'
pump = require 'pump'
split = require 'binary-split'
{ArgumentParser} = require 'argparse'

packageInfo = require '../package'

HASH_RE = /[A-Z0-9]{40}/
QUEUE_NAME = 'itorrents.org-scraper'

argparser = new ArgumentParser(
  version: packageInfo.version
  addHelp: true
  description: packageInfo.description
)
argparser.addArgument(
  ['server']
  help: 'Address of the AMQP server, for example: ' +
  '"username:password@localhost".'
  type: 'string'
  metavar: "AMQP_SERVER"
)

argv = argparser.parseArgs()

class PublishStream extends Transform
  constructor: (@ch) ->
    super(objectMode: true)

  _transform: (line, encoding, cb) =>
    hash = line.toString()
    if not HASH_RE.test(hash)
      console.error '\nbad hash:', hash
      cb()
    else
      process.stdout.write('.')
      @ch.sendToQueue(QUEUE_NAME, new Buffer(hash, 'hex'), persistent: true, cb)

conn = undefined
amqp.connect("amqp://#{argv.server}").then((connection) ->
  conn = connection
  conn.createConfirmChannel()
).then((ch) ->
  ch.assertExchange("#{QUEUE_NAME}.dead.fanout", 'fanout', durable: true)
  ch.assertExchange("#{QUEUE_NAME}.fanout", 'fanout', durable: true)
  ch.assertQueue(
    "#{QUEUE_NAME}.dead"
    durable: true
    deadLetterExchange: "#{QUEUE_NAME}.fanout"
  )
  ch.bindQueue("#{QUEUE_NAME}.dead", "#{QUEUE_NAME}.dead.fanout")
  ch.assertQueue(
    QUEUE_NAME
    durable: true
    deadLetterExchange: "#{QUEUE_NAME}.dead.fanout"
  )
  ch.bindQueue(QUEUE_NAME, "#{QUEUE_NAME}.fanout").then( ->
    pump(
      process.stdin
      split()
      (new PublishStream(ch))
      (err) ->
        if err? then console.error(err)
        conn.close()
    )
  )
).then(null, console.warn)
