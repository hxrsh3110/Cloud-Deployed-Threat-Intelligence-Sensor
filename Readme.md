# SSH Honeypot on AWS EC2

A small Node.js TCP server that pretends to be an SSH login prompt, logs whoever connects, and keeps that log even if the container gets rebuilt, the box reboots, or the instance itself gets replaced entirely. The entire server provisions and boots itself from Terraform with no manual SSH setup required, and management access no longer depends on SSH at all.

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

## Why they also survive instance replacement now

The host-level mount above only protects against container churn, it does nothing if the instance itself gets destroyed and recreated (an AMI change, an instance type change, a `user_data` change). That volume lives on the instance's root EBS volume, and until recently, every replacement wiped every log collected so far. This bit the project directly during the SSM migration; the only reason no data was lost then is that logs were manually backed up with `scp` before applying the change.

That gap is closed now. A cron job on the instance pushes `threat-logs.txt` to a versioned S3 bucket every 5 minutes:

```bash
*/5 * * * * /usr/local/bin/aws s3 cp /home/ubuntu/honeypot-logs/threat-logs.txt s3://honeypot-logs-hxrsh3110-eu-north-1/threat-logs.txt --only-show-errors
```

Credentials come from the instance's IAM role automatically, nothing hardcoded. The role is scoped to `s3:PutObject` on that one bucket only, it can push logs in but can't read them back or touch anything else in the account. Versioning is enabled on the bucket, so overwriting the same key on every sync still preserves full history, no need to manage timestamped filenames by hand.

**This still isn't zero-loss.** Up to 5 minutes of log data can be lost if the instance dies between sync intervals. See Known Gaps.

Getting this working also surfaced a real bug worth documenting rather than quietly fixing: `crontab -l -u ubuntu` exits with status 1 on a user's first-ever crontab check, since no crontab exists yet. That's expected, harmless behavior, `crontab` is designed to fail that way. But with `set -euxo pipefail` active, that expected failure was silently killing the entire `user_data.sh` script partway through, on every single fresh boot, before it ever reached the AWS CLI install, the S3 cron setup, or the `ssm-user` permission fixes further down. This means the health-check cron job, which predates tonight entirely, has likely never actually installed on any Terraform-provisioned instance since the SSM migration. The fix was adding `|| true` after the `2>/dev/null` on both crontab lines, so the expected failure doesn't propagate. This was caught, not assumed, by rebuilding from a cold Terraform boot and checking `crontab -l` directly instead of trusting that "the script ran without errors" meant everything in it worked.

## Why it doesn't run as root

The container drops root privileges and runs as the built-in `node` user (UID 1000) from the `node:20-alpine` image, via `USER node` in the Dockerfile. A process that's intentionally sitting open to the entire internet shouldn't also have root inside its own container.

One consequence of this that isn't obvious until you hit it: the host directory being mounted in has to be writable by UID 1000, not just by root. `infra/user_data.sh` handles this automatically at boot (`chown -R 1000:1000` on the log directory before the container ever starts), so this is no longer a manual step, but if you ever recreate the log directory by hand outside of Terraform, run:

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

The AWS side, the security group, the EC2 instance, the Elastic IP, the IAM role/instance profile used for access, and the S3 bucket used for log shipping, is tracked in Terraform under `infra/main.tf`. The instance and security group weren't built from Terraform originally, the infrastructure existed from manual console setup first, so it was brought under Terraform with `terraform import`, which tells Terraform "this resource already exists with this ID, track it instead of creating something new."

The first `terraform plan` after importing showed real drift: the security group's actual name (`launch-wizard-7`, an AWS-generated default from the original console setup, never renamed) and description didn't match what was first written into the file, and one ingress rule had the wrong source IP entirely. The file was corrected to match reality instead of applying, and `terraform plan` was re-run until it reported "No changes. Your infrastructure matches the configuration."

### The instance now provisions itself

`aws_instance.honeypot` includes a `user_data` script (`infra/user_data.sh`) that runs automatically the first time the instance boots. It installs Docker, git, and the AWS CLI, clones the repo, builds the image, starts the container, and sets up both cron jobs (health check and S3 log sync), all without anyone SSHing in to type commands by hand. `user_data_replace_on_change = true` is set explicitly, spelling out that changing this script forces a full instance replacement rather than an in-place update, since that's the AWS provider's actual default behavior and it's better documented than left implicit.

Things worth knowing about how this was validated, not just written and assumed correct:

- The first real run surfaced a gap the script's author didn't know was there: `health-check.sh`, described in this README's monitoring section as already built, had in fact never been committed to the repository. It existed only on the original, manually-configured instance. The automated bootstrap failed at that exact step, which is what caught the gap. The file has since been committed and the bootstrap now completes end to end.
- Access to the instance during and after the SSM migration moved off SSH entirely, which meant discovering and fixing a chain of ownership and permission mismatches between the `ubuntu` user (which owns everything `user_data` creates) and `ssm-user` (the account SSM sessions log in as). `user_data.sh` attempts to grant `ssm-user` group access to both Docker and the project directory at boot, but this depends on `ssm-user` already existing at that point in the boot sequence, and it doesn't reliably. See Known Gaps.
- Adding S3 log shipping surfaced a second, unrelated bootstrap failure: an expected-but-harmless `crontab -l` exit code was silently aborting the entire script under `set -e`, meaning the AWS CLI install, the S3 cron job, and the `ssm-user` permission fixes never ran on any fresh boot until this was caught and fixed. Full detail above.

