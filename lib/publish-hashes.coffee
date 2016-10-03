Transform = require 'concurrent-transform-stream'
amqp = require 'amqplib'
pump = require 'pump'
split = require 'binary-split'
{ArgumentParser} = require 'argparse'

packageInfo = require '../package'

HASH_RE = /[A-Z0-9]{40}/

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
      @ch.sendToQueue('torrents', line, persistent: true, cb)

conn = undefined
amqp.connect("amqp://#{argv.server}").then((connection) ->
  conn = connection
  conn.createConfirmChannel()
).then((ch) ->
  ch.assertExchange('torrents.dead.fanout', 'fanout', durable: true)
  ch.assertExchange('torrents.fanout', 'fanout', durable: true)
  ch.assertQueue(
    'torrents.dead'
    durable: true
    messageTtl: 1000 * 60 * 60 * 24 * 7 # 1 week
    deadLetterExchange: 'torrents.fanout'
  )
  ch.bindQueue('torrents.dead', 'torrents.dead.fanout')
  ch.assertQueue(
    'torrents'
    durable: true
    deadLetterExchange: 'torrents.dead.fanout'
  )
  ch.bindQueue(
    'torrents', 'torrents.fanout'
  ).then( ->
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
