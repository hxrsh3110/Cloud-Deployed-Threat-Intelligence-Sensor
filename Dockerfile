FROM node:alpine
WORKDIR /app/logs
COPY honeypot.js .
ENTRYPOINT [ "node", "honeypot.js" ]