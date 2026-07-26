# SSH Honeypot on AWS EC2

A small Node.js TCP server that pretends to be an SSH login prompt, logs whoever connects, and keeps that log even if the container gets rebuilt or the box reboots. As of this update, the entire server, not just the app inside it, provisions and boots itself from Terraform with no manual SSH setup required, and management access no longer depends on SSH at all.

This README describes what the project actually does right now, not what it might do someday. Anything not built yet is listed at the bottom under Known Gaps instead of being dressed up as done.

## What it does

The server listens on port 2222. When anything connects, it:

1. Grabs the connecting IP address and strips the `::ffff:` prefix that shows up on dual-stack listeners, so you get a clean IPv4 address in the log instead of a mangled one.
2. Sends back a fake Ubuntu login banner and a `login:` prompt.
3. Waits for the attacker to type a username, then prompts for a password, and waits for that too. Both fields are sanitized (control characters stripped, length capped) before anything gets logged.
4. Logs the IP, username, password, and a status (`complete` if both fields came through, `timeout` if the connection sat idle past 15 seconds without finishing) to `threat-logs.txt`.
5. Sends a fake "Login incorrect" and closes the connection.

It still doesn't run a fake shell or accept further commands after the password prompt, so it's a credential-capturing front door, not a full interactive trap like Cowrie.

One thing worth knowing if you're reading the raw log file: entries logged before an earlier update use the old plain format (`Unauthorized access attempt from: <ip>`), entries after use the current `IP | Username | Password | Status` format. The `grep`-based IP extraction below works on both since it just matches IP patterns regardless of the rest of the line, but anything that parses the full line structure needs to account for the format change.

## Why the logs survive container restarts

Containers are throwaway by design. Anything written to a container's own filesystem disappears when the container is removed. To avoid losing data every time the app gets rebuilt or redeployed, the log file lives outside the container, on the host, and gets mounted in:

```bash
-v /home/ubuntu/honeypot-logs:/app/logs
```

The app writes to an absolute path (`/app/logs/threat-logs.txt`) that matches this mount, not a relative path that depends on whatever the working directory happens to be at runtime.

**This does not survive an instance replacement.** The log directory lives on the instance's root EBS volume. If the instance is destroyed and recreated, for any reason, an AMI change, an instance type change, a `user_data` change, that volume goes with it, and every log collected so far goes with it too. This bit the project directly during the SSM migration below; the only reason no data was lost is that logs were manually backed up with `scp` before applying the change. See Known Gaps.

## Why it doesn't run as root

The container drops root privileges and runs as the built-in `node` user (UID 1000) from the `node:20-alpine` image, via `USER node` in the Dockerfile. A process that's intentionally sitting open to the entire internet shouldn't also have root inside its own container.

One consequence of this that isn't obvious until you hit it: the host directory being mounted in has to be writable by UID 1000, not just by root. The current `infra/user_data.sh` handles this automatically at boot (`chown -R 1000:1000` on the log directory before the container ever starts), so this is no longer a manual step, but if you ever recreate the log directory by hand outside of Terraform, run:

```bash
sudo chown -R 1000:1000 ~/honeypot-logs
```

If you skip this, the app won't crash, it'll just silently fail every write and print `Failed to save log.` to `docker logs` while the container looks perfectly healthy.

## Image hardening

The base image is pinned to `node:20-alpine` instead of the floating `node:alpine` tag, so a rebuild months from now starts from the same major version instead of whatever "latest" happens to mean by then.

The image also strips out `npm`, `npx`, `corepack`, and `yarn` at build time. The app has zero dependencies, it only uses Node's built-in `net`, `fs`, and `path` modules, so none of that tooling is ever invoked at runtime, it's just dead weight bundled into the base image by default. Removing it isn't just cosmetic, a CI scan flagged real CVEs living inside npm's own internal dependencies, none of them reachable by this app, but rather than exclude them from the scan, they're just not in the image anymore. The build also explicitly upgrades `libssl3`/`libcrypto3` at build time to pull in the current patched versions from Alpine's package repo, since a real OpenSSL CVE was flagged in the base OS layer on the first scan.

## CI: automated build and vulnerability scan

