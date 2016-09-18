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
  ['server']
  help: 'Address of the AMQP server, for example: ' +
  '"username:password@localhost".'
  type: 'string'
  metavar: "AMQP_SERVER"
)

argv = argparser.parseArgs()

FAKE_404_URL = 'http://itorrents.org/404.php?reason=&title='

checkStatus = (response) ->
  if response.status >= 200 and response.status < 300 and
     response.url isnt FAKE_404_URL
    return response
  else
    if response.url is FAKE_404_URL
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
    fetch("http://itorrents.org/torrent/#{infoHash}.torrent").then(
      checkStatus
    ).then((res) ->
      timeAdded = +(new Date(res.headers.get('last-modified'))) / 1000
      timeRetrieved = Date.now() / 1000
      pump(
        res.body
        fs.createWriteStream("#{argv.out}/#{infoHash}.torrent")
      )
    ).then( ->
      console.log 'got:', JSON.stringify({infoHash, timeAdded, timeRetrieved})
      channel.ack msg
      cb()
    ).catch((err) ->
      if not err.response? and
         err.code not in ['ETIMEDOUT', 'EAI_AGAIN', 'ECONNRESET']
        console.error err
        process.exit(1)
      else if err.response.status is 404
        console.log 'err 404 (no retry):', infoHash
        channel.nack(msg, false, false)
        cb()
      else
        console.log 'err (retrying):', infoHash, err
        channel.nack(msg)
        cb()
    )
  )

queues = [
  makeQueue()
  makeQueue()
  makeQueue()
  makeQueue()
  makeQueue()
  makeQueue()
  makeQueue()
  makeQueue()
  makeQueue()
  makeQueue()
  makeQueue()
  makeQueue()
]
queuesLength = queues.length
i = 0

amqp.connect("amqp://#{argv.server}").then((conn) ->
  conn.createChannel()
).then((ch) ->
  channel = ch
  BPromise.all([
    ch.assertExchange('torrents.dead.fanout', 'fanout', durable: true)
    ch.assertQueue('torrents.dead', durable: true)
    ch.bindQueue('torrents.dead', 'torrents.dead.fanout')
    ch.assertQueue(
      'torrents',
      durable: true,
      deadLetterExchange: 'torrents.dead.fanout'
    )
    ch.prefetch(20)
    ch.consume('torrents', (msg) ->
      i += 1
      queues[i % queuesLength].write(msg)
    )
  ])
).then(null, console.warn)