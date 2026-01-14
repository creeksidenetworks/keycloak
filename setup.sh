#!/bin/bash

# ==============================================================================
# Keycloak with FreeIPA Backend Setup Script
# ==============================================================================
# This script automates the setup of Keycloak with FreeIPA integration.
# It handles certificate import and generates Docker Compose configuration.
#
# Features:
#   - Auto-detects FreeIPA server or client configuration
#   - Imports FreeIPA CA certificate into Java truststore
#   - Generates .env and docker-compose.yml files
#   - Configures appropriate ports based on installation type
#
# Usage:
#   ./setup.sh -h <external_hostname>
#
# Arguments:
#   -h <hostname>   External hostname for Keycloak (e.g., keycloak.example.com)
#                   This is the hostname users will use to access Keycloak
#   -?              Show this help
#
# Example:
#   ./setup.sh -h keycloak.example.com
#   ./setup.sh -h sso.mycompany.com
#
# The script will auto-detect:
#   - If running on FreeIPA server: Uses local CA cert, port 28080
#   - If running on FreeIPA client: Downloads CA cert from server, port 8080
#
# (c) 2025 Jackson Tong
# ==============================================================================

set -e

# --- Global Variables ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="/opt/keycloak"
LOG_FILE="/tmp/keycloak-setup-$(date +%Y%m%d-%H%M%S).log"
TMP_DIR=""
CERT_FILE=""
CONTAINER_NAME="keycloak"
ALIAS="freeipa-ca"
TRUSTSTORE_DIR="${WORK_DIR}/runtime/keycloak_conf"

# Detection results
IS_IPA_SERVER="false"
IPA_SERVER=""
IPA_SERVER_SPECIFIED=""
KEYCLOAK_HTTP_PORT=""
KC_HOSTNAME=""

# --- Helper Functions ---

show_usage() {
    cat << EOF
Usage: $0 -h <external_hostname> [-s <ipa_server_hostname>]

Arguments:
  -h <hostname>   External hostname for Keycloak (e.g., keycloak.example.com)
                  This is the hostname users will use to access Keycloak
  -s <hostname>   FreeIPA server hostname (optional, will auto-detect if not specified)
                  Use this to override automatic FreeIPA detection
  -?              Show this help

Examples:
  $0 -h keycloak.example.com
  $0 -h sso.mycompany.com -s ipa.example.com

The script will auto-detect FreeIPA configuration if -s is not provided:
  - If running on FreeIPA server: Uses local CA cert, port 28080
  - If running on FreeIPA client: Downloads CA cert from server, port 8080
EOF
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    cleanup
    exit 1
}

# Cleanup function to remove temp directory on exit
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        log "Cleaning up temporary files..."
        rm -rf "$TMP_DIR"
        log "✓ Cleanup complete"
    fi
}

trap cleanup EXIT

# --- Certificate Import Functions ---

import_freeipa_ca_cert() {
    log "Starting FreeIPA CA certificate import..."
    
    # Create temporary directory
    TMP_DIR=$(mktemp -d -t keycloak-cert-setup.XXXXXX)
    CERT_FILE="$TMP_DIR/ipa-ca.crt"

    # Determine certificate source based on scenario
    if [ "$IS_IPA_SERVER" = "true" ]; then
        # Case 1: Running on FreeIPA server - use local certificate
        log "Using local CA certificate from FreeIPA server..."
        if [ -f "/etc/ipa/ca.crt" ]; then
            cp /etc/ipa/ca.crt "$CERT_FILE"
            log "✓ Certificate copied from /etc/ipa/ca.crt"
        else
            error_exit "Local CA certificate not found at /etc/ipa/ca.crt"
        fi
    else
        # Case 2: Running on FreeIPA client - download from server
        log "Downloading CA certificate from http://$IPA_SERVER/ipa/config/ca.crt ..."
        if curl -f -k -o "$CERT_FILE" "http://$IPA_SERVER/ipa/config/ca.crt" 2>/dev/null; then
            log "✓ Certificate downloaded successfully"
        else
            error_exit "Failed to download certificate from http://$IPA_SERVER/ipa/config/ca.crt

Please verify:
  1. FreeIPA server hostname/IP is correct
  2. Server is accessible from this machine
  3. FreeIPA web interface is running"
        fi
    fi

    # If truststore already exists, check if cert is present
    if [ -f "$TRUSTSTORE_DIR/cacerts" ]; then
        log "Checking if FreeIPA CA certificate is already in truststore..."
        if keytool -list -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias "$ALIAS" >/dev/null 2>&1; then
            log "✓ Certificate '$ALIAS' already exists in truststore. Skipping certificate import."
            return 0
        else
            log "Certificate '$ALIAS' not found in truststore. Proceeding with import."
        fi
    fi

    # Check if Keycloak container is running
    if docker ps | grep -q "$CONTAINER_NAME"; then
        error_exit "Keycloak container is running. Please stop the containers first: docker compose down"
    fi

    # Extract system cacerts from Keycloak container
    extract_system_cacerts

    # Import certificate into truststore
    import_certificate_to_truststore
}