Every push to `main` triggers a GitHub Actions workflow (`.github/workflows/docker-scan.yml`) that builds the Docker image and scans it with [Trivy](https://trivy.dev). If it finds a CRITICAL or HIGH severity vulnerability, the workflow fails outright, it's a gate, not a report nobody reads.

Worth being clear about what this does and doesn't cover: it only runs when code gets pushed to GitHub. It does not run continuously against the live instance, and it does not auto-deploy anything, rebuilding and redeploying on the server is still triggered manually (either by re-running Terraform for a full instance replacement, or by pulling and rebuilding in place, see Deployment below).

## Infrastructure as Code

The AWS side, the security group, the EC2 instance, the Elastic IP, and the IAM role/instance profile used for access, is tracked in Terraform under `infra/main.tf`. The instance and security group weren't built from Terraform originally, the infrastructure existed from manual console setup first, so it was brought under Terraform with `terraform import`, which tells Terraform "this resource already exists with this ID, track it instead of creating something new."

The first `terraform plan` after importing showed real drift: the security group's actual name (`launch-wizard-7`, an AWS-generated default from the original console setup, never renamed) and description didn't match what was first written into the file, and one ingress rule had the wrong source IP entirely. The file was corrected to match reality instead of applying, and `terraform plan` was re-run until it reported "No changes. Your infrastructure matches the configuration."

### The instance now provisions itself

`aws_instance.honeypot` includes a `user_data` script (`infra/user_data.sh`) that runs automatically the first time the instance boots. It installs Docker and git, clones the repo, builds the image, starts the container, and sets up the health-check cron job, all without anyone SSHing in to type commands by hand. `user_data_replace_on_change = true` is set explicitly, spelling out that changing this script forces a full instance replacement rather than an in-place update, since that's the AWS provider's actual default behavior and it's better documented than left implicit.

Two things worth knowing about how this was validated, not just written and assumed correct:

- The first real run surfaced a gap the script's author didn't know was there: `health-check.sh`, described in this README's monitoring section as already built, had in fact never been committed to the repository. It existed only on the original, manually-configured instance. The automated bootstrap failed at that exact step (the script uses `set -euxo pipefail`, so it stopped cleanly rather than continuing in a half-broken state), which is what caught the gap. The file has since been committed and the bootstrap now completes end to end.
- Access to the instance during and after this migration moved off SSH entirely, see the next section, which meant discovering and fixing a chain of ownership and permission mismatches between the `ubuntu` user (which owns everything `user_data` creates) and `ssm-user` (the account SSM sessions log in as). `user_data.sh` now grants `ssm-user` group access to both Docker and the project directory at boot, so this doesn't have to be fixed by hand again after the next replacement.

### Access moved from SSH to AWS Systems Manager (SSM)

The original security group allowed SSH from a single hardcoded IP (`cidr_blocks = ["<ip>/32"]`). That's a real problem for a laptop that connects over a mobile hotspot: the IP changes, and a hardcoded rule locks you out the moment it does, with no way back in except editing the security group from a session that's already locked out.

Rather than widen that rule (which would mean opening SSH to the whole internet, undermining the entire point of hardening this project), management access moved to SSM Session Manager instead:

- An IAM role (`aws_iam_role.ssm_role`) with the `AmazonSSMManagedInstanceCore` policy is attached to the instance via an instance profile.
- The port 22 ingress rule was removed from the security group entirely. It no longer exists, there is no SSH access to this instance, from any IP.
- Connecting now uses:

```bash
aws ssm start-session --target <instance-id>
```

This requires the AWS CLI and the Session Manager plugin installed locally, and valid AWS credentials configured (`aws configure`), but it does not depend on the connecting machine's IP address at all, so a rotating hotspot IP is no longer a problem.

What this doesn't cover: file transfer. `scp` still needs an actual SSH connection, which no longer exists. Pulling `threat-logs.txt` off the box now requires either an SSM port-forwarding session tunneling a local SSH connection, or a different transfer method (S3 upload, for instance), not yet decided.

`infra/terraform.tfstate` and `infra/.terraform/` are gitignored and never pushed, since state files can contain sensitive detail about the real infrastructure. Only `main.tf`, `user_data.sh`, `.gitignore`, and the provider lock file are meant to be committed.

## Monitoring

A cron job runs `health-check.sh` every 5 minutes, checks whether the `live-trap` container is up, and logs the result to `~/honeypot-logs/health.log`. On every healthy check it also pings a [healthchecks.io](https://healthchecks.io) endpoint. If that ping goes silent for longer than the configured period plus grace window, healthchecks.io sends an email automatically. This is what actually closes the loop, a log file nobody reads isn't a monitor, an external service that notices your silence is.

Current settings: 10 minute period, 5 minute grace, so a real outage takes up to about 15 minutes to trigger an email.

As of this update, `health-check.sh` is committed to the repository and installed automatically by `user_data.sh` on boot. Previously it existed only as a manually-created file on the original instance and was never version-controlled, a gap that only surfaced once the instance was actually rebuilt from scratch and the file wasn't there to find.

## Deployment

### 1. Launch the EC2 instance

Provisioning the instance, security group, Elastic IP, and IAM role/instance profile is handled by Terraform (`infra/main.tf`), including the `user_data` bootstrap. A fresh instance requires no manual SSH steps to get the honeypot running, Terraform and cloud-init handle it end to end.

Security group inbound rules:
- Port 2222 (honeypot), source: anywhere
- No SSH ingress rule. Management access is via AWS SSM Session Manager, not SSH.

### 2. Connect

```bash
aws ssm start-session --target <instance-id>
```

### 3. Verify it's actually working

Don't trust that it's fine just because the console shows the instance as running. Actually check:

```bash
docker logs live-trap
```

Look for `Failed to save log.`, if you see it, it's a permissions problem. If it's clean, trigger a real connection from a different network than the server itself is on, then confirm the log actually grew:

```bash
nc <PUBLIC_IP> 2222
tail -1 /home/ubuntu/honeypot-logs/threat-logs.txt
```

## Reading the logs

Most frequent attacker IPs:

```bash
cat /home/ubuntu/honeypot-logs/threat-logs.txt | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | sort | uniq -c | sort -nr
```

Watch it live:

```bash
tail -f /home/ubuntu/honeypot-logs/threat-logs.txt
```

## Pausing and resuming the project

Stopping the instance instead of terminating it keeps the disk, the docker setup, and the logs intact for less than a dollar a month in storage. With the Elastic IP attached, the public address doesn't change across a stop/start.

**To pause:**

```bash
aws ssm start-session --target <instance-id>
docker stop live-trap
# then stop the instance from the AWS console
```

**To resume**, pull the latest code before rebuilding rather than assuming what's on the server is current:

```bash
# on AWS console: start the instance
aws ssm start-session --target <instance-id>

git -C /home/ubuntu/Cloud-Deployed-Threat-Intelligence-Sensor pull origin main
cd /home/ubuntu/Cloud-Deployed-Threat-Intelligence-Sensor
docker build -t threat-honeypot .
docker stop live-trap && docker rm live-trap
docker run -d --name live-trap --restart unless-stopped \
  -p 2222:2222 \
  -v /home/ubuntu/honeypot-logs:/app/logs \
  threat-honeypot

docker logs live-trap
```

Then, from a separate terminal on your own machine:

```bash
nc <PUBLIC_IP> 2222
```

and back in the SSM session:

```bash
tail -1 /home/ubuntu/honeypot-logs/threat-logs.txt
```

## Known gaps

Being upfront about what's not done, instead of implying it is:

- **Logs still don't survive an instance replacement.** They live on the instance's root EBS volume, not in S3 or a separate persistent volume. Every replacement (an AMI change, an instance type change, another `user_data` edit) wipes them unless they're manually backed up first. This is the single biggest remaining risk in the project, not a nice-to-have.
- **File transfer off the instance has no clean path anymore.** SSH is gone, and with it, `scp`. Pulling logs now requires an SSM port-forwarding tunnel or a different transfer method entirely, not yet built.
- **A documented monitoring script wasn't actually in version control.** `health-check.sh` was described in this README as already built, but existed only on the original, manually-configured instance and was never committed. It was only caught because the instance was fully rebuilt from Terraform and the automated bootstrap failed on a missing file instead of silently working around it. It's fixed now, but it's a more honest and specific gap than "installing Docker is still manual" ever was, and worth remembering as a category of risk: infrastructure-as-code only covers what actually got committed, not what the docs claim exists.
- **CI builds and scans, but doesn't deploy.** The pipeline catches vulnerabilities before they'd ship, but getting a rebuilt image onto the actual running instance is still a manual step or a full Terraform-triggered replacement.
- **No fake shell after login.** Credentials are captured, but the connection ends right after, there's no simulated filesystem or command interpreter to see what an attacker would try next if they thought they were in.
- **Monitoring has a real blind spot.** The health check relies on cron running at all. If cron itself dies, or the whole instance goes down, the healthchecks.io grace window still catches it eventually because silence itself is the alert condition, but there's no independent check confirming cron is alive day to day.
