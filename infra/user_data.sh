#!/bin/bash
set -euxo pipefail

# --- Log everything this script does to a file you can inspect later ---
exec > /var/log/user-data.log 2>&1

# --- Install Docker, git, and unzip (needed for the AWS CLI v2 installer below) ---
apt-get update
apt-get install -y docker.io git unzip

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

# --- Install AWS CLI v2, so the instance can push logs to S3 ---
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws/

# --- Ship threat-logs.txt to S3 every 5 minutes, riding on the same crontab as the health check ---
# Credentials come from the instance profile automatically, no aws configure needed.
(crontab -l -u ubuntu 2>/dev/null; echo "*/5 * * * * /usr/local/bin/aws s3 cp /home/ubuntu/honeypot-logs/threat-logs.txt s3://honeypot-logs-hxrsh3110-eu-north-1/threat-logs.txt --only-show-errors") | crontab -u ubuntu -

# --- Give ssm-user group access to ubuntu's files and docker, so SSM sessions don't need sudo for routine work ---
for i in {1..12}; do
  if id ssm-user &>/dev/null; then
    usermod -aG ubuntu,docker ssm-user
    break
  fi
  sleep 5
done
chmod -R g+rwX /home/ubuntu/Cloud-Deployed-Threat-Intelligence-Sensor
find /home/ubuntu/Cloud-Deployed-Threat-Intelligence-Sensor -type d -exec chmod g+s {} \;
chmod -R g+rwX /home/ubuntu/honeypot-logs
find /home/ubuntu/honeypot-logs -type d -exec chmod g+s {} \;
sudo -u ssm-user git config --global --add safe.directory /home/ubuntu/Cloud-Deployed-Threat-Intelligence-Sensor