mkdir_work_dir() {
    log "Creating work directory $WORK_DIR if it doesn't exist..."
    mkdir -p "$WORK_DIR"
}

install_java() {
    log "Attempting to install Java/JDK..."
    
    # Check if keytool is already available
    if command -v keytool &> /dev/null; then
        log "✓ Java/JDK is already installed"
        return 0
    fi
    
    # Detect OS and install appropriate Java package
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
    else
        log "WARNING: Could not detect OS. Attempting generic installation."
        return 1
    fi
    
    case "$OS_ID" in
        rhel|centos|fedora|rocky|almalinux)
            log "Detected RHEL-based system. Installing java-latest-openjdk..."
            if command -v dnf &> /dev/null; then
                dnf install -y java-latest-openjdk >/dev/null 2>&1
            elif command -v yum &> /dev/null; then
                yum install -y java-latest-openjdk >/dev/null 2>&1
            else
                log "ERROR: Neither dnf nor yum found. Cannot install Java."
                return 1
            fi
            ;;
        debian|ubuntu)
            log "Detected Debian-based system. Installing default-jdk..."
            apt-get update >/dev/null 2>&1
            apt-get install -y default-jdk >/dev/null 2>&1
            ;;
        alpine)
            log "Detected Alpine system. Installing openjdk11..."
            apk add --no-cache openjdk11 >/dev/null 2>&1
            ;;
        *)
            log "WARNING: Unsupported OS: $OS_ID. Java installation may fail."
            return 1
            ;;
    esac
    
    # Verify installation
    if command -v keytool &> /dev/null; then
        log "✓ Java/JDK installed successfully"
        return 0
    else
        log "WARNING: Java/JDK installation failed or keytool not found in PATH"
        return 1
    fi
}