### Access moved from SSH to AWS Systems Manager (SSM)

The original security group allowed SSH from a single hardcoded IP. That's a real problem for a laptop that connects over a mobile hotspot: the IP changes, and a hardcoded rule locks you out the moment it does, with no way back in except editing the security group from a session that's already locked out.

Rather than widen that rule (which would mean opening SSH to the whole internet, undermining the entire point of hardening this project), management access moved to SSM Session Manager instead:

- An IAM role (`aws_iam_role.ssm_role`) with the `AmazonSSMManagedInstanceCore` policy is attached to the instance via an instance profile.
- The port 22 ingress rule was removed from the security group entirely. It no longer exists, there is no SSH access to this instance, from any IP.
- Connecting now uses:

```bash
aws ssm start-session --target <instance-id>
```

This requires the AWS CLI and the Session Manager plugin installed locally, and valid AWS credentials configured (`aws configure`), but it does not depend on the connecting machine's IP address at all, so a rotating hotspot IP is no longer a problem.

What this doesn't cover: interactive file transfer. `scp` still needs an actual SSH connection, which no longer exists. Threat logs no longer need this at all now that they ship to S3 automatically, but anything else pulled off the box still requires an SSM port-forwarding session or another transfer method.

`infra/terraform.tfstate` and `infra/.terraform/` are gitignored and never pushed, since state files can contain sensitive detail about the real infrastructure. Only `main.tf`, `user_data.sh`, `.gitignore`, and the provider lock file are meant to be committed.

## Monitoring

A cron job runs `health-check.sh` every 5 minutes, checks whether the `live-trap` container is up, and logs the result to `~/honeypot-logs/health.log`. On every healthy check it also pings a [healthchecks.io](https://healthchecks.io) endpoint. If that ping goes silent for longer than the configured period plus grace window, healthchecks.io sends an email automatically. This is what actually closes the loop, a log file nobody reads isn't a monitor, an external service that notices your silence is.

Current settings: 10 minute period, 5 minute grace, so a real outage takes up to about 15 minutes to trigger an email.

`health-check.sh` is committed to the repository and installed automatically by `user_data.sh` on boot.

## Deployment

### 1. Launch the EC2 instance

Provisioning the instance, security group, Elastic IP, IAM role/instance profile, and S3 bucket is handled by Terraform (`infra/main.tf`), including the `user_data` bootstrap. A fresh instance requires no manual SSH steps to get the honeypot running, Terraform and cloud-init handle it end to end.

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
sudo tail -100 /var/log/user-data.log
```

Confirm the bootstrap ran all the way through without aborting partway, this has bitten the project twice, silently.

```bash
sudo -u ubuntu crontab -l
```

Should show both the health-check line and the S3 sync line. An empty result here means the bootstrap didn't complete, even if the container itself looks fine.

```bash
docker logs live-trap
```

Look for `Failed to save log.`, if you see it, it's a permissions problem. If it's clean, trigger a real connection from a different network than the server itself is on, then confirm the log actually grew:

```bash
nc <PUBLIC_IP> 2222
tail -1 /home/ubuntu/honeypot-logs/threat-logs.txt
```

Then confirm the S3 sync, don't just wait for the cron tick, run it manually:

```bash
sudo -u ubuntu /usr/local/bin/aws s3 cp /home/ubuntu/honeypot-logs/threat-logs.txt s3://honeypot-logs-hxrsh3110-eu-north-1/threat-logs.txt --only-show-errors
```

From your own machine:

```bash
aws s3 ls s3://honeypot-logs-hxrsh3110-eu-north-1/
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

**Note:** this runbook is only for resuming an instance that stays the same instance. If instead you've run `terraform apply` with a `user_data.sh` change (which forces a full instance replacement), don't follow these steps, `user_data.sh` handles the clone, build, and container start itself on the new instance's first boot. Jump straight to the verification steps under Deployment instead.

## Known gaps

Being upfront about what's not done, instead of implying it is:

- **`ssm-user` group membership is a race condition, not a guarantee.** `user_data.sh` waits up to 60 seconds for the `ssm-user` account to exist before adding it to the `docker` and `ubuntu` groups. But that account only gets created by the SSM agent on first connection, which may not happen inside that window. If it doesn't, the script finishes without adding the user to either group, and every `docker` or log command inside an SSM session silently requires `sudo` until someone runs `usermod` by hand or the instance gets replaced again. Hit twice during the S3 rollout, patched manually both times, not yet fixed at the script level.
- **File transfer off the instance for anything other than threat logs has no clean path.** SSH is gone, and with it, `scp`. Threat logs now ship automatically via the S3 cron job, but anything else still requires an SSM port-forwarding tunnel or a different method entirely.
- **CI builds and scans, but doesn't deploy.** The pipeline catches vulnerabilities before they'd ship, but getting a rebuilt image onto the actual running instance is still a manual step or a full Terraform-triggered replacement.
- **No fake shell after login.** Credentials are captured, but the connection ends right after, there's no simulated filesystem or command interpreter to see what an attacker would try next if they thought they were in.
- **Monitoring has a real blind spot.** The health check relies on cron running at all. If cron itself dies, or the whole instance goes down, the healthchecks.io grace window still catches it eventually because silence itself is the alert condition, but there's no independent check confirming cron is alive day to day.
- **S3 log sync has up to a 5 minute lag.** Logs push to S3 on a fixed 5-minute cron interval, not on write. An instance that dies between syncs loses whatever was captured in that window. Bounded and small, but not zero.