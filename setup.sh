#!/bin/bash
# Setup script to import FreeIPA CA certificate into Keycloak's truststore
# Automatically detects IPA server from .env file
# Run this BEFORE starting containers: ./init.sh

set -e

# Working directory for temporary files
TMP_DIR=$(mktemp -d -t keycloak-cert-setup.XXXXXX)
CERT_FILE="$TMP_DIR/ipa-ca.crt"
CONTAINER_NAME="keycloak"
CONTAINER_CERT_PATH="/tmp/ipa-ca.crt"
CONTAINER_CACERTS="/opt/keycloak/conf/cacerts"
ALIAS="freeipa-ca"
TRUSTSTORE_DIR="./runtime/keycloak_conf"

# Cleanup function to remove temp directory on exit
cleanup() {
    if [ -d "$TMP_DIR" ]; then
        echo "Cleaning up temporary files..."
        rm -rf "$TMP_DIR"
        echo "✓ Cleanup complete"
    fi
}

trap cleanup EXIT

# Function to handle FreeIPA CA certificate import
import_freeipa_ca_cert() {

   # Check if FreeIPA CA certificate already exists in truststore before launching temporary container
    echo "Downloading CA certificate from http://$IPA_SERVER/ipa/config/ca.crt ..."

    if curl -f -k -o "$CERT_FILE" "http://$IPA_SERVER/ipa/config/ca.crt" 2>/dev/null; then
        echo "✓ Certificate downloaded successfully"
    else
        echo "ERROR: Failed to download certificate from http://$IPA_SERVER/ipa/config/ca.crt"
        echo ""
        echo "Please verify:"
        echo "  1. FreeIPA server hostname/IP is correct"
        echo "  2. Server is accessible from this machine"
        echo "  3. FreeIPA web interface is running"
        exit 1
    fi

    if [ -f "$TRUSTSTORE_DIR/cacerts" ]; then
        echo "Checking if FreeIPA CA certificate is already in truststore..."
        if keytool -list -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias  "$ALIAS" >/dev/null 2>&1; then
            echo "✓ Certificate '$ALIAS' already exists in truststore. Skipping certificate import."
            return 0
        else
            echo "Certificate '$ALIAS' not found in truststore. Proceeding with import."
        fi
    fi

    # Check if Keycloak container is running
    if docker ps | grep -q "$CONTAINER_NAME"; then
        echo "ERROR: Keycloak container is running"
        echo "Please stop the containers first: docker compose down"
        exit 1
    fi

    # Start a temporary Keycloak container to extract system cacerts
    echo "Starting temporary Keycloak container to extract system cacerts..."
    TEMP_CONTAINER="keycloak-temp-$(date +%s)"
    docker run -d --name "$TEMP_CONTAINER" --entrypoint sleep quay.io/keycloak/keycloak:latest infinity

    # Wait for container to start
    sleep 5

    # Extract system cacerts from temporary container
    echo "Extracting system cacerts from temporary container..."
    # Prefer Keycloak embedded cacerts if present
    if docker exec "$TEMP_CONTAINER" test -f /opt/keycloak/lib/security/cacerts >/dev/null 2>&1; then
        docker cp "$TEMP_CONTAINER:/opt/keycloak/lib/security/cacerts" "$TMP_DIR/system-cacerts.jks"
        echo "✓ Found cacerts in Keycloak lib directory (/opt/keycloak/lib/security/cacerts)"
    else
        # Search /usr/lib/jvm for any cacerts file in the container using 'find'; fallback to an explicit list of candidate paths
        echo "Searching /usr/lib/jvm inside container for Java cacerts..."
        CONTAINER_CACERTS_PATH=$(docker exec "$TEMP_CONTAINER" sh -c '
            set -e
            # First try find to find any cacerts file
            if command -v find >/dev/null 2>&1; then
                FIND_RESULT=$(find /usr/lib/jvm -type f -name cacerts 2>/dev/null | head -n 1 || true)
                if [ -n "$FIND_RESULT" ]; then
                    echo "$FIND_RESULT"; exit 0
                fi
            fi
            # Not found with find; try list of common candidate locations (ordered)
            CANDIDATES="/usr/lib/jvm/*/lib/security/cacerts /usr/lib/jvm/*/jre/lib/security/cacerts /usr/lib/jvm/*/security/cacerts /usr/lib/jvm/jre-*/lib/security/cacerts /usr/lib/jvm/java-*/lib/security/cacerts /usr/java/jre/lib/security/cacerts /opt/java/openjdk*/lib/security/cacerts" 
            for p in $CANDIDATES; do
                for f in $p; do
                    if [ -f "$f" ]; then
                        echo "$f"; exit 0
                    fi
                done
            done
            # No match: also check a Docker-friendly alternative path sometimes used by keycloak/jdk images
            if [ -f /opt/jdk/lib/security/cacerts ]; then
                echo /opt/jdk/lib/security/cacerts; exit 0
            fi
            true
        ')

        if [ -n "$CONTAINER_CACERTS_PATH" ]; then
            docker cp "$TEMP_CONTAINER:$CONTAINER_CACERTS_PATH" "$TMP_DIR/system-cacerts.jks"
            echo "✓ Found cacerts in container at: $CONTAINER_CACERTS_PATH"
        else
            # Fallback: use host system's cacerts (find a common install dynamically)
            echo "⚠️  Could not find cacerts in container, trying host system cacerts locations..."
            HOST_CACERTS_PATH=$(find /usr/lib/jvm -type f -name cacerts 2>/dev/null | head -n 1 || true)
            if [ -n "$HOST_CACERTS_PATH" ]; then
                cp "$HOST_CACERTS_PATH" "$TMP_DIR/system-cacerts.jks"
                echo "✓ Using host system cacerts: $HOST_CACERTS_PATH"
            else
                # Another try: system default path for RPM-based systems
                if [ -f /etc/pki/java/cacerts ]; then
                    cp /etc/pki/java/cacerts "$TMP_DIR/system-cacerts.jks"
                    echo "✓ Using host system cacerts: /etc/pki/java/cacerts"
                else
                    echo "ERROR: Could not locate any system cacerts in container or host; cannot continue"
                    exit 1
                fi
            fi
        fi
    fi

    # Stop and remove temporary container
    docker stop "$TEMP_CONTAINER" >/dev/null 2>&1
    docker rm "$TEMP_CONTAINER" >/dev/null 2>&1

    mkdir -p "$TRUSTSTORE_DIR"
    cp "$TMP_DIR/system-cacerts.jks" "$TRUSTSTORE_DIR/cacerts"
    chmod 644 "$TRUSTSTORE_DIR/cacerts"

    # Check if certificate already exists in truststore
    echo "Checking if FreeIPA CA certificate is already in truststore..."
    if keytool -list -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias "$ALIAS" >/dev/null 2>&1; then
        echo "✓ Certificate '$ALIAS' already exists in truststore"
        echo "Skipping import."
        echo ""
        # Delete existing certificate
        echo "Removing existing certificate..."
        keytool -delete -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias "$ALIAS"
    else
        echo "Alias '$ALIAS' does not exist, skipping delete step."
    fi

    # Import certificate
    echo "Importing FreeIPA CA certificate into truststore..."
    keytool -import -trustcacerts -alias "$ALIAS" \
        -file "$CERT_FILE" \
        -keystore "$TRUSTSTORE_DIR/cacerts" \
        -storepass changeit \
        -noprompt

    if [ $? -eq 0 ]; then
        echo "✓ Certificate imported successfully!"
    else
        echo "ERROR: Failed to import certificate"
        exit 1
    fi
    echo "Verifying certificate import..."
    keytool -list -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias "$ALIAS" -v 2>&1 | head -10
}

main() {
    cat <<EOF
    
-----------------------------------
Keycloak with freeIPA backend setup
(c) 2025 Jackson Tong
-----------------------------------

EOF

    # Check if any configuration files exist and prompt for overwrite at the beginning
    if [ -f ".env" ] || [ -f "docker-compose.yml" ] || [ -f "./runtime/keycloak_conf/cacerts" ]; then
        read -p "Existing configuration found, do you want to overwrite them? [y/N]: " OVERWRITE_ALL
        if [[ ! "$OVERWRITE_ALL" =~ ^[Yy]$ ]]; then
            echo "Skipping."
            exit 0
        fi

        echo ""

        # Delete runtime/postgres_data if it exists
        if [ -d "./runtime/postgres_data" ]; then
            echo "Deleting existing runtime/postgres_data directory..."
            rm -rf ./runtime/postgres_data
            echo "✓ runtime/postgres_data directory deleted."
        fi
    fi

    # Auto-detect FreeIPA server if the host is already joined to FreeIPA
    if [ -f "/etc/ipa/default.conf" ]; then
        IPA_SERVER=$(grep "^server" /etc/ipa/default.conf 2>/dev/null | cut -d '=' -f2 | tr -d ' ')
        if [ -n "$IPA_SERVER" ]; then
            import_freeipa_ca_cert
        fi
    fi

    # Generate .env file
    cat > .env <<EOF
POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=$(openssl rand -base64 32)
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=$(openssl rand -base64 16)
KC_HOSTNAME=$(hostname -f)
KC_HOSTNAME_INTERNAL=$(hostname -f)
FREEIPA_SERVER_HOST=$IPA_SERVER
FREEIPA_SERVER_IP=$(getent hosts $IPA_SERVER | awk '{print $1}')
KEYCLOAK_HTTP_PORT=8080
KC_HOSTNAME_STRICT=false
EOF
    echo "✓ .env created with updated Keycloak admin variables."

    # Generate docker-compose.yml file using escaped variables for literal text
    cat > docker-compose.yml <<EOF
services:
  keycloak:
      image: quay.io/keycloak/keycloak:latest
      container_name: keycloak
      command: >
          start --http-enabled=true --proxy-headers=xforwarded
      environment:
        - KC_DB=postgres
        - KC_DB_URL=jdbc:postgresql://keycloak-postgres:5432/
        - KC_DB_USERNAME=\${POSTGRES_USER}
        - KC_DB_PASSWORD=\${POSTGRES_PASSWORD}
        - KC_HOSTNAME=\${KC_HOSTNAME}
        - KC_HOSTNAME_STRICT=\${KC_HOSTNAME_STRICT}
        - KC_BOOTSTRAP_ADMIN_USERNAME=\${KC_BOOTSTRAP_ADMIN_USERNAME}
        - KC_BOOTSTRAP_ADMIN_PASSWORD=\${KC_BOOTSTRAP_ADMIN_PASSWORD}
        - KC_SPI_TRUSTSTORE_FILE_ENABLED=true
        - KC_SPI_TRUSTSTORE_FILE_FILE=/opt/keycloak/conf/cacerts
        - KC_SPI_TRUSTSTORE_FILE_PASSWORD=changeit
        - KC_SPI_TRUSTSTORE_FILE_HOSTNAME_VERIFICATION_POLICY=ANY
      ports:
        - "8080:8080"
      volumes:
        - ./runtime/keycloak_conf:/opt/keycloak/conf
      depends_on:
        - keycloak-postgres

  keycloak-postgres:
      image: postgres:15
      container_name: keycloak-postgres
      environment:
        - POSTGRES_DB=\${POSTGRES_DB}
        - POSTGRES_USER=\${POSTGRES_USER}
        - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      ports:
        - "5432:5432"
      volumes:
        - ./runtime/postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ./runtime/postgres_data
EOF
    echo "✓ docker-compose.yml created with default configuration."
}

main "$@"

