#!/bin/bash

# WARNING: This script is provided purely as an example and is not guaranteed to cover all production needs.
# Not all organization-level permissions map directly to project-level permissions.
# Ensure that you thoroughly evaluate existing permissions and determine the appropriate permission mappings.

# Source Terraform Enterprise (TFE) configuration
SRC_TFE_HOSTNAME="${SRC_TFE_HOSTNAME}"
SRC_TFE_ORG="${SRC_TFE_ORG}"
SRC_TFE_TOKEN="${SRC_TFE_TOKEN}"

# Destination HCP Terraform (TFC) or Terraform Enterprise configuration
DST_TFC_HOSTNAME="${DST_TFC_HOSTNAME:-app.terraform.io}"
DST_TFC_ORG="${DST_TFC_ORG}"
DST_TFC_TOKEN="${DST_TFC_TOKEN}"

page_number=1
max_page=5 # Here for development testing and/or chunking out processing
page_size=100

# Function to log messages
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

while true; do
    log "[INFO] Fetching list of Projects..."

    projects_response=$(curl -s -G \
        --header "Authorization: Bearer ${DST_TFC_TOKEN}" \
        --header "Content-Type: application/vnd.api+json" \
        --data-urlencode "page[number]=${page_number}" \
        --data-urlencode "page[size]=${page_size}" \
        "https://${DST_TFC_HOSTNAME}/api/v2/organizations/${DST_TFC_ORG}/projects")

    if $(echo "$projects_response" | jq 'has("errors")'); then
        log "[ERROR] Failed to fetch Projects: $(echo "$projects_response")"
        break
    fi

    echo "$projects_response" | jq -c '.data[]' | while read -r project; do
        project_id=$(echo "$project" | jq -r '.id')
        project_name=$(echo "$project" | jq -r '.attributes.name')

        if [ "$project_name" == "Default Project" ]; then
            continue
        fi

        team_page_number=1

        log "[INFO] Processing Teams for Project [$project_name] ($project_id)"

        while true; do
            # Get the original teams' details from the old Organization
            original_teams_details=$(curl -s -G \
                --header "Authorization: Bearer ${SRC_TFE_TOKEN}" \
                --header "Content-Type: application/vnd.api+json" \
                --data-urlencode "page[number]=$team_page_number" \
                --data-urlencode "page[size]=$page_size" \
                "https://${SRC_TFE_HOSTNAME}/api/v2/organizations/${project_name}/teams")

            echo "$original_teams_details" | jq -c '.data[]' | while read -r team; do
                team_name=$(echo "$team" | jq -r '.attributes.name')

                if [ "$team_name" == "owners" ]; then
                    continue
                fi

                team_payload=$(jq -n \
                    --arg name "$team_name" \
                    --arg visibility "$(echo "$team" | jq -r '.attributes.visibility')" \
                    '{data: {type: "teams", attributes: {name: $name, visibility: $visibility, "organization-access": { "manage-workspaces": false, "manage-projects": false }}}}')

                team_create_response=$(curl -s -X POST \
                    --header "Authorization: Bearer ${DST_TFC_TOKEN}" \
                    --header "Content-Type: application/vnd.api+json" \
                    --data "$team_payload" \
                    "https://${DST_TFC_HOSTNAME}/api/v2/organizations/${DST_TFC_ORG}/teams")

                if $(echo "$team_create_response" | jq 'has("errors")'); then
                    if $(echo "$team_create_response" | jq 'any(.errors[]; .status == "422")'); then
                        log "[INFO] Team [$team_name] already exists, will grant access to Project [$project_name]"
                    else
                        log "[WARN] Failed to create team [$team_name] in organization [$DST_TFC_ORG]: $(echo "$team_create_response")"
                    fi
                fi
                team_id=null
                if echo "$team_create_response" | jq -e 'has("data")' >/dev/null; then
                    log "[INFO] Created Team [$team_name] in Organization [$DST_TFC_ORG]"
                    team_id=$(echo "$team_create_response" | jq -r '.data.id')
                else
                    # team already existed, need to query for its ID
                    # there are ways to optimize this in Bash 4.0+ or other shells
                    # using a "map" object but this is the most portable way to do it
                    team_id=$(curl -s -G \
                        --header "Authorization: Bearer ${DST_TFC_TOKEN}" \
                        --header "Content-Type: application/vnd.api+json" \
                        --data-urlencode "filter[name]=${team_name}" \
                        "https://${DST_TFC_HOSTNAME}/api/v2/organizations/${DST_TFC_ORG}/teams" | jq -r '.data[0].id')
                fi

                # Map old Organization access to new Project access
                # org manage-projects => project admin
                # org manage-workspaces => project maintain
                # org read => project read
                project_access=$(echo "$team" | jq -r \
                    '.attributes | if ."organization-access"."manage-projects" == true then "admin" elif ."organization-access"."manage-workspaces" == true then "maintain" else "read" end')

                access_payload=$(jq -n \
                    --arg project_id "$project_id" \
                    --arg team_id "$team_id" \
                    --arg access "$project_access" \
                    '{data: {type: "team-projects", attributes: {access: $access}, relationships: {project: {data: {type: "projects", id: $project_id}}, team: {data: {type: "teams", id: $team_id}}}}}')

                access_response=$(curl -s -X POST \
                    --header "Authorization: Bearer ${DST_TFC_TOKEN}" \
                    --header "Content-Type: application/vnd.api+json" \
                    --data "$access_payload" \
                    "https://${DST_TFC_HOSTNAME}/api/v2/team-projects")

                if $(echo "$access_response" | jq 'has("errors")'); then
                    if $(echo "$access_response" | jq 'any(.errors[]; .status == "422")'); then
                        log "[INFO] Team [$team_name] access already exists for Project [$project_name], skipping..."
                    else
                        log "[WARN] Failed to create Team [$team_name] access in Project [$project_name]: $(echo "$access_response")"
                    fi
                else
                    log "[INFO] Granted Team [$team_name] [$project_access] permissions for Project [$project_name]"
                fi
            done

            team_page_number=$(echo "$original_teams_details" | jq -r '.meta.pagination."next-page"')
            if [ "$team_page_number" == "null" ]; then
                break
            fi
            # sleep to avoid rate limiting
            sleep 0.3
        done
    done

    log "[INFO] Processed page $page_number of $(echo "$projects_response" | jq -r '.meta.pagination."total-pages"')"

    if [ -n "$max_page" ] && [ "$page_number" -ge "$max_page" ]; then
        log "[INFO] Halting at 'max_page' $max_page"
        break
    else
        page_number=$(echo "$projects_response" | jq -r '.meta.pagination."next-page"')
        if [ "$page_number" == "null" ]; then
            break
        fi
        # sleep to avoid rate limiting
        sleep 0.1
    fi
done

log "[INFO] Finished processing teams"
