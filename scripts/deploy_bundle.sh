
#!/bin/bash
set -euxo pipefail

# Usage: ./deploy_bundle.sh [local|cloud]
ENVIRONMENT="${1:-cloud}"

# Detect docker compose command
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "ERROR: Neither 'docker compose' nor 'docker-compose' is available. Please install Docker Compose." >&2
    exit 1
fi

cd "$(dirname "$0")/../compose/production"

# Read environment config from environments.json
CONFIG_FILE="../../environments.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found" >&2; exit 1;
fi

get_json() {
    jq -r ".${ENVIRONMENT}.$1" "$CONFIG_FILE"
}


TUNNEL_TOKEN=$(get_json tunnel_token)
TUNNEL_ID=$(get_json tunnel_id)
TRAEFIK_HOSTNAME=$(get_json traefik_hostname)
PORTAINER_HOSTNAME=$(get_json portainer_hostname)
DOCKER_SOCKET_PATH=$(get_json docker_socket_path)
GITHUB_CLIENT_ID_PROD=$(get_json github_client_id_prod)
GITHUB_CLIENT_SECRET_PROD=$(get_json github_client_secret_prod)
OAUTH2_COOKIE_SECRET_PROD=$(get_json oauth2_cookie_secret_prod)
OAUTH_URL=$(get_json oauth_url)
ASG=$(get_json asg)
BUCKET=$(get_json bucket)
REGION=$(get_json region)
PROFILE=$(get_json profile)

# Write .env file for compose
ENV_FILE=".env"
echo "TUNNEL_TOKEN=$TUNNEL_TOKEN" > "$ENV_FILE"
echo "TRAEFIK_HOSTNAME=$TRAEFIK_HOSTNAME" >> "$ENV_FILE"
echo "TUNNEL_ID=$TUNNEL_ID" >> "$ENV_FILE"
echo "PORTAINER_HOSTNAME=$PORTAINER_HOSTNAME" >> "$ENV_FILE"
echo "DOCKER_SOCKET_PATH=$DOCKER_SOCKET_PATH" >> "$ENV_FILE"
echo "GITHUB_CLIENT_ID_PROD=$GITHUB_CLIENT_ID_PROD" >> "$ENV_FILE"
echo "GITHUB_CLIENT_SECRET_PROD=$GITHUB_CLIENT_SECRET_PROD" >> "$ENV_FILE"
echo "OAUTH2_COOKIE_SECRET_PROD=$OAUTH2_COOKIE_SECRET_PROD" >> "$ENV_FILE"
echo "OAUTH_URL=$OAUTH_URL" >> "$ENV_FILE"
OAUTH_WHITELIST_DOMAIN=$(get_json oauth_whitelist_domain)
echo "OAUTH_WHITELIST_DOMAIN=$OAUTH_WHITELIST_DOMAIN" >> "$ENV_FILE"

if [ "$ENVIRONMENT" = "cloud" ]; then
    # Cloud: just build the bundle
    zip -r ../../bundle.zip .
    cd ../..
    KEY="bundles/platform-$(date +%Y%m%d-%H%M%S).zip"
    if [ ! -f bundle.zip ]; then
        echo "ERROR: bundle.zip not found in $(pwd). Zip step may have failed." >&2
        exit 1
    fi
    aws s3 cp bundle.zip s3://$BUCKET/$KEY --profile $PROFILE --region $REGION
    aws ssm put-parameter --name /platform/compose_key --type String --value "$KEY" --overwrite --profile $PROFILE --region $REGION
    aws autoscaling start-instance-refresh --auto-scaling-group-name $ASG --profile $PROFILE --region $REGION
    echo "Deployed $KEY and triggered instance refresh."
    exit 0
else
    # Local/dev: run compose with env file
    $DOCKER_COMPOSE --env-file "$ENV_FILE" down -v --remove-orphans --timeout 10 || true
    $DOCKER_COMPOSE --env-file "$ENV_FILE" pull
    $DOCKER_COMPOSE --env-file "$ENV_FILE" up -d --force-recreate
    echo "Stack deployed for $ENVIRONMENT."
    exit 0
fi
