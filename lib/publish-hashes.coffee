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
  ['--amqp-server']
  defaultValue: 'localhost'
  dest: 'amqpServer'
  help: 'Address of the AMQP server, defaults to localhost.'
  type: 'string'
)
argparser.addArgument(
  ['--username']
  defaultValue: 'torrent-scraper'
  dest: 'user'
  help: 'RabbitMQ username, defaults to "torrent-scraper".'
  type: 'string'
)
argparser.addArgument(
  ['--password']
  dest: 'pass'
  help: 'RabbitMQ password.'
  required: true
  type: 'string'
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
serverUrl = "amqp://#{argv.user}:#{argv.pass}@#{argv.amqpServer}"
amqp.connect(serverUrl).then((connection) ->
  conn = connection
  conn.createConfirmChannel()
).then((ch) ->
  ch.assertExchange('torrents.dead.fanout', 'fanout', durable: true)
  ch.assertQueue('torrents.dead', durable: true)
  ch.bindQueue('torrents.dead', 'torrents.dead.fanout')
  ch.assertQueue(
    'torrents'
    durable: true
    deadLetterExchange: 'torrents.dead.fanout'
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
