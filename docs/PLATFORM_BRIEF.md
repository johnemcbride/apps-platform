Here’s a solid, low-ops pattern that ticks your boxes: EC2 Spot for cost, Traefik as the front door, add-apps-without-SSH, Cloudflare-friendly, and easy to rebuild if a Spot is reclaimed.

# The shape of the setup

1. **One-node Swarm (or plain Docker) + Portainer UI**
   Run everything as containers on a single EC2 instance. Use **Portainer CE** so you can see what’s deployed and add new apps from a browser (Stacks → upload/URL to a compose file; supports webhooks for GitOps-y redeploys). No SSH needed to “see” or manage apps. ([docs.portainer.io][1])

2. **Traefik as reverse proxy**
   Traefik routes `Host()` rules to your app containers via labels. It works fine **behind Cloudflare** either via:

* **Cloudflare Tunnel** (no public ports on EC2; CF terminates TLS, forwards to Traefik), or
* **DNS-01 challenge** with Cloudflare API to get Let’s Encrypt certs even while orange-clouded. ([Cloudflare Docs][2])

3. **Cloudflare specifics**

* If using **Tunnel**, run `cloudflared` as a sidecar; CF handles certs at the edge. You can use a **Cloudflare Origin Certificate** between CF and Traefik for full end-to-end TLS. Also configure Traefik to read the **CF-Connecting-IP** header so logs/rate-limits see real client IPs. ([Cloudflare Docs][2])
* If skipping Tunnel and exposing 80/443, use **Traefik DNS-01 (Cloudflare)** for ACME. Works fine with the proxy on. ([Traefik Labs Documentation][3])

4. **EC2 Spot with safety rails**
   Put the instance in an **Auto Scaling Group (ASG)** using a **Mixed Instances Policy** with **capacity-optimized** Spot allocation and a small On-Demand fallback (e.g., 0–1 On-Demand) so you don’t go dark during a capacity crunch. Handle **2-minute interruption notices** to drain containers gracefully. ([AWS Documentation][4])

5. **State & restore**
   For simple apps, keep data in volumes and **nightly restic backups to S3**. If you want persistence across Spot replacements with zero manual reattach, store shared data on **EFS** (OK for light DBs/files; use RDS if you need real DB durability/perf). On re-provision, cloud-init pulls your Portainer + Traefik compose and you’re back.

6. **Security**
   Put Portainer and the Traefik dashboard behind **Authelia/SSO** (or at least HTTP basic auth), and only expose them via your tunnel/Traefik—not directly. CrowdSec/fail2ban optional.

---

# Minimal core `docker-compose.yml`

This example uses **Cloudflare Tunnel** (no open ports on the instance). Swap Tunnel for Traefik DNS-01 if you prefer direct 80/443.

```yaml
version: "3.9"

networks:
  edge:
  apps:

volumes:
  portainer_data:
  traefik_data:

services:
  traefik:
    image: traefik:v3.1
    command:
      - --api.dashboard=true
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      # Trust Cloudflare tunnel and use real client IP
      - --serverstransport.insecureskipverify=true
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --accesslog=true
      - --log.level=INFO
    labels:
      - "traefik.enable=true"
      # (Optional) Protect dashboard behind auth/SSO in front of this
      - "traefik.http.routers.traefik.rule=Host(`traefik.yourdomain.com`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.service=api@internal"
    ports: []  # no host ports; traffic arrives via cloudflared
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_data:/etc/traefik
    networks: [edge, apps]
    restart: unless-stopped

  portainer:
    image: portainer/portainer-ce:latest
    command: -H unix:///var/run/docker.sock
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(`portainer.yourdomain.com`)"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"
    networks: [apps]
    restart: unless-stopped

  cloudflared:
    image: cloudflare/cloudflared:latest
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}
    restart: unless-stopped
    networks: [edge]
```

> To deploy a new app, add a compose stack in Portainer with labels like:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.myapp.rule=Host(`myapp.yourdomain.com`)"
  - "traefik.http.routers.myapp.entrypoints=websecure"
  - "traefik.http.services.myapp.loadbalancer.server.port=3000"
