#!/bin/bash
# docker-roll.sh - A CLI tool for rolling updates with Traefik
# Usage: docker-roll up [options]

set -e

VERSION="1.0.3"
COMMAND=""
PROJECT_DIR=$(pwd)
TRAEFIK_DIR="/home/ssw/traefik"  # Default location of Traefik directory
DYNAMIC_CONF_DIR="${TRAEFIK_DIR}/data/dynamic_conf"

# Default configuration
DOMAIN=""
HEALTH_CHECK_PATH="/health"
HEALTH_CHECK_TIMEOUT=60
TRAFFIC_SHIFT_INTERVAL=20
COMPOSE_FILE="docker-compose.yml"
SERVICE_NAME="app"  # Default service name to update
PORT="3000"         # Default internal port

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display help
show_help() {
    echo -e "${BLUE}docker-roll${NC} - A CLI tool for rolling updates with Traefik"
    echo ""
    echo "Usage:"
    echo "  docker-roll up [options]      Perform a rolling update"
    echo "  docker-roll help              Show this help message"
    echo "  docker-roll version           Show version information"
    echo ""
    echo "Options:"
    echo "  --domain, -d        Domain name for the service (required)"
    echo "  --service, -s       Service name in docker-compose to update (default: app)"
    echo "  --port, -p          Internal container port the service is running on (default: 3000)"
    echo "  --compose-file, -f  Path to docker-compose file (default: docker-compose.yml)"
    echo "  --health-path       Health check endpoint path (default: /health)"
    echo "  --health-timeout    Health check timeout in seconds (default: 60)"
    echo "  --shift-interval    Time between traffic shifts in seconds (default: 20)"
    echo "  --traefik-dir       Path to Traefik directory (default: /root/traefik)"
    echo "  --no-shift          Deploy without gradual traffic shifting"
    echo "  --color-scheme      Use blue-green naming instead of timestamps (blue|green)"
    echo ""
    echo "Example:"
    echo "  docker-roll up --domain myapp.example.com --service web --port 8080"
}

# Function to show version
show_version() {
    echo "docker-roll version ${VERSION}"
}

# Function to log messages
log() {
    local level=$1
    local message=$2
    local color=$NC
    
    case $level in
        "INFO") color=$BLUE ;;
        "SUCCESS") color=$GREEN ;;
        "WARNING") color=$YELLOW ;;
        "ERROR") color=$RED ;;
    esac
    
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}${NC}"
}

# Check if required tools are installed
check_requirements() {
    # Check for required commands
    for cmd in docker curl jq; do
        if ! command -v $cmd &> /dev/null; then
            log "ERROR" "$cmd is required but not installed. Please install it first."
            exit 1
        fi
    done
    
    # Check for docker compose (could be docker-compose or docker compose)
    if command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
    elif docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
    else
        log "ERROR" "Neither docker-compose nor docker compose is available. Please install Docker Compose first."
        exit 1
    fi
    
    # Check if Traefik is running
    if ! docker ps | grep -q traefik; then
        log "WARNING" "Traefik container not detected. Make sure it's running."
    fi
    
    # Check if dynamic conf directory exists
    if [ ! -d "$DYNAMIC_CONF_DIR" ]; then
        log "WARNING" "Traefik dynamic configuration directory not found at $DYNAMIC_CONF_DIR"
        log "INFO" "Creating directory: $DYNAMIC_CONF_DIR"
        mkdir -p "$DYNAMIC_CONF_DIR"
    fi
}

# Parse command line arguments
parse_args() {
    COMMAND=$1
    shift
    
    if [ "$COMMAND" = "help" ]; then
        show_help
        exit 0
    elif [ "$COMMAND" = "version" ]; then
        show_version
        exit 0
    elif [ "$COMMAND" != "up" ]; then
        log "ERROR" "Unknown command: $COMMAND"
        show_help
        exit 1
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain|-d)
                DOMAIN="$2"
                shift 2
                ;;
            --service|-s)
                SERVICE_NAME="$2"
                shift 2
                ;;
            --port|-p)
                PORT="$2"
                shift 2
                ;;
            --compose-file|-f)
                COMPOSE_FILE="$2"
                shift 2
                ;;
            --health-path)
                HEALTH_CHECK_PATH="$2"
                shift 2
                ;;
            --health-timeout)
                HEALTH_CHECK_TIMEOUT="$2"
                shift 2
                ;;
            --shift-interval)
                TRAFFIC_SHIFT_INTERVAL="$2"
                shift 2
                ;;
            --traefik-dir)
                TRAEFIK_DIR="$2"
                DYNAMIC_CONF_DIR="${TRAEFIK_DIR}/data/dynamic_conf"
                shift 2
                ;;
            --no-shift)
                NO_SHIFT=true
                shift
                ;;
            --color-scheme)
                USE_COLOR_SCHEME=true
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Validate required parameters
    if [ -z "$DOMAIN" ]; then
        log "ERROR" "Domain is required. Use --domain or -d to specify."
        exit 1
    fi
    
    # Check if compose file exists
    if [ ! -f "$COMPOSE_FILE" ]; then
        log "ERROR" "Docker Compose file not found: $COMPOSE_FILE"
        exit 1
    fi
}

