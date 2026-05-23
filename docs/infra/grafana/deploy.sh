#!/bin/bash
# docs/infra/grafana/deploy.sh
# Deploy Grafana provisioning config (datasources, dashboards, alerting, notifiers) to running container.
# Usage: ./deploy.sh
#
# This script:
# 1. Copies provisioning YAML/JSON files into the kyb-infra-grafana container
# 2. Triggers Grafana API hot-reload for dashboards and alerting
#
# See: docs/infra/reviews/grafana-provisioning.md (Section 3.1)
set -euo pipefail

GRAFANA_CONTAINER="kyb-infra-grafana"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROVISIONING_DIR="${SCRIPT_DIR}/provisioning"

echo "=> Syncing provisioning config to ${GRAFANA_CONTAINER}..."
docker cp "${PROVISIONING_DIR}" "${GRAFANA_CONTAINER}:/etc/grafana/provisioning"

echo "=> Triggering dashboard hot-reload via API..."
ADMIN_PASSWORD=$(docker exec "${GRAFANA_CONTAINER}" \
  cat /etc/grafana/grafana.ini 2>/dev/null \
  | grep -oP '(?<=admin_password = ).*' || echo "admin")

# Reload dashboards
docker exec "${GRAFANA_CONTAINER}" \
  curl -s -X POST "http://admin:${ADMIN_PASSWORD}@localhost:3000/api/admin/provisioning/dashboards/reload" \
  -H "Content-Type: application/json" || echo "  WARN: dashboard reload failed (may be expected if no changes)"

# Reload alerting
docker exec "${GRAFANA_CONTAINER}" \
  curl -s -X POST "http://admin:${ADMIN_PASSWORD}@localhost:3000/api/admin/provisioning/alerting/reload" \
  -H "Content-Type: application/json" || echo "  WARN: alerting reload failed (Grafana < 8.x may not support this)"

echo "=> Done. Provisioning config deployed to ${GRAFANA_CONTAINER}."
echo "=> Verify at http://localhost:3000 (data sources, dashboards, alerting)"
