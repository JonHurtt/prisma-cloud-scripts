#!/usr/bin/env bash
#------------------------------------------------------------------------------------------------------------------#
# Written By Jonathan Hurtt
#
# REQUIREMENTS: 
# Requires jq to be installed: 'sudo apt-get install jq'
#
##############################################################################
clear

date=$(date +%Y%m%d)

#Secrets
PC_APIURL="REDACTED"
PC_ACCESSKEY="REDACTED"
PC_SECRETKEY="REDACTED"

#Tag Key Value Pair
KVP_KEY="created-by"
KVP_VALUE="prismacloud-agentless-scan"

#Select CSP from {"aws-" "azure-" "gcp-" "gcloud-" "alibaba-" "oci-"} 
csp_pfix_array=("aws-" "azure-" "gcp-" "gcloud-" "alibaba-" "oci-")

#Define Time Amount and Units for search
TIME_AMOUNT=24
TIME_UNIT="hour"

##############################################################################

TOTAL_RESOURCES=0
TOTAL_ALERTS=0
TOTAL_RESOURCES_WITH_ALERTS=0

#Amount of Time the JWT is valid (10 min) adjust refresh to lower number with slower connections
jwt_token_timeout=600
jwt_token_refresh=590

#Define Folder Locations
OUTPUT_LOCATION=./output
JSON_OUTPUT_LOCATION=./output/json

