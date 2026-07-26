#!/bin/bash
if [ ! "$(docker ps -q -f name=live-trap)" ]; then
    echo "$(date): ALERT - live-trap is DOWN" >> ~/honeypot-logs/health.log
else
    echo "$(date): OK - live-trap is UP" >> ~/honeypot-logs/health.log
    curl -fsS -m 10 --retry 3 https://hc-ping.com/99a0c39a-2c34-441c-83d7-214f82cb344b > /dev/null
fi