extract_system_cacerts() {
    log "Starting temporary Keycloak container to extract system cacerts..."
    
    local TEMP_CONTAINER="keycloak-temp-$(date +%s)"
    docker run -d --name "$TEMP_CONTAINER" --entrypoint sleep quay.io/keycloak/keycloak:latest infinity

    # Wait for container to start
    sleep 5

    log "Extracting system cacerts from temporary container..."
    
    # Prefer Keycloak embedded cacerts if present
    if docker exec "$TEMP_CONTAINER" test -f /opt/keycloak/lib/security/cacerts >/dev/null 2>&1; then
        docker cp "$TEMP_CONTAINER:/opt/keycloak/lib/security/cacerts" "$TMP_DIR/system-cacerts.jks"
        log "✓ Found cacerts in Keycloak lib directory (/opt/keycloak/lib/security/cacerts)"
    else
        # Search /usr/lib/jvm for any cacerts file in the container
        log "Searching /usr/lib/jvm inside container for Java cacerts..."
        local CONTAINER_CACERTS_PATH=$(docker exec "$TEMP_CONTAINER" sh -c '
            set -e
            # First try find to find any cacerts file
            if command -v find >/dev/null 2>&1; then
                FIND_RESULT=$(find /usr/lib/jvm -type f -name cacerts 2>/dev/null | head -n 1 || true)
                if [ -n "$FIND_RESULT" ]; then
                    echo "$FIND_RESULT"; exit 0
                fi
            fi
            # Not found with find; try list of common candidate locations
            CANDIDATES="/usr/lib/jvm/*/lib/security/cacerts /usr/lib/jvm/*/jre/lib/security/cacerts /usr/lib/jvm/*/security/cacerts /usr/lib/jvm/jre-*/lib/security/cacerts /usr/lib/jvm/java-*/lib/security/cacerts /usr/java/jre/lib/security/cacerts /opt/java/openjdk*/lib/security/cacerts" 
            for p in $CANDIDATES; do
                for f in $p; do
                    if [ -f "$f" ]; then
                        echo "$f"; exit 0
                    fi
                done
            done
            # Also check Docker-friendly alternative path
            if [ -f /opt/jdk/lib/security/cacerts ]; then
                echo /opt/jdk/lib/security/cacerts; exit 0
            fi
            true
        ')

        if [ -n "$CONTAINER_CACERTS_PATH" ]; then
            docker cp "$TEMP_CONTAINER:$CONTAINER_CACERTS_PATH" "$TMP_DIR/system-cacerts.jks"
            log "✓ Found cacerts in container at: $CONTAINER_CACERTS_PATH"
        else
            # Fallback: use host system's cacerts
            log "WARNING: Could not find cacerts in container, trying host system..."
            local HOST_CACERTS_PATH=$(find /usr/lib/jvm -type f -name cacerts 2>/dev/null | head -n 1 || true)
            if [ -n "$HOST_CACERTS_PATH" ]; then
                cp "$HOST_CACERTS_PATH" "$TMP_DIR/system-cacerts.jks"
                log "✓ Using host system cacerts: $HOST_CACERTS_PATH"
            elif [ -f /etc/pki/java/cacerts ]; then
                cp /etc/pki/java/cacerts "$TMP_DIR/system-cacerts.jks"
                log "✓ Using host system cacerts: /etc/pki/java/cacerts"
            else
                # Stop and remove temporary container before error
                docker stop "$TEMP_CONTAINER" >/dev/null 2>&1
                docker rm "$TEMP_CONTAINER" >/dev/null 2>&1
                error_exit "Could not locate any system cacerts in container or host"
            fi
        fi
    fi

    # Stop and remove temporary container
    docker stop "$TEMP_CONTAINER" >/dev/null 2>&1
    docker rm "$TEMP_CONTAINER" >/dev/null 2>&1
    log "✓ Temporary container removed"
}

import_certificate_to_truststore() {
    # Check if keytool is available, if not try to install Java/JDK
    if ! command -v keytool &> /dev/null; then
        log "keytool not found. Attempting to install Java/JDK..."
        if ! install_java; then
            log "WARNING: keytool not found and Java/JDK installation failed."
            log "         Certificate import will be skipped."
            log "         You can manually install Java/JDK and re-run the script to import the certificate."
            return 0
        fi
    fi

    log "Preparing truststore directory..."
    
    mkdir -p "$TRUSTSTORE_DIR"
    cp "$TMP_DIR/system-cacerts.jks" "$TRUSTSTORE_DIR/cacerts"
    chmod 644 "$TRUSTSTORE_DIR/cacerts"

    # Check if certificate already exists in truststore
    log "Checking for existing certificate in truststore..."
    if keytool -list -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias "$ALIAS" >/dev/null 2>&1; then
        log "Certificate '$ALIAS' already exists, removing old certificate..."
        keytool -delete -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias "$ALIAS"
        log "✓ Old certificate removed"
    fi

    # Import certificate
    log "Importing FreeIPA CA certificate into truststore..."
    keytool -import -trustcacerts -alias "$ALIAS" \
        -file "$CERT_FILE" \
        -keystore "$TRUSTSTORE_DIR/cacerts" \
        -storepass changeit \
        -noprompt

    if [ $? -eq 0 ]; then
        log "✓ Certificate imported successfully"
    else
        log "WARNING: Failed to import certificate. The truststore file was created but may not contain the FreeIPA CA certificate."
        log "         You can manually import the certificate using keytool once Java/JDK is installed."
        return 0
    fi 

    # Verify import
    log "Verifying certificate import..."
    keytool -list -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias "$ALIAS" -v 2>&1 | head -10 | tee -a "$LOG_FILE"
}

# --- Configuration Detection ---

detect_freeipa_configuration() {
    # If IPA server was explicitly specified via -s argument, use it
    if [ -n "$IPA_SERVER_SPECIFIED" ]; then
        log "Using FreeIPA server specified via -s argument: $IPA_SERVER_SPECIFIED"
        IPA_SERVER="$IPA_SERVER_SPECIFIED"
        IS_IPA_SERVER="false"
    else
        log "Detecting FreeIPA configuration..."
        
        # Two scenarios:
        #   1) This host IS the FreeIPA server: has 'host' but NO 'server' in default.conf
        #   2) This host is a FreeIPA client: has 'server' keyword pointing to IPA server

        if [ -f "/etc/ipa/default.conf" ]; then
            # Check if this is a FreeIPA client (has 'server' keyword)
            IPA_SERVER=$(grep "^server" /etc/ipa/default.conf 2>/dev/null | cut -d '=' -f2 | tr -d ' ')
            
            if [ -n "$IPA_SERVER" ]; then
                # Case 2: This is a FreeIPA client
                IS_IPA_SERVER="false"
                log "Detected FreeIPA client configuration"
                log "  IPA Server: $IPA_SERVER"
            else
                # Check if this is a FreeIPA server (has 'host' keyword but no 'server')
                local LOCAL_HOST=$(grep "^host" /etc/ipa/default.conf 2>/dev/null | cut -d '=' -f2 | tr -d ' ')
                if [ -n "$LOCAL_HOST" ] && [ -f "/etc/ipa/ca.crt" ]; then
                    # Case 1: This IS the FreeIPA server
                    IS_IPA_SERVER="true"
                    IPA_SERVER="$LOCAL_HOST"
                    log "Detected FreeIPA server installation"
                    log "  Local host: $IPA_SERVER"
                fi
            fi
        else
            log ""
            log "ERROR: FreeIPA configuration not detected"
            log ""
            log "This server must be joined to a FreeIPA domain before running this setup."
            log ""
            log "To join this server to FreeIPA, run:"
            log "  ipa-client-install --server=<ipa-server-fqdn> --domain=<domain>"
            log ""
            log "Or if installing Keycloak on the FreeIPA server itself, ensure FreeIPA"
            log "is properly installed and /etc/ipa/default.conf exists."
            log ""
            log "Alternatively, specify the FreeIPA server hostname using: -s <ipa-server-fqdn>"
            log ""
            exit 1
        fi
    fi

    # Set Keycloak HTTP port based on installation type
    if [ "$IS_IPA_SERVER" = "true" ]; then
        KEYCLOAK_HTTP_PORT=28080
        log "Using port 28080 for Keycloak (port 8080 is used by FreeIPA)"
    else
        KEYCLOAK_HTTP_PORT=8080
    fi
}

# --- Configuration Generation ---

generate_env_file() {
    log "Generating .env file..."
    
    local POSTGRES_PASSWORD=$(openssl rand -base64 32)
    local KC_ADMIN_PASSWORD=$(openssl rand -base64 16)
    local HOSTNAME_INTERNAL=$(hostname -f)
    local IPA_SERVER_IP=""
    
    if [ -n "$IPA_SERVER" ]; then
        # Get IPv4 address only, exclude localhost (127.x.x.x)
        IPA_SERVER_IP=$(getent ahostsv4 "$IPA_SERVER" 2>/dev/null | awk '$2 == "STREAM" {print $1}' | grep -v '^127\.' | head -1)
        if [ -z "$IPA_SERVER_IP" ]; then
            # Fallback: try dig for A record
            IPA_SERVER_IP=$(dig +short -t A "$IPA_SERVER" 2>/dev/null | grep -v '^127\.' | head -1)
        fi
    fi

    cat > "$WORK_DIR/.env" <<EOF
POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=$KC_ADMIN_PASSWORD
KC_HOSTNAME=$KC_HOSTNAME
KC_HOSTNAME_INTERNAL=$HOSTNAME_INTERNAL
FREEIPA_SERVER_HOST=$IPA_SERVER
FREEIPA_SERVER_IP=$IPA_SERVER_IP
KEYCLOAK_HTTP_PORT=$KEYCLOAK_HTTP_PORT
KC_HOSTNAME_STRICT=false
EOF

    log "✓ .env file created at $WORK_DIR/.env"
}

generate_docker_compose() {
    log "Generating docker-compose.yml..."

    cat > "$WORK_DIR/docker-compose.yml" <<'DOCKEREOF'
services:
  keycloak:
      image: quay.io/keycloak/keycloak:latest
      container_name: keycloak
      command: >
          start --http-enabled=true --proxy-headers=xforwarded
      environment:
        - KC_DB=postgres
        - KC_DB_URL=jdbc:postgresql://keycloak-postgres:5432/
        - KC_DB_USERNAME=${POSTGRES_USER}
        - KC_DB_PASSWORD=${POSTGRES_PASSWORD}
        - KC_HOSTNAME=${KC_HOSTNAME}
        - KC_HOSTNAME_STRICT=${KC_HOSTNAME_STRICT}
        - KC_BOOTSTRAP_ADMIN_USERNAME=${KC_BOOTSTRAP_ADMIN_USERNAME}
        - KC_BOOTSTRAP_ADMIN_PASSWORD=${KC_BOOTSTRAP_ADMIN_PASSWORD}
        - KC_SPI_TRUSTSTORE_FILE_ENABLED=true
        - KC_SPI_TRUSTSTORE_FILE_FILE=/opt/keycloak/conf/cacerts
        - KC_SPI_TRUSTSTORE_FILE_PASSWORD=changeit
        - KC_SPI_TRUSTSTORE_FILE_HOSTNAME_VERIFICATION_POLICY=ANY
      ports:
        - "${KEYCLOAK_HTTP_PORT}:8080"
      volumes:
        - /opt/keycloak/runtime/keycloak_conf:/opt/keycloak/conf
        - /opt/keycloak/providers:/opt/keycloak/providers
      depends_on:
        - keycloak-postgres

  keycloak-postgres:
      image: postgres:15
      container_name: keycloak-postgres
      environment:
        - POSTGRES_DB=${POSTGRES_DB}
        - POSTGRES_USER=${POSTGRES_USER}
        - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      ports:
        - "5432:5432"
      volumes:
        - /opt/keycloak/runtime/postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /opt/keycloak/runtime/postgres_data
DOCKEREOF

    log "✓ docker-compose.yml file created at $WORK_DIR/docker-compose.yml"
}

# --- Firewall Configuration ---

configure_firewall() {
    log "Configuring firewall..."
    
    # Check if firewalld is running
    if ! systemctl is-active --quiet firewalld; then
        log "WARNING: firewalld is not running, skipping firewall configuration"
        return 0
    fi
    
    # Check if port is already open
    if firewall-cmd --query-port="${KEYCLOAK_HTTP_PORT}/tcp" >/dev/null 2>&1; then
        log "✓ Port ${KEYCLOAK_HTTP_PORT}/tcp is already open in firewall"
        return 0
    fi
    
    # Open the Keycloak HTTP port
    log "Opening port ${KEYCLOAK_HTTP_PORT}/tcp in firewall..."
    if firewall-cmd --permanent --add-port="${KEYCLOAK_HTTP_PORT}/tcp" >/dev/null 2>&1; then
        firewall-cmd --reload >/dev/null 2>&1
        log "✓ Port ${KEYCLOAK_HTTP_PORT}/tcp opened in firewall"
    else
        log "WARNING: Failed to open port ${KEYCLOAK_HTTP_PORT}/tcp in firewall"
        log "         You may need to manually open the port:"
        log "         firewall-cmd --permanent --add-port=${KEYCLOAK_HTTP_PORT}/tcp && firewall-cmd --reload"
    fi
}

# --- Summary Display ---

show_summary() {
    local KC_ADMIN_PASSWORD=$(grep KC_BOOTSTRAP_ADMIN_PASSWORD "$WORK_DIR/.env" | cut -d '=' -f2)
    local HOSTNAME_INTERNAL=$(hostname -f)
    
    log ""
    log "==================================================================="
    log "                    SETUP COMPLETE"
    log "==================================================================="
    log ""
    log "Configuration Summary:"
    log "  External Hostname:    $KC_HOSTNAME"
    log "  Internal Hostname:    $HOSTNAME_INTERNAL"
    log "  Keycloak HTTP Port:   $KEYCLOAK_HTTP_PORT"
    log "  FreeIPA Server:       ${IPA_SERVER:-N/A}"
    if [ "$IS_IPA_SERVER" = "true" ]; then
        log "  Installation Type:    On FreeIPA Server"
    else
        log "  Installation Type:    Standalone (FreeIPA Client)"
    fi
    log ""
    log "Generated Files:"
    log "  $WORK_DIR/.env"
    log "                        Environment variables"
    log "  $WORK_DIR/docker-compose.yml"
    log "                        Container configuration"
    if [ -f "$TRUSTSTORE_DIR/cacerts" ]; then
        log "  $TRUSTSTORE_DIR/cacerts"
        log "                        Java truststore with FreeIPA CA"
    fi
    log ""
    log "Keycloak Admin Credentials:"
    log "  Username: admin"
    log "  Password: $KC_ADMIN_PASSWORD"
    log ""
    log "Next Steps:"
    log "  1. Review the generated .env and docker-compose.yml files"
    log "  2. Start the containers: docker compose up -d"
    log "  3. Access Keycloak at: http://$KC_HOSTNAME:$KEYCLOAK_HTTP_PORT"
    log ""
    log "Log file: $LOG_FILE"
    log "==================================================================="
}

# --- Argument Parsing ---

parse_arguments() {
    while getopts "h:s:?" opt; do
        case $opt in
            h)
                KC_HOSTNAME="$OPTARG"
                ;;
            s)
                IPA_SERVER_SPECIFIED="$OPTARG"
                ;;
            \?)
                show_usage
                exit 0
                ;;
            *)
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [ -z "$KC_HOSTNAME" ]; then
        echo "ERROR: External hostname is required (-h option)" >&2
        echo ""
        show_usage
        exit 1
    fi

    # Basic hostname validation
    if [[ ! "$KC_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
        echo "ERROR: Invalid hostname format: $KC_HOSTNAME" >&2
        exit 1
    fi

    # Validate IPA server hostname if specified
    if [ -n "$IPA_SERVER_SPECIFIED" ]; then
        if [[ ! "$IPA_SERVER_SPECIFIED" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
            echo "ERROR: Invalid IPA server hostname format: $IPA_SERVER_SPECIFIED" >&2
            exit 1
        fi
    fi
}

# --- Main Function ---

main() {
    # Parse command line arguments first
    parse_arguments "$@"

    # Create work directory
    mkdir_work_dir

    log "==================================================================="
    log "Keycloak with FreeIPA Backend Setup"
    log "(c) 2025 Jackson Tong"
    log "==================================================================="
    log ""
    log "Starting setup script..."
    log "Log file: $LOG_FILE"
    log "Work directory: $WORK_DIR"
    log "External hostname: $KC_HOSTNAME"
    if [ -n "$IPA_SERVER_SPECIFIED" ]; then
        log "FreeIPA server: $IPA_SERVER_SPECIFIED (specified via -s)"
    fi

    # Check if any configuration files exist and prompt for overwrite
    if [ -f "$WORK_DIR/.env" ] || [ -f "$WORK_DIR/docker-compose.yml" ] || [ -f "$TRUSTSTORE_DIR/cacerts" ]; then
        log "Existing configuration detected"
        read -p "Existing configuration found, do you want to overwrite them? [y/N]: " OVERWRITE_ALL
        if [[ ! "$OVERWRITE_ALL" =~ ^[Yy]$ ]]; then
            log "User chose not to overwrite. Exiting."
            exit 0
        fi

        log "User confirmed overwrite"

        # Delete runtime/postgres_data if it exists
        if [ -d "$WORK_DIR/runtime/postgres_data" ]; then
            log "Deleting existing runtime/postgres_data directory..."
            rm -rf "$WORK_DIR/runtime/postgres_data"
            log "✓ runtime/postgres_data directory deleted"
        fi
    fi

    # Detect FreeIPA configuration
    detect_freeipa_configuration

    # Import FreeIPA CA certificate if IPA is configured
    if [ -n "$IPA_SERVER" ]; then
        import_freeipa_ca_cert || true
    fi

    # Generate configuration files
    generate_env_file
    generate_docker_compose

    # Configure firewall
    configure_firewall

    # Show summary
    show_summary
}

# Execute main function
main "$@"
