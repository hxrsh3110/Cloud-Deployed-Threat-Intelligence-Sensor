#!/bin/bash
set -euxo pipefail

# --- Log everything this script does to a file you can inspect later ---
exec > /var/log/user-data.log 2>&1

# --- Install Docker and git ---
apt-get update
apt-get install -y docker.io git

# --- Let the ubuntu user run docker without sudo ---
usermod -aG docker ubuntu

# --- Prep the log directory with the right ownership BEFORE the container ever writes to it ---
mkdir -p /home/ubuntu/honeypot-logs
chown -R 1000:1000 /home/ubuntu/honeypot-logs

# --- Clone and build ---
cd /home/ubuntu
git clone https://github.com/hxrsh3110/Cloud-Deployed-Threat-Intelligence-Sensor.git
chown -R ubuntu:ubuntu /home/ubuntu/Cloud-Deployed-Threat-Intelligence-Sensor
cd Cloud-Deployed-Threat-Intelligence-Sensor
docker build -t threat-honeypot .

# --- Run it ---
docker run -d --name live-trap --restart unless-stopped \
  -p 2222:2222 \
  -v /home/ubuntu/honeypot-logs:/app/logs \
  threat-honeypot

# --- Set up the health check cron job too, while we're closing the manual-step gap ---
# (adjust this if health-check.sh isn't at repo root)
chmod +x /home/ubuntu/Cloud-Deployed-Threat-Intelligence-Sensor/health-check.sh
(crontab -l -u ubuntu 2>/dev/null; echo "*/5 * * * * /home/ubuntu/Cloud-Deployed-Threat-Intelligence-Sensor/health-check.sh") | crontab -u ubuntu -