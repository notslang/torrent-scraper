FROM mhart/alpine-node:base-7
MAINTAINER Sean Lang <slang800@gmail.com>
VOLUME ["/data"]
WORKDIR /app
COPY build .
ENTRYPOINT ["node", "lib/index.js"]
