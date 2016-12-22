BPromise = require 'bluebird'
amqp = require 'amqplib'
fetch = require 'node-fetch'
fs = require 'fs'
map = require 'through2'
pumpCb = require 'pump'
{ArgumentParser} = require 'argparse'

packageInfo = require '../package'

pump = BPromise.promisify(pumpCb)

argparser = new ArgumentParser(
  version: packageInfo.version
  addHelp: true
  description: packageInfo.description
)
argparser.addArgument(
  ['--out']
  defaultValue: '/data'
  help: 'Download directory, defaults to "/data".'
  type: 'string'
)
argparser.addArgument(
  ['--prefetch']
  defaultValue: 100
  help: 'How many hashes to fetch from AMQP and keep in memory waiting to' +
  'download. Defaults to 100.'
  type: 'int'
)
argparser.addArgument(
  ['--concurrency']
  defaultValue: 12
  help: 'How many HTTP requests to make at once. Defaults to 12.'
  type: 'int'
)
argparser.addArgument(
  ['server']
  help: 'Address of the AMQP server, for example: ' +
  '"username:password@localhost".'
  type: 'string'
  metavar: "AMQP_SERVER"
)

argv = argparser.parseArgs()

FAKE_404_URLS = [
  'http://itorrents.org/404.php?reason=&title='
  'https://www.limetorrents.cc/'
]
SOFT_NETWORK_ISSUES = ['ETIMEDOUT', 'EAI_AGAIN', 'ECONNRESET', 'EHOSTUNREACH']

checkStatus = (response) ->
  if response.status >= 200 and response.status < 300 and
     response.url not in FAKE_404_URLS
    return response
  else
    if response.url in FAKE_404_URLS
      # fake 404 :(
      error = new Error("Not Found")
      error.response =
        status: 404
        statusText: "Not Found"
    else
      error = new Error(response.statusText)
      error.response = response

    throw error
  return

channel = undefined

makeQueue = ->
  map(objectMode: true, (msg, enc, cb) ->
    infoHash = msg.content.toString()
    timeAdded = null
    timeRetrieved = null
    BPromise.resolve(
      fetch("http://itorrents.org/torrent/#{infoHash}.torrent", redirect: 'error')
    ).timeout(
      30000
    ).then(
      checkStatus
    ).then((res) ->
      timeAdded = +(new Date(res.headers.get('last-modified'))) / 1000
      timeRetrieved = Date.now() / 1000
      pump(
        res.body
        fs.createWriteStream("#{argv.out}/#{infoHash}.torrent")
      )
    ).then( ->
      console.log JSON.stringify({
        infoHash
        result: 'success'
        timeAdded
        timeRetrieved
      })
      channel.ack msg
      cb()
    ).catch((err) ->
      if (err.name is 'FetchError' and err.type is 'no-redirect') or
         err.response?.status is 404
        console.log JSON.stringify({
          infoHash
          result: '404-no-retry'
        })
        channel.nack(msg, false, false)
        cb()
      else if not err.response? and err.code not in SOFT_NETWORK_ISSUES and
              err not instanceof BPromise.TimeoutError
        console.error err
        process.exit(1)
      else
        errorCode = (
          if err instanceof BPromise.TimeoutError then 'TIMEOUT' else err.code
        )
        console.log JSON.stringify({
          infoHash
          result: 'retry'
          errorCode
        })
        console.error err
        channel.nack(msg)
        cb()
    )
  )

queues = (makeQueue() for i in [0...argv.concurrency])
i = 0

amqp.connect("amqp://#{argv.server}").then((conn) ->
  conn.createChannel()
).then((ch) ->
  channel = ch
  BPromise.all([
    ch.assertExchange('torrents.dead.fanout', 'fanout', durable: true)
    ch.assertExchange('torrents.fanout', 'fanout', durable: true)
    ch.assertQueue(
      'torrent.dead'
      durable: true
      messageTtl: 1000 * 60 * 60 * 24 * 30 # 1 month
      deadLetterExchange: 'torrents.fanout'
    )
    ch.bindQueue('torrent.dead', 'torrents.dead.fanout')
    ch.assertQueue(
      'torrents'
      durable: true
      deadLetterExchange: 'torrents.dead.fanout'
    )
    ch.bindQueue(
      'torrents', 'torrents.fanout'
    )
    ch.prefetch(argv.prefetch)
    ch.consume('torrents', (msg) ->
      i += 1
      queues[i % argv.concurrency].write(msg)
    )
  ])
).then(null, console.warn)
