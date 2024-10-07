#!/bin/bash

# WARNING: This script is provided purely as an example and must be adapted to cover all production needs.
# This script does not perform all of the `tfm` commands, as each deployment is different. Workspace-level VCS configuration can be copied as well.
# Refer to the tfm documentation (https://hashicorp-services.github.io/tfm) for additional information.

# Source Terraform Enterprise (TFE) configuration
SRC_TFE_HOSTNAME="${SRC_TFE_HOSTNAME}"
SRC_TFE_TOKEN="${SRC_TFE_TOKEN}"

# Destination HCP Terraform (TFC) or Terraform Enterprise configuration
DST_TFC_HOSTNAME="${DST_TFC_HOSTNAME:-app.terraform.io}"
DST_TFC_ORG="${DST_TFC_ORG}"
DST_TFC_TOKEN="${DST_TFC_TOKEN}"

IGNORED_ORGS="${IGNORED_ORGS:-''}"
IGNORED_ORGS_ARRAY=()
IFS=',' read -ra IGNORED_ORGS_ARRAY <<<"$IGNORED_ORGS"
for i in "${!IGNORED_ORGS_ARRAY[@]}"; do
    # Trim leading and trailing whitespace from each ignored organization
    IGNORED_ORGS_ARRAY[$i]=$(echo "${IGNORED_ORGS_ARRAY[$i]}" | awk '{gsub(/^[ \t]+|[ \t]+$/, "")}1')
done

# Executes a Terraform migration command with the specified parameters.
#
# This function sets up the necessary environment variables and then runs the
# Terraform migration script (`tfm`) with the provided arguments.
#
# Arguments:
#   $1 - Source Terraform Enterprise (TFE) organization name.
#   $2 - Destination Terraform Cloud (TFC) project ID.
#   $3 - Additional arguments to pass to the `tfm` script.
#
# Environment Variables:
#   SRC_TFE_HOSTNAME - Hostname of the source TFE instance.
#   SRC_TFE_TOKEN    - API token for the source TFE instance.
#   DST_TFC_HOSTNAME - Hostname of the destination TFC instance.
#   DST_TFC_ORG      - Organization name in the destination TFC instance.
#   DST_TFC_TOKEN    - API token for the destination TFC instance.

execute_tfm_command() {
    SRC_TFE_HOSTNAME="${SRC_TFE_HOSTNAME}" \
        SRC_TFE_ORG="$1" \
        SRC_TFE_TOKEN="${SRC_TFE_TOKEN}" \
        DST_TFC_HOSTNAME="${DST_TFC_HOSTNAME}" \
        DST_TFC_ORG="${DST_TFC_ORG}" \
        DST_TFC_TOKEN="${DST_TFC_TOKEN}" \
        DST_TFC_PROJECT_ID="$2" \
        ./tfm $3
}

# Function to log messages
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

# Fetch all organizations across paginated results
log "[INFO] Fetching all Organizations from ${SRC_TFE_HOSTNAME}..."

page_number=1
ORG_LIST=()
while true; do
    # API request to get organizations
    response=$(curl -s -G \
        --header "Authorization: Bearer $SRC_TFE_TOKEN" \
        --header "Content-Type: application/vnd.api+json" \
        --data-urlencode "page[number]=${page_number}" \
        --data-urlencode "page[size]=${PAGE_SIZE}" \
        "https://${SRC_TFE_HOSTNAME}/api/v2/organizations")

    # Check for errors in the response
    if $(echo "$response" | jq 'has("errors") and (.errors | length > 0)'); then
        log "[ERROR] Failed to retrieve Organizations $(echo "$response")"
        exit 1
    fi

    # Extract organization IDs and add them to ORG_LIST
    org_ids=($(echo "$response" | jq -r '.data[].id'))
    ORG_LIST+=("${org_ids[@]}")

    # Log the page processed
    total_pages=$(echo "$response" | jq -r '.meta.pagination."total-pages"')
    log "[INFO] Processed page $page_number of $total_pages"

    # Check if max page limit is reached
    if [ -n "$MAX_PAGE" ] && [ "$page_number" -ge "$MAX_PAGE" ]; then
        log "[INFO] Halting at MAX_PAGE $MAX_PAGE"
        break
    fi

    # Exit loop if the last page is processed
    next_page=$(echo "$response" | jq -r '.meta.pagination."next-page"')
    if [ "$next_page" == "null" ]; then
        break
    else
        page_number=$next_page
        # Sleep to prevent hitting API rate limits
        sleep 0.1
    fi
done

# Remove ignored organizations and the destination organization from the list
filtered_orgs=()
for org in "${ORG_LIST[@]}"; do
    if [ "$org" != "$DST_TFC_ORG" ] && [[ ! " ${IGNORED_ORGS_ARRAY[@]} " =~ " $org " ]]; then
        filtered_orgs+=("$org")
    else
        log "[INFO] Ignoring Organization $org"
    fi
done

log "[INFO] Found ${#filtered_orgs[@]} Organizations to migrate"

for org in "${filtered_orgs[@]}"; do
    log "[INFO] Migrating Organization $org"

    SRC_TFE_ORG="${org}"
    # Fetch the Project id for the destination Project
    DST_TFC_PROJECT_ID=$(curl -s \
        --header "Authorization: Bearer $DST_TFC_TOKEN" \
        --header "Content-Type: application/vnd.api+json" \
        "https://${DST_TFC_HOSTNAME}/api/v2/organizations/${DST_TFC_ORG}/projects" | jq -r ".data[] | select(.attributes.name == \"${SRC_TFE_ORG}\") | .id")

    # Copy Workspaces
    log "[INFO] Copying Workspaces from ${SRC_TFE_HOSTNAME}/${SRC_TFE_ORG} to ${DST_TFC_HOSTNAME}/${DST_TFC_ORG}/${SRC_TFE_ORG}..."
    execute_tfm_command "$SRC_TFE_ORG" "$DST_TFC_PROJECT_ID" "copy workspaces --autoapprove=true"

    # Copy Variables
    log "[INFO] Copying Variables from ${SRC_TFE_HOSTNAME}/${SRC_TFE_ORG} to ${DST_TFC_HOSTNAME}/${DST_TFC_ORG}/${SRC_TFE_ORG}..."
    execute_tfm_command "$SRC_TFE_ORG" "$DST_TFC_PROJECT_ID" "copy ws --vars --autoapprove=true"

    # Copy Team Access
    log "[INFO] Copying Team Access from ${SRC_TFE_HOSTNAME}/${SRC_TFE_ORG} to ${DST_TFC_HOSTNAME}/${DST_TFC_ORG}/${SRC_TFE_ORG}..."
    execute_tfm_command "$SRC_TFE_ORG" "$DST_TFC_PROJECT_ID" "copy ws --teamaccess --autoapprove=true"

    # Copy State
    log "[INFO] Copying State from ${SRC_TFE_HOSTNAME}/${SRC_TFE_ORG} to ${DST_TFC_HOSTNAME}/${DST_TFC_ORG}/${SRC_TFE_ORG}..."
    execute_tfm_command "$SRC_TFE_ORG" "$DST_TFC_PROJECT_ID" "copy ws --state --autoapprove=true"

    # Copy Variable Sets
    log "[INFO] Copying Variable Sets from ${SRC_TFE_HOSTNAME}/${SRC_TFE_ORG} to ${DST_TFC_HOSTNAME}/${DST_TFC_ORG}/${SRC_TFE_ORG}..."
    execute_tfm_command "$SRC_TFE_ORG" "$DST_TFC_PROJECT_ID" "copy varsets"

    break
done