# Get the project name from the current directory or docker-compose.yml
get_project_name() {
    # First check if COMPOSE_PROJECT_NAME is defined in .env file
    if [ -f ".env" ] && grep -q "COMPOSE_PROJECT_NAME" .env; then
        PROJECT_NAME=$(grep "COMPOSE_PROJECT_NAME" .env | cut -d '=' -f2)
    else
        # Fall back to directory name
        PROJECT_NAME=$(basename "$PROJECT_DIR")
    fi
    echo $PROJECT_NAME
}

# Find the running container for the service
find_running_container() {
    local service=$1
    local project=$2
    
    # Try to find container using both project and service name
    CONTAINER_ID=$(docker ps --filter "label=com.docker.compose.project=$project" --filter "label=com.docker.compose.service=$service" --format "{{.ID}}" | head -n 1)
    
    # If not found, try just by service name
    if [ -z "$CONTAINER_ID" ]; then
        CONTAINER_ID=$(docker ps --filter "label=com.docker.compose.service=$service" --format "{{.ID}}" | head -n 1)
    fi
    
    echo $CONTAINER_ID
}

# Find if any container is already running with the blue-green pattern
check_blue_green_deployment() {
    local project=$1
    local service=$2
    
    # Check if blue or green container exists
    BLUE_CONTAINER=$(docker ps --filter "name=${project}-blue-${service}" --format "{{.ID}}" | head -n 1)
    GREEN_CONTAINER=$(docker ps --filter "name=${project}-green-${service}" --format "{{.ID}}" | head -n 1)
    
    if [ -n "$BLUE_CONTAINER" ]; then
        echo "blue"
    elif [ -n "$GREEN_CONTAINER" ]; then
        echo "green"
    else
        echo ""
    fi
}

# Create temporary docker-compose file for new version
create_temp_compose() {
    local deployment_id=$1
    local service=$2
    local original_file=$3
    local domain=$4
    local port=$5
    local new_service="${service}-${deployment_id}"
    
    log "INFO" "Creating temporary compose file for new deployment: $new_service"
    
    # Create a copy of the original compose file
    cp $original_file docker-compose.rolling.yml
    
    # Remove the host port binding to avoid conflicts
    sed -i 's/ports:/expose:/g' docker-compose.rolling.yml
    sed -i 's/- "[0-9]*:[0-9]*"/- "'$port'"/g' docker-compose.rolling.yml
    
    # Replace service name in labels
    sed -i "s/traefik.http.routers.${SERVICE_NAME}/traefik.http.routers.${new_service}/g" docker-compose.rolling.yml
    sed -i "s/traefik.http.routers.\${COMPOSE_PROJECT_NAME:-app}/traefik.http.routers.${new_service}/g" docker-compose.rolling.yml
    sed -i "s/traefik.http.services.${SERVICE_NAME}/traefik.http.services.${new_service}/g" docker-compose.rolling.yml
    sed -i "s/traefik.http.services.\${COMPOSE_PROJECT_NAME:-app}/traefik.http.services.${new_service}/g" docker-compose.rolling.yml
    
    # Ensure domain is set correctly
    sed -i "s/Host(`.*`)/Host(`${domain}`)/g" docker-compose.rolling.yml
    
    # Add deployment ID label
    sed -i "/labels:/a \      - \"deployment.id=${deployment_id}\"" docker-compose.rolling.yml
    
    # Make sure the container port is correct
    sed -i "s/server.port=[0-9]*/server.port=${port}/g" docker-compose.rolling.yml
    
    # Ensure healthcheck is configured
    if ! grep -q "healthcheck" docker-compose.rolling.yml; then
        sed -i "/labels:/a \      - \"traefik.http.services.${new_service}.loadbalancer.healthcheck.path=${HEALTH_CHECK_PATH}\"" docker-compose.rolling.yml
        sed -i "/labels:/a \      - \"traefik.http.services.${new_service}.loadbalancer.healthcheck.interval=5s\"" docker-compose.rolling.yml
        sed -i "/labels:/a \      - \"traefik.http.services.${new_service}.loadbalancer.healthcheck.timeout=3s\"" docker-compose.rolling.yml
    fi
    
    log "SUCCESS" "Temporary compose file created"
}

