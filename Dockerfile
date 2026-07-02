FROM node:alpine
WORKDIR /app
COPY honeypot.json .
ENTRYPOINT [ "node", "honeypot.js" ]