#!/usr/bin/env bash
# Mirror swim-deploy-openshift-local: make infra-artemis-ssl
# Creates validator-artemis-ssl-secret and provider-artemis-ssl-secret from cert-manager certs.
set -euo pipefail

NS="${1:-swim-demo}"

echo "Namespace: $NS"
echo "Waiting for cert-manager certificates..."

oc wait --for=condition=Ready "certificate/validator-artemis-amqp" -n "$NS" --timeout=600s
oc wait --for=condition=Ready "certificate/provider-artemis-amqp" -n "$NS" --timeout=600s

create_ssl_secret() {
  local cert_name="$1"
  local ssl_secret_name="$2"
  local keystore_pw_secret="$3"

  local KS TS PW
  KS=$(oc get secret "${cert_name}-tls" -n "$NS" -o jsonpath='{.data.keystore\.jks}')
  TS=$(oc get secret "${cert_name}-tls" -n "$NS" -o jsonpath='{.data.truststore\.jks}')
  PW=$(printf '%s' "$(oc get secret "$keystore_pw_secret" -n "$NS" -o jsonpath='{.data.password}' | base64 -d)" | base64 -w0 2>/dev/null || base64)

  oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${ssl_secret_name}
  namespace: ${NS}
type: Opaque
data:
  broker.ks: ${KS}
  client.ts: ${TS}
  keyStorePassword: ${PW}
  trustStorePassword: ${PW}
EOF
  echo "Created ${ssl_secret_name}"
}

create_ssl_secret "validator-artemis-amqp" "validator-artemis-ssl-secret" "validator-artemis-keystore-password"
create_ssl_secret "provider-artemis-amqp" "provider-artemis-ssl-secret" "provider-artemis-keystore-password"

echo "Done."