# Create weighted service configuration for Traefik
create_weighted_config() {
    local old_service=$1
    local new_service=$2
    local domain=$3
    local old_weight=$4
    local new_weight=$5
    local project_name=$6
    
    log "INFO" "Updating traffic weights: ${old_weight}% old, ${new_weight}% new"
    
    mkdir -p $DYNAMIC_CONF_DIR
    
    cat > "${DYNAMIC_CONF_DIR}/weighted-${project_name}.yml" <<EOF
http:
  services:
    weighted-${project_name}:
      weighted:
        services:
          - name: ${old_service}@docker
            weight: ${old_weight}
          - name: ${new_service}@docker
            weight: ${new_weight}

  routers:
    weighted-${project_name}:
      rule: "Host(\`${domain}\`)"
      entryPoints:
        - websecure
      service: weighted-${project_name}
      tls:
        certResolver: letsencrypt
      middlewares:
        - secure-headers@docker
        - gzip-compress@docker
EOF
}

# Check if container is healthy
check_container_health() {
    local container_id=$1
    local health_path=$2
    local port=$3
    local timeout=$4
    
    log "INFO" "Waiting for container to be healthy (timeout: ${timeout}s)..."
    
    # Get container IP
    local container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $container_id)
    
    for i in $(seq 1 $timeout); do
        if curl -s -f -o /dev/null "http://${container_ip}:${port}${health_path}"; then
            log "SUCCESS" "Container is healthy!"
            return 0
        fi
        
        echo -n "."
        if [ $((i % 10)) -eq 0 ]; then
            echo " $i/${timeout}"
        fi
        
        sleep 1
    done
    
    log "ERROR" "Health check timed out. Container is not healthy."
    return 1
}

# Determine which color deployment to use (blue or green)
get_deployment_color() {
    local current_color=$1
    
    if [ "$current_color" = "blue" ]; then
        echo "green"
    else
        echo "blue"
    fi
}

