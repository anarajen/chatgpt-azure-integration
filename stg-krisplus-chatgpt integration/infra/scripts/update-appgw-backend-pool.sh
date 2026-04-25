#!/bin/bash
# update-appgw-backend-pool.sh
# Updates the Container App backend pool in an Azure Application Gateway.
#
# Called by appgw-backend-update.bicep via Microsoft.Resources/deploymentScripts.
# Required env vars (injected by the deployment script resource):
#   APPGW_RG             - Resource group containing the App Gateway
#   APPGW_NAME           - App Gateway name (e.g. DEVUAT-ASE-APPGWV2-03)
#   POOL_NAME            - Backend pool name (e.g. DEV-KRISPLUS-CHATGPT-POOL)
#   PRIVATE_FQDN         - New FQDN: <containerAppName>.<managedEnvironmentDefaultDomain>
#
# Optional env vars (when set, the script also upserts probe, HTTP settings, listener, rule):
#   HTTP_SETTINGS_NAME   - e.g. DEV-KRISPLUS-CHATGPT-HTTPSetting
#   LISTENER_NAME        - e.g. DEV-KRISPLUS-CHATGPT-LISTENER
#   RULE_NAME            - e.g. DEV-KRISPLUS-CHATGPT-RULE
#   SSL_CERT_NAME        - existing cert on App Gateway (e.g. nonprodkrispaydotcom-sectigo-Expiry-2026)
#   HOSTNAME             - public hostname (e.g. dev-chatgpt.nonprod-krispay.com)
#
# Implementation: manual GET → jq upsert → PUT via az rest
#
#   We do NOT use `az network application-gateway address-pool update` because that
#   command does a full GET+PUT which re-validates ALL existing App Gateway configuration.
#   If the App Gateway has any pre-existing misconfiguration (e.g. a custom error page
#   with an invalid HTTP status code), ARM will reject the entire PUT with
#   ApplicationGatewayCustomErrorStatusCodeIsInvalid — even though we are not touching
#   that configuration at all.
#
#   The manual GET+jq+PUT approach strips invalid customErrorConfigurations (anything
#   other than HttpStatus403 or HttpStatus502) from the body before PUT, allowing the
#   update to proceed. This only removes already-broken configuration that Azure would
#   have rejected on any write anyway.
#
# Retry rationale:
#   The Managed Identity Operator / Network Contributor role assignments (granted by
#   appgw-rbac.bicep so that this script's UAMI can pass the linked-authorization
#   checks on the PUT) may not have propagated through Azure's authorization system
#   by the time this script runs. Azure RBAC propagation typically completes in under
#   2 minutes but can take up to 10. The retry loop handles this window without
#   requiring manual re-runs.

set -euo pipefail

MAX_RETRIES=8
RETRY_DELAY=30    # seconds between retry attempts (total ceiling: ~4 min)
POLL_INTERVAL=15  # seconds between provisioning state polls after PUT
MAX_POLL=40       # maximum poll attempts after PUT (~10 minutes)

echo "=== App Gateway backend pool update ==="
echo "  Resource group : ${APPGW_RG}"
echo "  App Gateway    : ${APPGW_NAME}"
echo "  Pool           : ${POOL_NAME}"
echo "  New FQDN       : ${PRIVATE_FQDN}"

ENABLE_FULL_CONFIG="${HTTP_SETTINGS_NAME:+true}"
if [ "${ENABLE_FULL_CONFIG}" = "true" ]; then
    echo "  HTTP Settings  : ${HTTP_SETTINGS_NAME}"
    echo "  Listener       : ${LISTENER_NAME}"
    echo "  Rule           : ${RULE_NAME}"
    echo "  SSL Cert       : ${SSL_CERT_NAME}"
    echo "  Hostname       : ${HOSTNAME}"
    echo "  Mode           : Full upsert (pool + probe + settings + listener + rule)"
