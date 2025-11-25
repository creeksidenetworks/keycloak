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

# --- Create .env at the start ---
if [ ! -f ".env" ]; then
    cat > .env <<EOF
POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=$(openssl rand -base64 32)
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=$(openssl rand -base64 16)
KC_HOSTNAME=keycloak.example.com
KC_HOSTNAME_INTERNAL=keycloak.internal.local
FREEIPA_SERVER_HOST=ipa-server.example.com
FREEIPA_SERVER_IP=192.168.1.100
KEYCLOAK_HTTP_PORT=8080
KC_HOSTNAME_STRICT=false
EOF
    echo "✓ .env created with updated Keycloak admin variables"
fi

# Check if docker-compose.yml exists, and generate it if not
if [ ! -f "docker-compose.yml" ]; then
    cat > docker-compose.yml <<EOF
services:
  keycloak:
    image: quay.io/keycloak/keycloak:latest
    container_name: keycloak
    command: >
      start --http-enabled=true --proxy-headers=xforwarded
    environment:
      - KC_DB=postgres
      - KC_DB_URL=jdbc:postgresql://keycloak-postgres:5432/keycloak
      - KC_DB_USERNAME=keycloak
      - KC_DB_PASSWORD=keycloak
      - KC_HOSTNAME=
      - KC_HOSTNAME_STRICT=false
      - KC_BOOTSTRAP_ADMIN_USERNAME=admin
      - KC_BOOTSTRAP_ADMIN_PASSWORD=admin
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
      - POSTGRES_DB=keycloak
      - POSTGRES_USER=keycloak
      - POSTGRES_PASSWORD=keycloak
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
EOF
    echo "✓ docker-compose.yml created with default configuration (no version specified)"
fi

# Cleanup function to remove temp directory on exit
cleanup() {
    if [ -d "$TMP_DIR" ]; then
        echo "Cleaning up temporary files..."
        rm -rf "$TMP_DIR"
        echo "✓ Cleanup complete"
    fi
}
trap cleanup EXIT

echo "=== FreeIPA CA Certificate Import Setup ==="
echo ""
echo "⚠️  IMPORTANT: Run this script BEFORE starting Keycloak containers"
echo "   If containers are running, stop them first: docker compose down"
echo ""

# Check if Keycloak container is running
if docker ps | grep -q "$CONTAINER_NAME"; then
    echo "ERROR: Keycloak container is running"
    echo "Please stop the containers first: docker compose down"
    exit 1
fi
echo "✓ Keycloak container is not running"
echo ""

# Download certificate from FreeIPA
echo "Let's download the FreeIPA CA certificate."
echo ""

# Try to get FreeIPA server from .env file
if [ -f ".env" ]; then
    IPA_SERVER=$(grep "^FREEIPA_SERVER_HOST=" .env | cut -d '=' -f2)
    if [ -n "$IPA_SERVER" ]; then
        echo "Using FreeIPA server from .env: $IPA_SERVER"
    fi
fi

# Prompt if not found
if [ -z "$IPA_SERVER" ]; then
    read -p "Enter your FreeIPA server hostname or IP (e.g., ipa.example.com): " IPA_SERVER
fi

if [ -z "$IPA_SERVER" ]; then
    echo "ERROR: FreeIPA server hostname is required"
    exit 1
fi

echo ""
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

# Copy certificate to container (not needed anymore, we work directly with files)
# echo ""
# echo "Copying certificate to Keycloak container..."
# docker cp "$CERT_FILE" "$CONTAINER_NAME:$CONTAINER_CERT_PATH"
# echo "✓ Certificate copied to container"

# Start a temporary Keycloak container to extract system cacerts
echo ""
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

# Create custom truststore directory if it doesn't exist
TRUSTSTORE_DIR="./runtime/keycloak_conf"
mkdir -p "$TRUSTSTORE_DIR"

# Copy system cacerts as base for custom truststore
cp "$TMP_DIR/system-cacerts.jks" "$TRUSTSTORE_DIR/cacerts"
chmod 644 "$TRUSTSTORE_DIR/cacerts"

# Check if certificate already exists in truststore
echo "Checking if FreeIPA CA certificate is already in truststore..."
if keytool -list -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias "$ALIAS" >/dev/null 2>&1; then
    echo "✓ Certificate '$ALIAS' already exists in truststore"
    echo ""
    read -p "Certificate already imported. Re-import? [y/N]: " REIMPORT
    if [[ ! "$REIMPORT" =~ ^[Yy]$ ]]; then
        echo "Skipping import."
        exit 0
    fi
    # Delete existing certificate
    echo "Removing existing certificate..."
    keytool -delete -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias "$ALIAS"
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

# Verify
echo "Verifying certificate import..."
keytool -list -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias "$ALIAS" -v 2>&1 | head -10

echo "=== Setup Complete ==="
echo "The FreeIPA CA certificate has been imported into Keycloak's truststore."
echo "You can now start the containers:"
echo "   docker compose up -d"

# Add a note about optimized startup
cat <<EOF

=== Optimized Startup ===
After the first successful startup, you can enable optimized startup by updating the docker-compose.yml file:

  command: >
    start --http-enabled=true --proxy-headers=xforwarded --optimized

This will improve startup performance for subsequent runs.
EOF
