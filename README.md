# torrent scraper

A little tool for scraping torrents in bulk, using RabbitMQ for task distribution and Docker for deploying the scraper to Kubernetes. Right now it only uses itorrents.org, but in the future should be expanded to fetch from other caches & the DHT.

## why?

Downloading torrents via HTTP is vastly faster than discovering them and doing oppurtunistic scraping via the DHT alone. Plus, you get to collect all the dead torrents. This is, of course, nearly useless for actually getting the content described by those dead torrents, since if it's not on the DHT then it probably doesn't exist in the network. However, collecting torrents in bulk does let you construct a rough historical record of the BitTorrent network and learn a lot about how it's used.

## how?

Torrent caching sites sometimes rate-limit your requests, or ban particular IPs, so I use a distributed network of scrapers. These run on whatever VPS providers are the cheapest and on servers that I have to run for other applications. The scraper itself is self-contained in a 40MB Docker image, uses very little CPU-time and torrent files are tiny. So I run these almost everywhere.

RabbitMQ is in charge of telling the scrapers what URLs to try. This uses less than 100kB/sec bandwidth for AMQP communication with all the scrapers, so it can be hosted on a cheap residential connection. Having a backlog of ~40 million persistent messages in RabbitMQ can take up more than 30GB of disk space, so using your own server with cheap disks is preferable to paying a VPS provider for storage.

Retries are also handled by RabbitMQ. There are two queues:

- `itorrents.org-scraper` - holds the messages ready to be sent to scrapers and dead-letters to `itorrents.org-scraper.dead`
- `itorrents.org-scraper.dead` - holds messages representing failed requests and dead-letters to `itorrents.org-scraper`

Since they're tied together in a loop, `nack`ing a message in `itorrents.org-scraper.dead` will queue it up to be retried. The script at `lib/nack.coffee` handles this automatically. You could also handle this by setting a [`message-ttl` policy](https://www.rabbitmq.com/ttl.html) on the `itorrents.org-scraper.dead` queue, but this can be inconsistent if you start and stop your scrapers frequently.

The `itorrents.org-scraper` queue should be kept nearly empty so newly published hashes don't need to wait before being tried.

To publish messages, pipe a newline demimited list of info-hashes to the `lib/publish-hashes.coffee` script. I usually sort this list randomly so the traffic that the scrapers produce doesn't look sequential and obvious:

```bash
cat ./uploadlist | sort -R | coffee lib/publish-hashes.coffee username:password@server-address
```

You should take steps to ensure you don't publish duplicate info-hashes because there is no good way to deduplicate messages within RabbitMQ.

## can I buy a copy of your dataset?

Sure, contact me via [email](mailto:slang800@gmail.com) and I can send you a hard drive. The collection is about 20 million torrent files, with an average filesize of 36kB, stored on a btrfs disk. Basic deduplication is done in order to find places where the torrent cache being scraped has returned something obviously incorrect (like an empty file or an HTML page), but corrupt torrent files are kept and just retried. Download times and `last-modified` headers are logged for most of them, but this is just basic logging intended for debugging. I'm not storing them in a WARC, so I don't keep full records of headers or failed requests.

Costs cover buying the hard drive, shipping, and recuperation of some server costs.
