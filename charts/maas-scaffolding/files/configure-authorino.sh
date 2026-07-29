#!/bin/bash

set -e

KUADRANT_NS="kuadrant-system"
RHOAI_NS="redhat-ods-applications"
SVC_NAME="authorino-authorino-authorization"
SECRET_NAME="authorino-server-cert"
ANNOTATION_KEY="service.beta.openshift.io/serving-cert-secret-name"
ANNOTATION="${ANNOTATION_KEY}=${SECRET_NAME}"

CHANGES_MADE=false
MAX_WAIT_SVC=60
MAX_WAIT_SECRET=150
MAX_WAIT_AUTHORINO=60

echo "Waiting for ${SVC_NAME} service to exist..."
attempts=0
until oc get svc "${SVC_NAME}" -n "${KUADRANT_NS}" &>/dev/null; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge "${MAX_WAIT_SVC}" ]; then
    echo "ERROR: Timed out waiting for service ${SVC_NAME} after $((MAX_WAIT_SVC * 5))s"
    exit 1
  fi
  sleep 5
done
echo "Service ${SVC_NAME} found."

CURRENT_ANNOTATION=$(oc get svc "${SVC_NAME}" -n "${KUADRANT_NS}" \
  -o jsonpath="{.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}" 2>/dev/null || true)

if [ "${CURRENT_ANNOTATION}" = "${SECRET_NAME}" ]; then
  echo "Annotation already set correctly on ${SVC_NAME}, skipping."
else
  echo "Annotating ${SVC_NAME} with serving cert..."
  oc annotate svc "${SVC_NAME}" -n "${KUADRANT_NS}" "${ANNOTATION}" --overwrite
  CHANGES_MADE=true
fi

echo "Waiting for ${SECRET_NAME} secret..."
attempts=0
until oc get secret "${SECRET_NAME}" -n "${KUADRANT_NS}" &>/dev/null; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge "${MAX_WAIT_SECRET}" ]; then
    echo "ERROR: Timed out waiting for secret ${SECRET_NAME} after $((MAX_WAIT_SECRET * 2))s"
    exit 1
  fi
  sleep 2
done
echo "Secret ${SECRET_NAME} found."

echo "Waiting for Authorino CR to exist..."
attempts=0
until oc get authorino authorino -n "${KUADRANT_NS}" &>/dev/null; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge "${MAX_WAIT_AUTHORINO}" ]; then
    echo "ERROR: Timed out waiting for Authorino CR after $((MAX_WAIT_AUTHORINO * 5))s"
    exit 1
  fi
  sleep 5
done
echo "Authorino CR found."

CURRENT_TLS_ENABLED=$(oc get authorino authorino -n "${KUADRANT_NS}" \
  -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || true)
CURRENT_CERT_REF=$(oc get authorino authorino -n "${KUADRANT_NS}" \
  -o jsonpath='{.spec.listener.tls.certSecretRef.name}' 2>/dev/null || true)

if [ "${CURRENT_TLS_ENABLED}" = "true" ] && [ "${CURRENT_CERT_REF}" = "${SECRET_NAME}" ]; then
  echo "Authorino TLS already configured correctly, skipping patch."
else
  echo "Patching Authorino TLS configuration..."
  oc patch authorino authorino -n "${KUADRANT_NS}" --type=merge \
    --patch '{"spec":{"listener":{"tls":{"enabled":true,"certSecretRef":{"name":"'"${SECRET_NAME}"'"}}}}}'
  CHANGES_MADE=true
fi

if [ "${CHANGES_MADE}" = "true" ]; then
  echo "Waiting for Authorino rollout..."
  oc rollout status deployment/authorino -n "${KUADRANT_NS}" --timeout=5m

  echo "Restarting ODH controllers due to configuration changes..."
  oc delete pod -n "${RHOAI_NS}" -l app=odh-model-controller --ignore-not-found
  oc delete pod -n "${RHOAI_NS}" -l control-plane=kserve-controller-manager --ignore-not-found
else
  echo "No changes were made, skipping rollout wait and ODH controller restart."
fi

echo "Authorino configuration complete."