# Perform rolling update
perform_rolling_update() {
    local project_name=$(get_project_name)
    log "INFO" "Starting rolling update for project: $project_name"
    
    # Check if we're using blue-green naming scheme
    if [ "${USE_COLOR_SCHEME}" = true ]; then
        # Check if blue or green container is already running
        CURRENT_COLOR=$(check_blue_green_deployment "$project_name" "$SERVICE_NAME")
        
        if [ -z "$CURRENT_COLOR" ]; then
            # No existing blue/green container, default to blue
            NEW_COLOR="blue"
            INITIAL_DEPLOYMENT=true
        else
            # Use the opposite color
            NEW_COLOR=$(get_deployment_color "$CURRENT_COLOR")
            INITIAL_DEPLOYMENT=false
        fi
        
        DEPLOYMENT_ID="${NEW_COLOR}"
        log "INFO" "Using ${NEW_COLOR} deployment (current: ${CURRENT_COLOR})"
    else
        # Generate deployment ID based on timestamp
        DEPLOYMENT_ID=$(date +%s)
        
        # Check if service is already running
        OLD_CONTAINER_ID=$(find_running_container "$SERVICE_NAME" "$project_name")
        
        if [ -z "$OLD_CONTAINER_ID" ]; then
            log "INFO" "No existing service found. Proceeding with initial deployment."
            INITIAL_DEPLOYMENT=true
        else
            INITIAL_DEPLOYMENT=false
            OLD_SERVICE=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' $OLD_CONTAINER_ID)
            OLD_PROJECT=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' $OLD_CONTAINER_ID)
            log "INFO" "Found existing service: $OLD_SERVICE in project $OLD_PROJECT"
        fi
    fi
    
    NEW_SERVICE="${SERVICE_NAME}-${DEPLOYMENT_ID}"
    
    # Create temporary compose file
    create_temp_compose "$DEPLOYMENT_ID" "$SERVICE_NAME" "$COMPOSE_FILE" "$DOMAIN" "$PORT"
    
    # Build and start new version
    log "INFO" "Building and starting new version..."
    if [ "${USE_COLOR_SCHEME}" = true ]; then
        COMPOSE_PROJECT_NAME="${project_name}-${NEW_COLOR}" $DOCKER_COMPOSE -f docker-compose.rolling.yml build --no-cache
        COMPOSE_PROJECT_NAME="${project_name}-${NEW_COLOR}" $DOCKER_COMPOSE-f docker-compose.rolling.yml up -d
    else
        COMPOSE_PROJECT_NAME="${project_name}-${DEPLOYMENT_ID}" $DOCKER_COMPOSE -f docker-compose.rolling.yml build --no-cache
        COMPOSE_PROJECT_NAME="${project_name}-${DEPLOYMENT_ID}" $DOCKER_COMPOSE -f docker-compose.rolling.yml up -d
    fi
    
    # Get new container ID
    if [ "${USE_COLOR_SCHEME}" = true ]; then
        NEW_CONTAINER_ID=$(find_running_container "$SERVICE_NAME" "${project_name}-${NEW_COLOR}")
    else
        NEW_CONTAINER_ID=$(find_running_container "$SERVICE_NAME" "${project_name}-${DEPLOYMENT_ID}")
    fi
    
    if [ -z "$NEW_CONTAINER_ID" ]; then
        log "ERROR" "Failed to start new container"
        exit 1
    fi
    
    # If this is an initial deployment, no need for gradual traffic shifting
    if [ "$INITIAL_DEPLOYMENT" = true ]; then
        log "SUCCESS" "Initial deployment complete. Service is available at https://${DOMAIN}"
        rm docker-compose.rolling.yml
        exit 0
    fi
    
    # Check if new container is healthy
    if ! check_container_health "$NEW_CONTAINER_ID" "$HEALTH_CHECK_PATH" "$PORT" "$HEALTH_CHECK_TIMEOUT"; then
        log "ERROR" "New container is not healthy. Rolling back..."
        if [ "${USE_COLOR_SCHEME}" = true ]; then
            COMPOSE_PROJECT_NAME="${project_name}-${NEW_COLOR}" $DOCKER_COMPOSE -f docker-compose.rolling.yml down
        else
            COMPOSE_PROJECT_NAME="${project_name}-${DEPLOYMENT_ID}" $DOCKER_COMPOSE -f docker-compose.rolling.yml down
        fi
        rm docker-compose.rolling.yml
        log "INFO" "Rollback complete. Still using old version."
        exit 1
    fi
    
    # Get old service details for traffic shifting
    if [ "${USE_COLOR_SCHEME}" = true ]; then
        OLD_SERVICE="${project_name}-${CURRENT_COLOR}_${SERVICE_NAME}"
        NEW_SERVICE="${project_name}-${NEW_COLOR}_${SERVICE_NAME}"
    else
        if [ -n "$OLD_CONTAINER_ID" ]; then
            OLD_SERVICE="${OLD_PROJECT}_${OLD_SERVICE}"
            NEW_SERVICE="${project_name}-${DEPLOYMENT_ID}_${SERVICE_NAME}"
        fi
    fi
    
    if [ "${NO_SHIFT}" = true ]; then
        # Direct switch without gradual transition
        log "INFO" "Performing direct switch to new version (no gradual shifting)"
        create_weighted_config "${OLD_SERVICE}" "${NEW_SERVICE}" "$DOMAIN" 0 100 "$project_name"
    else
        # Gradually shift traffic from old to new
        for i in $(seq 0 20 100); do
            OLD_WEIGHT=$((100 - i))
            NEW_WEIGHT=$i
            
            create_weighted_config "${OLD_SERVICE}" "${NEW_SERVICE}" "$DOMAIN" $OLD_WEIGHT $NEW_WEIGHT "$project_name"
            
            sleep $TRAFFIC_SHIFT_INTERVAL
        done
    fi
    
    log "SUCCESS" "Traffic fully shifted to new version."
    
    # Clean up old container
    log "INFO" "Removing old container..."
    if [ "${USE_COLOR_SCHEME}" = true ]; then
        $DOCKER_COMPOSE -p "${project_name}-${CURRENT_COLOR}" down
    else
        if [ -n "$OLD_CONTAINER_ID" ]; then
            docker stop $OLD_CONTAINER_ID
            docker rm $OLD_CONTAINER_ID
        fi
    fi
    
    # Clean up temporary files
    rm docker-compose.rolling.yml
    rm "${DYNAMIC_CONF_DIR}/weighted-${project_name}.yml"
    
    log "SUCCESS" "Rolling update complete! New version is now serving 100% of traffic."
}

# Main function
main() {
    parse_args "$@"
    check_requirements
    perform_rolling_update
}

# Execute main function with all arguments
main "$@"