#Create output folders
mkdir -p ${OUTPUT_LOCATION}
rm -f ${OUTPUT_LOCATION}/*.csv
rm -f ${OUTPUT_LOCATION}/*.json

mkdir -p ${JSON_OUTPUT_LOCATION}
rm -f ${JSON_OUTPUT_LOCATION}/*.json
 
SPACER="===================================================================================================================================="
DIVIDER="++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"

printf "%s\n" ${DIVIDER}
#Begin Applicaiton Timer
start_time=$(date +%Y%m%d-%H:%M:%S)
printf "Start Time: ${start_time}\n"
start=$(date +%s)

#Define Auth Payload for JWT
AUTH_PAYLOAD=$(cat <<EOF
{"username": "${PC_ACCESSKEY}", "password": "${PC_SECRETKEY}"}
EOF
)

#API Call for JWT
PC_JWT_RESPONSE=$(curl -s --request POST \
				   --url "${PC_APIURL}/login" \
				   --header 'Accept: application/json; charset=UTF-8' \
				   --header 'Content-Type: application/json; charset=UTF-8' \
				   --data "${AUTH_PAYLOAD}")


PC_JWT=$(printf %s "${PC_JWT_RESPONSE}" | jq -r '.token')

if [ -z "${PC_JWT}" ]; then
	printf "JWT not recieved, recommending you check your variable assignment\n";
	exit;
else
	printf "JWT Recieved\n"
fi

printf "Assembling list of available APIs...\n"
for csp_indx in "${!csp_pfix_array[@]}"; do \

	config_request_body=$(cat <<EOF
	{
		  "query":"config from cloud.resource where api.name = ${csp_pfix_array[csp_indx]}",
		  "timeRange":{
			"type":"relative",
			"value":{
			   "unit":"${TIME_UNIT}",
			   "amount":${TIME_AMOUNT}
			}
		  }
	}
	EOF
	)
	
	curl --no-progress-meter --url "${PC_APIURL}/search/suggest" \
		-w '{"curl_http_code": %{http_code}}' \
		--header "accept: application/json; charset=UTF-8" \
		--header "content-type: application/json" \
		--header "x-redlock-auth: ${PC_JWT}" \
		--data "${config_request_body}" > "${JSON_OUTPUT_LOCATION}/api_suggestions_${csp_indx}.json"
done
#end iteration through CSP prefix.

rql_api_array=($(cat ${JSON_OUTPUT_LOCATION}/api_suggestions_* | jq -r '.suggestions[]?'))

printf '%s available API endpoints\n' ${#rql_api_array[@]}
printf "%s\n" ${SPACER}
printf "Searching for resources with tags containing key:value of {%s:%s} ... \n"  ${KVP_KEY} ${KVP_VALUE}
printf "%s\n" ${SPACER}

for api_query_indx in "${!rql_api_array[@]}"; do \
	
	rql_request_body=$(cat <<EOF
	{
		  "query":"config from cloud.resource where api.name = ${rql_api_array[api_query_indx]} AND resource.status = Active AND json.rule = tags[?(@.key=='${KVP_KEY}')].value equals ${KVP_VALUE}",
		  "timeRange":{
			"type":"relative",
			"value":{
			"unit":"${TIME_UNIT}",
			"amount":${TIME_AMOUNT}
			}
		  }
	}
	EOF
	)
	
	curl --no-progress-meter --url "${PC_APIURL}/search/config" \
		--header "accept: application/json; charset=UTF-8" \
		--header "content-type: application/json" \
		--header "x-redlock-auth: ${PC_JWT}" \
		--data "${rql_request_body}" > "${JSON_OUTPUT_LOCATION}/api_query_${api_query_indx}.json" &
done
wait

#Create CSV for all resources
printf '%s\n' "cloudType,id,accountId,name,accountName,regionId,regionName,service,resourceType" > "${OUTPUT_LOCATION}/all_cloud_resources_${date}.csv"

cat ${JSON_OUTPUT_LOCATION}/api_query_*.json | jq -r '.data.items[] | {"cloudType": .cloudType, "id": .id, "accountId": .accountId,  "name": .name,  "accountName": .accountName,  "regionId": .regionId,  "regionName": .regionName,  "service": .service, "resourceType": .resourceType }' | jq -r '[.[]] | @csv' >> "${OUTPUT_LOCATION}/all_cloud_resources_${date}.csv"

printf '%s\n' "Inventory Report located at ${OUTPUT_LOCATION}/all_cloud_resources_${date}.csv"
printf "%s\n" ${SPACER}

#Find all Resouce IDs to search for Alerts
resource_id_array=($(cat ${JSON_OUTPUT_LOCATION}/api_query_*.json | jq -r '.data.items[].id'))

printf "Finding all alerts for %s resources found matching key:value of {%s:%s} ...\n" ${#resource_id_array[@]} ${KVP_KEY} ${KVP_VALUE}
printf "%s\n" ${SPACER}

for resource_id_indx in "${!resource_id_array[@]}"; do \
	curl --no-progress-meter\
	   --url "${PC_APIURL}/v2/alert?detailed=true&timeType=relative&timeAmount=${TIME_AMOUNT}&timeUnit=${TIME_UNIT}&resource.id=${resource_id_array[resource_id_indx]}" \
	   --header 'content-type: application/json; charset=UTF-8' \
	   --header "x-redlock-auth: ${PC_JWT}" > "${JSON_OUTPUT_LOCATION}/alerts_${resource_id_indx}.json" &
done


printf '%s\n' "alertId,alertStatus,policyName,policyDesc,policySeverity,cloudType,resourceId,accountId,resourceName,accountName,regionId,regionName,service,resourceType,resourceApiName" > "${OUTPUT_LOCATION}/cloud_resources_with_alerts_$date.csv"

cat ${JSON_OUTPUT_LOCATION}/alerts_*.json | jq -r '.items[] | {"alertId" : .id, "alertStatus" : .status, "policyName" : .policy.name, "policyDesc" : .policy.description, "policySeverity": .policy.severity, "cloudType": .resource.cloudType, "resourceId": .resource.id, "accountId": .resource.accountId,  "resourcenName": .resource.name,  "accountName": .resource.account,  "regionId": .resource.regionId,  "resourceRegion": .resource.region,  "cloudServiceName": .resource.cloudServiceName, "resourceType": .resource.resourceType, "resourceApiName": .resource.resourceApiName }' | jq -r '[.[]] | @csv' >> "${OUTPUT_LOCATION}/cloud_resources_with_alerts_$date.csv"

printf '%s\n' "Full Report located at ${OUTPUT_LOCATION}/cloud_resources_with_alerts_$date.csv"

#rm -f ${JSON_OUTPUT_LOCATION}/*.json

printf '%s\n' ${DIVIDER}
end=$(date +%s)
end_time=$(date +%Y%m%d-%H:%M:%S)
duration=$end-$start

printf "Start Time: ${start_time}\n"
printf "End Time: ${end_time}\n"
printf "%s\n" ${SPACER}
printf "Completed in $(((duration/60))) minutes and $((duration%60)) seconds\n"
printf "Elapsed Time: $(($end-$start)) seconds\n"
printf '%s\n' ${DIVIDER}
printf "Complete - Exiting\n"
printf '%s\n' ${DIVIDER}
exit
#end
