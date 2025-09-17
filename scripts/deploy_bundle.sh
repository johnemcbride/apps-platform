#!/bin/bash
set -euxo pipefail


# Read secrets from environment variables, warn if not set
if [ -z "${BUCKET:-}" ]; then echo "ERROR: BUCKET env var not set" >&2; exit 1; fi
if [ -z "${REGION:-}" ]; then echo "ERROR: REGION env var not set" >&2; exit 1; fi
if [ -z "${ASG:-}" ]; then echo "ERROR: ASG env var not set" >&2; exit 1; fi
if [ -z "${PROFILE:-}" ]; then echo "ERROR: PROFILE env var not set" >&2; exit 1; fi
if [ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then echo "ERROR: CLOUDFLARE_TUNNEL_TOKEN env var not set" >&2; exit 1; fi

# 1. Build bundle
cd "$(dirname "$0")/../compose/production"
# Create .env file with Cloudflare token
echo "CLOUDFLARE_TUNNEL_TOKEN=$CLOUDFLARE_TUNNEL_TOKEN" > .env
# Substitute Podman socket with Docker socket for Traefik before bundling
cp compose.yml compose.yml.bak
sed 's|/run/podman/podman.sock:/var/run/docker.sock:ro,Z|/var/run/docker.sock:/var/run/docker.sock:ro|g' compose.yml.bak > compose.yml
zip -r ../../bundle.zip .
# Restore original compose file
mv compose.yml.bak compose.yml
cd ../..

# 2. Upload to S3 with timestamped key
KEY="bundles/platform-$(date +%Y%m%d-%H%M%S).zip"
if [ ! -f bundle.zip ]; then
	echo "ERROR: bundle.zip not found in $(pwd). Zip step may have failed." >&2
	exit 1
fi
aws s3 cp bundle.zip s3://$BUCKET/$KEY --profile $PROFILE --region $REGION

# 3. Update SSM parameter
aws ssm put-parameter --name /platform/compose_key --type String --value "$KEY" --overwrite --profile $PROFILE --region $REGION

# 4. Trigger instance refresh
aws autoscaling start-instance-refresh --auto-scaling-group-name $ASG --profile $PROFILE --region $REGION

echo "Deployed $KEY and triggered instance refresh."