else
    echo "  Mode           : Pool-only upsert (no HTTP_SETTINGS_NAME set)"
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
API_VERSION="2023-05-01"
GATEWAY_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${APPGW_RG}/providers/Microsoft.Network/applicationGateways/${APPGW_NAME}?api-version=${API_VERSION}"

# Use temp files to avoid large variables and shell quoting issues with big JSON bodies
TMPWORK=$(mktemp -d)
trap 'rm -rf "${TMPWORK}"' EXIT
GATEWAY_FILE="${TMPWORK}/gateway.json"
MODIFIED_FILE="${TMPWORK}/modified.json"

for attempt in $(seq 1 "${MAX_RETRIES}"); do
    echo "  Attempt ${attempt}/${MAX_RETRIES}..."

    # ── Step 1: GET current App Gateway configuration ─────────────────────────
    echo "  Fetching current App Gateway configuration..."
    if ! az rest --method GET --uri "${GATEWAY_URL}" --output json > "${GATEWAY_FILE}" 2>&1; then
        echo "  GET failed."
        if [ "${attempt}" -lt "${MAX_RETRIES}" ]; then
            echo "  Waiting ${RETRY_DELAY}s before retry..."
            sleep "${RETRY_DELAY}"
        fi
        continue
    fi

    ETAG=$(jq -r '.etag' "${GATEWAY_FILE}")
    echo "  ETag: ${ETAG}"

    # ── Step 2: Apply mutations via jq ────────────────────────────────────────
    #   a) Update the target backend pool servers to the new private FQDN.
    #   b) Strip any customErrorConfigurations with invalid HTTP status codes.
    #      Azure only accepts HttpStatus403 and HttpStatus502 in this field.
    #      Anything else (e.g. HttpStatus400) causes ARM to reject the entire PUT
    #      with ApplicationGatewayCustomErrorStatusCodeIsInvalid. Stripping them
    #      is safe: the existing configuration is already broken and cannot be
    #      served by Azure regardless.
    # Extract gateway ID for constructing sub-resource references
    GW_ID=$(jq -r '.id' "${GATEWAY_FILE}")
    PROBE_NAME="${POOL_NAME}-HTTPS-pr"

    # Check what exists
    POOL_EXISTS=$(jq --arg n "${POOL_NAME}" \
        '[.properties.backendAddressPools[] | select(.name == $n)] | length' \
        "${GATEWAY_FILE}")

    if [ "${POOL_EXISTS}" -eq 0 ]; then
        echo "  Backend pool '${POOL_NAME}' does not exist — creating..."
    else
        echo "  Backend pool '${POOL_NAME}' exists — updating FQDN..."
    fi

    if [ "${ENABLE_FULL_CONFIG}" = "true" ]; then
        echo "  Patching configuration (upsert pool + probe + settings + listener + rule)..."
    else
        echo "  Patching configuration (upsert pool only)..."
    fi

    if ! jq \
        --arg pool "${POOL_NAME}" \
        --arg fqdn "${PRIVATE_FQDN}" \
        --arg http_settings "${HTTP_SETTINGS_NAME:-}" \
        --arg listener "${LISTENER_NAME:-}" \
        --arg rule "${RULE_NAME:-}" \
        --arg ssl_cert_name "${SSL_CERT_NAME:-}" \
        --arg hostname "${HOSTNAME:-}" \
        --arg probe_name "${PROBE_NAME}" \
        --arg gw_id "${GW_ID}" \
        '
        # Helper: construct a sub-resource ID
        def sub_id(collection; item_name):
            "\($gw_id)/\(collection)/\(item_name)";

        # ── Upsert helper ─────────────────────────────────────────────
        def upsert(arr; $name; new_entry):
            if (arr | map(select(.name == $name)) | length) > 0 then
                arr | map(if .name == $name then new_entry else . end)
            else
                arr + [new_entry]
            end;

        # ── 1. Upsert backend pool ────────────────────────────────────
        .properties.backendAddressPools = upsert(
            .properties.backendAddressPools; $pool;
            {
                "name": $pool,
                "properties": {
                    "backendAddresses": [{"fqdn": $fqdn}]
                }
            }
        ) |

        # ── 2. Upsert health probe (only if full config) ─────────────
        (if $http_settings != "" then
            .properties.probes = upsert(
                (.properties.probes // []); $probe_name;
                {
                    "name": $probe_name,
                    "properties": {
                        "protocol": "Https",
                        "path": "/health",
                        "interval": 30,
                        "timeout": 30,
                        "unhealthyThreshold": 3,
                        "pickHostNameFromBackendHttpSettings": true,
                        "minServers": 0,
                        "match": {}
                    }
                }
            )
        else . end) |

        # ── 3. Upsert HTTP settings (only if full config) ────────────
        (if $http_settings != "" then
            .properties.backendHttpSettingsCollection = upsert(
                .properties.backendHttpSettingsCollection; $http_settings;
                {
                    "name": $http_settings,
                    "properties": {
                        "port": 443,
                        "protocol": "Https",
                        "cookieBasedAffinity": "Disabled",
                        "pickHostNameFromBackendAddress": true,
                        "requestTimeout": 30,
                        "probe": {"id": sub_id("probes"; $probe_name)}
                    }
                }
            )
        else . end) |

        # ── 4. Upsert HTTPS listener (only if full config) ───────────
        (if $listener != "" then
            # Resolve existing IDs from the live config
            (.properties.sslCertificates // [] | map(select(.name == $ssl_cert_name)) | first | .id) as $ssl_cert_id |
            (.properties.frontendIPConfigurations // [] | map(select(.properties.publicIPAddress != null)) | first | .id) as $frontend_ip_id |
            (.properties.frontendPorts // [] | map(select(.properties.port == 443)) | first | .id) as $https_port_id |

            .properties.httpListeners = upsert(
                .properties.httpListeners; $listener;
                {
                    "name": $listener,
                    "properties": {
                        "frontendIPConfiguration": {"id": $frontend_ip_id},
                        "frontendPort": {"id": $https_port_id},
                        "protocol": "Https",
                        "hostName": $hostname,
                        "requireServerNameIndication": true,
                        "sslCertificate": {"id": $ssl_cert_id},
                        "customErrorConfigurations": []
                    }
                }
            )
        else . end) |

        # ── 5. Upsert routing rule (only if full config) ─────────────
        (if $rule != "" then
            # Preserve existing priority or compute next available
            (.properties.requestRoutingRules | map(select(.name == $rule)) | first | .properties.priority // null) as $existing_priority |
            (if $existing_priority != null then $existing_priority
             else ((.properties.requestRoutingRules | map(.properties.priority // 0) | map(select(. < 10000)) | max) + 10) // 100
             end) as $priority |

            .properties.requestRoutingRules = upsert(
                .properties.requestRoutingRules; $rule;
                {
                    "name": $rule,
                    "properties": {
                        "ruleType": "Basic",
                        "priority": $priority,
                        "httpListener": {"id": sub_id("httpListeners"; $listener)},
                        "backendAddressPool": {"id": sub_id("backendAddressPools"; $pool)},
                        "backendHttpSettings": {"id": sub_id("backendHttpSettingsCollection"; $http_settings)}
                    }
                }
            )
        else . end) |

        # ── 6. Strip invalid custom error configs from ALL listeners ──
        .properties.httpListeners = (.properties.httpListeners | map(
            .properties.customErrorConfigurations = (
                (.properties.customErrorConfigurations // []) |
                map(select(.statusCode == "HttpStatus403" or .statusCode == "HttpStatus502"))
            )
        ))
        ' "${GATEWAY_FILE}" > "${MODIFIED_FILE}"; then
        echo "ERROR: jq transformation failed — this is a script bug, not a transient error."
        exit 1
    fi

    # Verify the pool is in the modified config
    POOL_COUNT=$(jq --arg pool "${POOL_NAME}" \
        '[.properties.backendAddressPools[] | select(.name == $pool)] | length' \
        "${MODIFIED_FILE}")
    if [ "${POOL_COUNT}" -eq 0 ]; then
        echo "ERROR: Backend pool '${POOL_NAME}' missing after jq transform — this is a script bug."
        exit 1
    fi

    if [ "${ENABLE_FULL_CONFIG}" = "true" ]; then
        # Verify all 4 additional resources exist
        for check_name_var in HTTP_SETTINGS_NAME LISTENER_NAME RULE_NAME; do
            check_name="${!check_name_var}"
            case "${check_name_var}" in
                HTTP_SETTINGS_NAME) collection="backendHttpSettingsCollection" ;;
                LISTENER_NAME)      collection="httpListeners" ;;
                RULE_NAME)          collection="requestRoutingRules" ;;
            esac
            count=$(jq --arg n "${check_name}" \
                "[.properties.${collection}[] | select(.name == \$n)] | length" \
                "${MODIFIED_FILE}")
            if [ "${count}" -eq 0 ]; then
                echo "ERROR: ${check_name_var}='${check_name}' missing in ${collection} after jq transform."
                exit 1
            fi
        done
        echo "  All 5 sub-resources verified in modified config."
    fi

    # Log any stripped entries so the team knows what was removed
    STRIPPED=$(jq --raw-output '
        .properties.httpListeners[] |
        .name as $ln |
        .properties.customErrorConfigurations // [] |
        map(select(.statusCode != "HttpStatus403" and .statusCode != "HttpStatus502")) |
        select(length > 0) |
        "  [stripped] listener=\($ln) statusCodes=\(map(.statusCode) | join(","))"
    ' "${GATEWAY_FILE}" 2>/dev/null || true)
    if [ -n "${STRIPPED}" ]; then
        echo "  NOTE: Stripped invalid customErrorConfigurations (only 403/502 are valid):"
        echo "${STRIPPED}"
    fi

    # ── Step 3: PUT the modified configuration ────────────────────────────────
    echo "  Applying updated configuration..."
    if ! az rest \
        --method PUT \
        --uri "${GATEWAY_URL}" \
        --headers "Content-Type=application/json" "If-Match=${ETAG}" \
        --body "@${MODIFIED_FILE}" \
        --output none 2>&1; then
        echo "  PUT failed."
        if [ "${attempt}" -lt "${MAX_RETRIES}" ]; then
            echo "  Waiting ${RETRY_DELAY}s for RBAC propagation before retry..."
            sleep "${RETRY_DELAY}"
        fi
        continue
    fi

    # ── Step 4: Poll until provisioning completes ─────────────────────────────
    # App Gateway PUT is asynchronous — the resource enters "Updating" state and
    # must be polled until provisioningState == "Succeeded".
    echo "  Waiting for App Gateway to finish provisioning..."
    for poll_attempt in $(seq 1 "${MAX_POLL}"); do
        sleep "${POLL_INTERVAL}"
        PROV_STATE=$(az rest \
            --method GET \
            --uri "${GATEWAY_URL}" \
            --query "properties.provisioningState" \
            -o tsv 2>/dev/null || echo "Unknown")
        echo "  provisioningState: ${PROV_STATE} (poll ${poll_attempt}/${MAX_POLL})"
        case "${PROV_STATE}" in
            Succeeded)
                if [ "${ENABLE_FULL_CONFIG}" = "true" ]; then
                    echo "=== App Gateway fully configured (pool + probe + settings + listener + rule) ==="
                else
                    echo "=== Backend pool updated successfully ==="
                fi
                exit 0
                ;;
            Failed|Canceled)
                echo "ERROR: App Gateway update ended in state '${PROV_STATE}'."
                exit 1
                ;;
        esac
    done
    echo "  WARNING: Timed out waiting for provisioning to complete. Retrying from GET..."
done

echo "ERROR: Failed to update backend pool after ${MAX_RETRIES} attempts."
echo "       If the last error was LinkedAuthorizationFailed, RBAC may still be propagating."
echo "       Re-run azd provision in a few minutes to retry."
exit 1
