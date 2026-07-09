FROM node:20-alpine
WORKDIR /app
COPY honeypot.js .
RUN apk update && apk upgrade --no-cache libssl3 libcrypto3 && \
    rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
           /opt/yarn-v*
USER node
ENTRYPOINT [ "node", "honeypot.js" ]