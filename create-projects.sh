#!/bin/bash

# WARNING: This script is provided purely as an example and is not guaranteed to cover all production needs.

# Source Terraform Enterprise (TFE) configuration
SRC_TFE_HOSTNAME="${SRC_TFE_HOSTNAME}"
SRC_TFE_ORG="${SRC_TFE_ORG}"
SRC_TFE_TOKEN="${SRC_TFE_TOKEN}"

# Destination HCP Terraform (TFC) or Terraform Enterprise configuration
DST_TFC_HOSTNAME="${DST_TFC_HOSTNAME:-app.terraform.io}"
DST_TFC_ORG="${DST_TFC_ORG}"
DST_TFC_TOKEN="${DST_TFC_TOKEN}"

# Organizations to ignore during migration
IGNORED_ORGS="${IGNORED_ORGS:-''}"
IGNORED_ORGS_ARRAY=()
IFS=',' read -ra IGNORED_ORGS_ARRAY <<<"$IGNORED_ORGS"
for i in "${!IGNORED_ORGS_ARRAY[@]}"; do
    # Trim leading and trailing whitespace from each ignored organization
    IGNORED_ORGS_ARRAY[$i]=$(echo "${IGNORED_ORGS_ARRAY[$i]}" | awk '{gsub(/^[ \t]+|[ \t]+$/, "")}1')
done

# Pagination settings
MAX_PAGE=5 # Set this to limit the number of pages processed; set to null to process all pages
PAGE_SIZE=100

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

# Create a project for each organization in the destination TFC
log "[INFO] Creating Projects for each Organization in ${DST_TFC_HOSTNAME}/${DST_TFC_ORG}..."

for org in "${filtered_orgs[@]}"; do
    payload=$(jq -n --arg name "$org" --arg description "Migrated from ${SRC_TFE_HOSTNAME}/${SRC_TFE_ORG}" \
        '{
   data: {
     attributes: {
       name: $name,
       description: $description
     },
     type: "projects"
   }
 }')

    response=$(curl -s -X POST \
        --header "Authorization: Bearer $DST_TFC_TOKEN" \
        --header "Content-Type: application/vnd.api+json" \
        --data "$payload" \
        "https://${DST_TFC_HOSTNAME}/api/v2/organizations/${DST_TFC_ORG}/projects")

    # Check for errors in the response
    if $(echo "$response" | jq 'has("errors")'); then
        log "[ERROR] Failed to create Project [$org] in Organization [$DST_TFC_ORG] ($(echo "$response"))"
    else
        log "[INFO] Successfully created Project [$org] in Organization [$DST_TFC_ORG]"
    fi

    # Sleep to prevent hitting API rate limits
    sleep 0.1
done

log "[INFO] Project creation completed"
