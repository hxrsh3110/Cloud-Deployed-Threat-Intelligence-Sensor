# Architecture Overview
This project utilizes a lightweight, containerized approach to capture unauthorized access attempts using a simulated SSH service.

## Cloud Infrastructure
Hosted on an AWS EC2 t2.micro instance running Ubuntu 24.04 LTS. Security groups are configured to strictly limit administrative SSH (Port 22) to a dedicated IP address, while leaving the honeypot listener (Port 2222) open to the public internet. To maintain operational efficiency, the instance utilizes a Stop/Start lifecycle rather than full termination, preserving the compiled architecture and threat data on the EBS volume between sessions.

## Containerization 
The environment is isolated using Docker. It is built upon a minimal node:alpine image and runs in detached mode, safely mapping the exposed port 2222 from the host into the container. Crucially, the container utilizes a bind-mount volume (-v) to decouple the application code from the data layer. This bridges the container's internal log directory directly to the Ubuntu host filesystem, ensuring log data persists even if the container crashes or is rebuilt.

## Application Logic 
A custom Node.js TCP server acts as the trap. When an automated scanner or attacker connects to port 2222, the application sanitizes the network data by stripping IPv4-mapped IPv6 prefixes (::ffff:). It captures the clean IP address, appends a standardized ISO timestamp, and writes it to disk using robust absolute pathing to prevent directory resolution errors. The script then serves a fake Ubuntu login banner to stall the attacker before aggressively terminating the connection after two seconds to conserve server memory and prevent resource exhaustion.

## Data Extraction 
Because the system utilizes a persistent volume mount, threat intelligence is extracted directly from the host machine rather than bridging into the container. Administrators can natively parse, sort, and identify the most frequent offending IP addresses by reading the threat-logs.txt file directly from their home directory using standard Linux utilities like cat, grep, and tail. 

## Deployment Runbook

### Phase 1: AWS Infrastructure Provisioning
1.	Log into AWS Management Console -> EC2 Dashboard -> Launch Instance.
2.	Base Image (AMI) -> OS: Ubuntu 24.04 LTS.
3.	Compute Tier (Instance Type) : t2.micro.
4.	Key Pair: Assign your pre-configured administrative key pair
5.	Perimeter Firewalls (Security Groups): Configure the network stack 	with the following inbound rules:
   	Rule 1 (Admin Management): SSH | Port 22 | Source: My IP (Administrative Access).
   	Rule 2 (Public Intake): Custom TCP | Port 2222 | Source: Anywhere - 0.0.0.0/0 (Honeypot Trap).
6.	Click Launch. Copy the new Public IPv4 Address.

### Phase 2: Perimeter Access / Edge Connectivity
1.	Launch your local WSL environment or native Linux terminal.
2.	Ensure the private key has strict permissions (only required once per machine):
```bash
chmod 400 ~/.ssh/xyz-server-key.pem
```
3.	Establish an authenticated SSH management session to the cloud infrastructure:
```bash
ssh -i ~/.ssh/xyz-server-key.pem ubuntu@<NEW_AWS_PUBLIC_IP>
```

### Phase 3: Insfrastructure Provisioning & Deployment
1.	Synchronize local package indexes and provision core containerization and version control tooling:
```bash
sudo apt update && sudo apt install docker.io git -y
```
2.	Clone the project repository directly onto the cloud instance filesystem and step into the project root:
```bash
git clone <YOUR_GITHUB_REPO_URL>
cd Cloud-Deployed-Threat-Intelligence-Sensor
```

3.	Compile the container configuration blueprint into a local, immutable Docker image:
```bash
sudo docker build -t threat-honeypot .
```

4.	Instantiate the containerized process with integrated network binding and continuous log volume mapping:
```bash
sudo docker run -d --name live-trap -p 2222:2222 -v $HOME/honeypot-logs:/app/logs threat-honeypot
```

### Phase 4: Telemetry Aggregation & Data Analysis
1.	Verify that the core engine is up, functional, and actively listening for network connections:
```bash
sudo docker logs live-trap
```
2.	Because data layers are bind-mounted directly to the host machine workspace (~/honeypot-logs), you do not need to drop into the container to review telemetry. Analyze, filter, and aggregate malicious threat vectors using native host strings:
```bash
cat ~/honeypot-logs/threat-logs.txt | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | sort | uniq -c | sort -nr
```
3. To monitor incoming threat attacks live as they hit the network perimeter interface, stream the file descriptor output directly:
```bash
tail -f ~/honeypot-logs/threat-logs.txt
```
4.  If your ultimate goal is to copy that log file from the cloud server down to your local machine for offline analysis, you don't use cat. You use Secure Copy (scp) from your local linux terminal:
```bash
scp -i ~/.ssh/xyz-server-key.pem ubuntu@<YOUR_AWS_PUBLIC_IP>:~/honeypot-logs/threat-logs.txt ~/honeypot-logs/
```

 ## System Maintenance Cycle (Next-DayLifecycle Procedure)
To keep costs low while maintaining architecture state, follow this cycle instead of destroying your virtual machine assets completely.

### Lifecycle Start Routine (When resuming development)
1. Log into your AWS Management Console, select your stopped honeypot instance, and change the instance state to Start.

2. Network Alignment: Because public cloud IP addresses cycle on boot, copy the brand new Public IPv4 Address from your console interface.

3. Firewall Update: Navigate to Security Groups, select your project group, and edit inbound rules. Update Rule 1 (Port 22) to your current My IP location to maintain administrative tunnel access.

4. Tunnel back into the cloud instance:
```bash
ssh -i ~/.ssh/xyz-server-key.pem ubuntu@<NEW_AWS_PUBLIC_IP>
```
5. Re-initialize your pre-configured, data-mapped engine container without building any assets from scratch:
```bash
sudo docker start live-trap
```
### Lifecycle Standby Routine (When finishing your work shift)
1. Exit your active SSH tunnel terminal interface.

2. Log into your AWS Management Console, locate your instance, and select Stop Instance.

3. Note: The system stops generating compute costs, while your underlying configuration, Docker environments, code, and threat telemetry profiles remain securely written to persistent disk for less than $1.00 USD per month.