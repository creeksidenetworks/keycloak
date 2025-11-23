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
echo "Extracting system cacerts..."
# Try multiple possible locations in the container
if docker exec "$TEMP_CONTAINER" test -f /opt/keycloak/lib/security/cacerts; then
    docker cp "$TEMP_CONTAINER:/opt/keycloak/lib/security/cacerts" "$TMP_DIR/system-cacerts.jks"
    echo "✓ Found cacerts in Keycloak lib directory"
elif docker exec "$TEMP_CONTAINER" test -f /usr/lib/jvm/java-17-openjdk/lib/security/cacerts; then
    docker cp "$TEMP_CONTAINER:/usr/lib/jvm/java-17-openjdk/lib/security/cacerts" "$TMP_DIR/system-cacerts.jks"
    echo "✓ Found cacerts in Java 17 directory"
else
    # Fallback: use host system's cacerts
    echo "⚠️  Could not find cacerts in container, using host system cacerts"
    cp /usr/lib/jvm/java-1.8.0-openjdk-1.8.0.432.b06-3.el9.x86_64/jre/lib/security/cacerts "$TMP_DIR/system-cacerts.jks"
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

echo "✓ Custom truststore created at $TRUSTSTORE_DIR/cacerts"

# Check if certificate already exists in truststore
echo ""
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
echo ""
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
echo ""
echo "Verifying certificate import..."
keytool -list -keystore "$TRUSTSTORE_DIR/cacerts" -storepass changeit -alias "$ALIAS" -v 2>&1 | head -10

echo ""
echo "=== Setup Complete ==="
echo ""
echo "The FreeIPA CA certificate has been imported into Keycloak's truststore."
echo ""
echo "You can now start the containers:"
echo "   docker compose up -d"
echo ""