```

Cloudflare Tunnel container docs (and remote-managed tunnels) are here. ([Cloudflare Docs][2])
Portainer “Add stack” flow (upload/URL/webhook) is here. ([docs.portainer.io][5])

---

# EC2 Spot bits that matter

* **ASG w/ Mixed Instances Policy**: pick several instance types (e.g., c7a.large, c7i.large, m7a.large), set **Spot** as primary and allow a small On-Demand percentage as fallback; choose **capacity-optimized** strategy. ([AWS Documentation][4])
* **User-data bootstrap**: install Docker, pull the above compose from a Git repo and `docker compose up -d`. If a Spot is reclaimed, a fresh instance self-hydrates.
* **Interruption handler**: a tiny systemd service watches the metadata endpoint for an **interruption notice** and tells Portainer/Swarm to drain before the 2-minute cutoff. (AWS docs on the notice here.) ([AWS Documentation][6])

---

# Cloudflare compatibility (your Dokploy pain point)

* With **Tunnels**, you don’t fight CF at all: no open ports, CF edge terminates TLS, and the tunnel forwards to Traefik on your private network. CF recommends remotely-managed tunnels for Docker setups. ([Cloudflare Docs][2])
* If you prefer direct 443 to Traefik behind orange cloud, use **DNS-01 ACME via Cloudflare** to mint certs and configure Traefik to trust `CF-Connecting-IP` for accurate client IPs/logging. ([Traefik Labs Documentation][3])
* If you want a turnkey PaaS-like layer, **Coolify** plays nicely with Cloudflare (including Tunnels) and can manage Traefik routes for you—handy if you don’t want to touch labels at all. ([Coolify][7])

---

## Variants (pick your flavor)

* **Simplest UI first**: *Docker + Portainer + Traefik + Cloudflare Tunnel* (compose above).
* **Slightly more infra-y**: *Docker Swarm + Portainer Agent* if you might add a second node later. Portainer makes Swarm trivial. ([dockerswarm.rocks][8])
* **PaaS-light**: *Coolify* on the same EC2. It handles app deploys, environments, logs, domains, and integrates with Cloudflare (Proxy/Tunnels). ([Coolify][7])

---

## Hardening & housekeeping (quick hits)

* Put Portainer/Traefik UI behind **Authelia** (SSO) or at least basic auth.
* **Backups**: restic to S3 for `/var/lib/docker/volumes/*` data you care about.
* **Updates**: `watchtower` for safe rolling container updates (or use Portainer webhooks from your Git repo).
* **Logs/metrics**: Traefik access log to S3/CloudWatch, and a tiny Loki + Grafana stack if you want searchable logs.

---

If you want, I can tailor the **cloud-init** (user-data) script and an **ASG Launch Template** that bootstraps Docker, Portainer, Traefik, and cloudflared on first boot, plus a tiny interruption handler—so a Spot termination just self-rebuilds in a couple minutes with no manual steps.

[1]: https://docs.portainer.io/?utm_source=chatgpt.com "Portainer Documentation: Welcome"
[2]: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/update-cloudflared/?utm_source=chatgpt.com "Update cloudflared · Cloudflare Zero Trust docs"
[3]: https://doc.traefik.io/traefik/user-guides/docker-compose/acme-dns/?utm_source=chatgpt.com "Docker-compose with Let's Encrypt: DNS Challenge"
[4]: https://docs.aws.amazon.com/autoscaling/ec2/userguide/mixed-instances-groups-set-up-overview.html?utm_source=chatgpt.com "Setup overview for creating a mixed instances group"
[5]: https://docs.portainer.io/user/docker/stacks/add?utm_source=chatgpt.com "Add a new stack"
[6]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html?utm_source=chatgpt.com "Spot Instance interruption notices"
[7]: https://coolify.io/docs/knowledge-base/cloudflare/tunnels/all-resource?utm_source=chatgpt.com "Access All Resource via Cloudflare Tunnels"
[8]: https://dockerswarm.rocks/portainer/?utm_source=chatgpt.com "Portainer web user interface for your Docker Swarm cluster"

Great questions. Here’s a clean pattern that keeps “infra” and “apps” decoupled, uses EC2 Spot, and lets you ship new `docker-compose` versions without SSH.

# TL;DR choices

* **Two repos** (recommended):

  * `infra-cdk/` – VPC/ASG/roles + a tiny bootstrap.
  * `apps-platform/` – your `docker-compose.yml`, Traefik/Coolify/Portainer config, `.env`, etc.
* **Rollouts**: CI in `apps-platform` publishes a versioned bundle to S3 and bumps an SSM Parameter (`/platform/compose_version`). CI then triggers an **ASG Instance Refresh** or an **SSM Run Command** to pull & apply.
* **Auto-detect?** Don’t make the instance “poll Git.” Prefer **explicit deployments** (CI updates SSM + triggers refresh). It’s safer and auditable.

---

# Repo layout that works

```
infra-cdk/
  cdk.json
  package.json
  bin/stack.ts
  lib/stack.ts
  user-data/bootstrap.sh           # installs docker, pulls compose from S3
  README.md

apps-platform/
  compose/production/compose.yml
  compose/production/.env.example
  traefik/traefik.yml
  traefik/dynamic/*.yml
  portainer/
  cloudflared/
  scripts/build_bundle.sh           # zips compose + config
  .github/workflows/deploy.yml      # publish to S3, bump SSM, trigger rollout
```

Why separate?

* **Infra cadence** (months) ≠ **app cadence** (days).
* You can roll back apps by flipping one SSM parameter, without touching CDK.

---

# CDK: base build (TypeScript)

This gives you: VPC (public subnets), Instance Profile with SSM, **ASG with Spot** (capacity-optimized), Launch Template with **user-data** that installs Docker and pulls the latest compose bundle from S3 based on an **SSM parameter**.

```ts
// lib/stack.ts
import * as cdk from 'aws-cdk-lib';
import { Stack, Duration, RemovalPolicy, aws_ec2 as ec2, aws_iam as iam,
         aws_autoscaling as asg, aws_ssm as ssm, aws_s3 as s3,
         aws_s3_deployment as s3deploy } from 'aws-cdk-lib';
import { readFileSync } from 'fs';
import { Construct } from 'constructs';

export class PlatformStack extends Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // 1) Network (simple: public only; Cloudflare Tunnel means no inbound ports)
    const vpc = new ec2.Vpc(this, 'Vpc', {
      natGateways: 0,
      maxAzs: 2,
      subnetConfiguration: [{ name: 'public', subnetType: ec2.SubnetType.PUBLIC }]
    });

    // 2) Bucket for versioned compose bundles
    const bundleBucket = new s3.Bucket(this, 'ComposeBucket', {
      versioned: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      removalPolicy: RemovalPolicy.RETAIN,
      enforceSSL: true
    });

    // (Optional) Seed a default empty bundle so first boot doesn't fail
    new s3deploy.BucketDeployment(this, 'SeedBundle', {
      destinationBucket: bundleBucket,
      destinationKeyPrefix: 'bundles/',
      sources: [s3deploy.Source.asset('user-data/seed-bundle')], // place a minimal zip here
      retainOnDelete: true
    });

    // 3) Parameter the app CI will bump (e.g., "bundles/platform-2025-09-15.zip")
    const composeKeyParam = new ssm.StringParameter(this, 'ComposeKeyParam', {
      parameterName: '/platform/compose_key',
      stringValue: 'bundles/seed.zip'
    });

    // 4) Instance Role
    const role = new iam.Role(this, 'InstanceRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com')
    });
    role.addManagedPolicy(iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'));
    role.addManagedPolicy(iam.ManagedPolicy.fromAwsManagedPolicyName('CloudWatchAgentServerPolicy'));
    // Read bundle + read SSM param
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:GetObject'],
      resources: [bundleBucket.arnForObjects('*')]
    }));
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['ssm:GetParameter', 'ssm:GetParameters'],
      resources: [composeKeyParam.parameterArn]
    }));

    // 5) Security Group (egress only)
    const sg = new ec2.SecurityGroup(this, 'Sg', { vpc, allowAllOutbound: true });

    // 6) Launch Template + User Data
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      // Harden IMDSv2 is default on LT; we’ll still be explicit
      'set -euxo pipefail',
      // Install docker + compose plugin (Amazon Linux 2023)
      'dnf update -y',
      'dnf install -y docker git unzip',
      'systemctl enable --now docker',
      // Fetch compose bundle key from SSM
      `COMPOSE_KEY=$(aws ssm get-parameter --name ${composeKeyParam.parameterName} --query 'Parameter.Value' --output text --region ${this.region})`,
      `aws s3 cp s3://${bundleBucket.bucketName}/$COMPOSE_KEY /opt/bundle.zip`,
      'mkdir -p /opt/platform && unzip -o /opt/bundle.zip -d /opt/platform',
      // Bring up core stack (Traefik/Portainer/cloudflared) from the bundle
      'cd /opt/platform && docker compose pull && docker compose up -d',
      // Spot interruption handler: drain gracefully
      'cat >/usr/local/bin/spot-drain.sh <<EOF\n' +
      '#!/usr/bin/env bash\n' +
      'set -euo pipefail\n' +
      'URL=http://169.254.169.254/latest/meta-data/spot/instance-action\n' +
      'while sleep 5; do\n' +
      '  if curl -sf $URL >/dev/null; then\n' +
      '    echo "[spot] interruption notice received; stopping containers..." | systemd-cat -t spot\n' +
      '    docker compose -f /opt/platform/compose.yml down\n' +
      '    sleep 100\n' +
      '  fi\n' +
      'done\nEOF\n' +
      'chmod +x /usr/local/bin/spot-drain.sh',
      'cat >/etc/systemd/system/spot-drain.service <<EOF\n' +
      '[Unit]\nDescription=Spot Interruption Drainer\nAfter=docker.service\n' +
      '[Service]\nExecStart=/usr/local/bin/spot-drain.sh\nRestart=always\n' +
      '[Install]\nWantedBy=multi-user.target\nEOF\n',
      'systemctl enable --now spot-drain.service'
    );

    const lt = new ec2.LaunchTemplate(this, 'Lt', {
      machineImage: ec2.MachineImage.latestAmazonLinux2023(),
      instanceType: new ec2.InstanceType('c7a.large'),
      role,
      securityGroup: sg,
      userData,
      requireImdsv2: true
    });

    // 7) Auto Scaling Group using Spot (with diversified types)
    const asgGroup = new asg.AutoScalingGroup(this, 'Asg', {
      vpc,
      minCapacity: 1,
      maxCapacity: 1,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      launchTemplate: lt,
    });

    // Switch to Mixed Instances/Spot via overrides (CDK helper)
    asgGroup.spotPrice = '0.0'; // “Spot only”; price is ignored, but sets lifecycle
    asgGroup.addOverride('Properties.MixedInstancesPolicy', {
      LaunchTemplate: { LaunchTemplateSpecification: { LaunchTemplateId: lt.launchTemplateId, Version: lt.latestVersionNumber } },
      InstancesDistribution: { OnDemandPercentageAboveBaseCapacity: 0, SpotAllocationStrategy: 'capacity-optimized' },
      LaunchTemplateOverrides: [
        { InstanceType: 'c7a.large' },
        { InstanceType: 'c7i.large' },
        { InstanceType: 'm7a.large' },
        { InstanceType: 'm7i.large' }
      ]
    });

    // (Nice-to-have) Instance Refresh on every param/bundle bump is triggered by CI (see below)
    new cdk.CfnOutput(this, 'BucketName', { value: bundleBucket.bucketName });
    new cdk.CfnOutput(this, 'ComposeParam', { value: composeKeyParam.parameterName });
  }
}
```

**bootstrap.sh** above is inlined as `userData.addCommands(...)` so you don’t have to SCP anything.

---

# Where to store `docker-compose`?

* **In `apps-platform/` repo** (not the infra repo).
  Keep `compose.yml`, Traefik dynamic config, and any `.env`. Your CI zips that tree into `bundle.zip`.

Example bundle layout (what ends up in `/opt/platform`):

```
compose.yml
.env
traefik/traefik.yml
traefik/dynamic/*.yml
cloudflared/config.yml
portainer/...
```

---

# How the instance gets the *latest* compose

* The instance reads **`/platform/compose_key`** (SSM) at boot.
* Your **CI** (when you tag or merge to main) uploads a new `bundles/platform-YYYYMMDD-HHMM.zip` to S3, then updates the SSM parameter to point to that key, then either:

  1. **Starts an ASG Instance Refresh** (blue/green-ish: new Spot comes up on new version; old one terminates), **or**
  2. Runs **SSM Run Command** on the current instance to `aws s3 cp` + `docker compose pull && up -d` in place.

I recommend **Instance Refresh**: it proves a clean bootstrap and catches drift.

---

# GitHub Actions (apps-platform → S3 → SSM → rollout)

```yaml
# .github/workflows/deploy.yml
name: Deploy Compose Bundle
on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      # zip bundle
      - name: Build bundle
        run: |
          set -eux
          mkdir -p dist
          zip -r dist/bundle.zip compose/production traefik portainer cloudflared \
            -x '**/.DS_Store' '**/.git*'

      # configure AWS (OIDC role you create in infra account)
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/github-oidc-deploy
          aws-region: eu-west-1

      - name: Upload to S3
        run: |
          KEY="bundles/platform-$(date +%Y%m%d-%H%M%S).zip"
          aws s3 cp dist/bundle.zip s3://$BUNDLE_BUCKET/$KEY
          echo "KEY=$KEY" >> $GITHUB_ENV

      - name: Update SSM parameter
        run: |
          aws ssm put-parameter --name /platform/compose_key --type String --value "$KEY" --overwrite

      # Option A: Instance Refresh (recommended)
      - name: Start Instance Refresh
        run: |
          aws autoscaling start-instance-refresh --auto-scaling-group-name "<AsgName>" \
            --preferences "MinHealthyPercentage=100,InstanceWarmup=120"

      # Option B (instead): in-place update via SSM Run Command
      # - name: Rolling in-place update
      #   run: |
      #     aws ssm send-command \
      #       --document-name "AWS-RunShellScript" \
      #       --targets "Key=tag:aws:autoscaling:groupName,Values=<AsgName>" \
      #       --parameters commands='[
      #         "set -eux",
      #         "KEY=$(aws ssm get-parameter --name /platform/compose_key --query Parameter.Value --output text)",
      #         "aws s3 cp s3://'"$BUNDLE_BUCKET"'/$KEY /opt/bundle.zip",
      #         "unzip -o /opt/bundle.zip -d /opt/platform",
      #         "cd /opt/platform && docker compose pull && docker compose up -d"
      #       ]'
```

> Set `BUNDLE_BUCKET` as a repo secret; the OIDC role must allow `s3:PutObject`, `ssm:PutParameter`, and `autoscaling:StartInstanceRefresh`.

---

# Should infra auto-detect new compose?

* **No.** Let CI **announce** a new version by updating SSM and triggering a rollout.
* Advantages: auditable, reversible, and you won’t get surprise mid-night deploys because a node rebooted and “pulled main”.

If you really want pull-based, add a tiny systemd timer that checks SSM every N minutes and redeploys when the key changes—but you lose explicit change control.

---

# Bonus switches you can flip later

* **EFS** for volumes that must survive Spot replacement (mount in user-data, point volumes there).
* **Coolify** instead of Portainer if you want a more PaaS-like UI (it still sits inside the same compose bundle).
* **Cloudflare Tunnel** config lives in the bundle; you can rotate the `TUNNEL_TOKEN` via SSM and reference it in the compose with `${CF_TUNNEL_TOKEN}` pulled at boot.

If you want, say the word and I’ll tailor the `compose.yml` skeleton (Traefik+Portainer+cloudflared) and the exact IAM trust policy for the GitHub OIDC deployment role.
