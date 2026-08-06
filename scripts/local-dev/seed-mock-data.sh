#!/bin/bash
# Seeds a small set of mock data into a locally running Fineract instance.
set -euo pipefail

BASE_URL="${BASE_URL:-https://localhost:8443/fineract-provider/api/v1}"
AUTH="${AUTH:-Basic bWlmb3M6cGFzc3dvcmQ=}"
TENANT="${TENANT:-default}"

api() {
    local method=$1 path=$2 body=${3:-}
    curl -sk -X "$method" "$BASE_URL$path" \
        -H 'Content-Type: application/json' \
        -H "Fineract-Platform-TenantId: $TENANT" \
        -H "Authorization: $AUTH" \
        ${body:+-d "$body"}
}

echo "Creating office..."
api POST /offices '{"name":"Mock Branch","parentId":1,"openingDate":"01 January 2020","dateFormat":"dd MMMM yyyy","locale":"en"}'
echo

echo "Creating staff..."
api POST /staff '{"officeId":1,"firstname":"Mock","lastname":"Officer","isLoanOfficer":true,"joiningDate":"01 January 2020","dateFormat":"dd MMMM yyyy","locale":"en"}'
echo

for name in Alice Bob Carol; do
    echo "Creating client $name..."
    api POST /clients "{\"officeId\":1,\"legalFormId\":1,\"firstname\":\"$name\",\"lastname\":\"Mockdata\",\"active\":true,\"activationDate\":\"01 January 2024\",\"dateFormat\":\"dd MMMM yyyy\",\"locale\":\"en\"}"
    echo
done

echo "Clients now in the system:"
api GET '/clients?limit=10'
echo
