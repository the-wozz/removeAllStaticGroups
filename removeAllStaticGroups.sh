#!/bin/bash

# Zachary 'Woz'nicki
# What it do: Removes all Static Groups from a device WITHOUT deleting the computer record...
# Requirements: JQ... (macOS 15 OR Homebrew) This makes reading JSON files sooooo much easier...
version="0.9 (Last Update: 4/2/25)"

# MODIFABLE variables #
# Jamf Pro URL
jamfProURL=
# Jamf Pro API client ID
jamfAPIClient=
# Jamf Pro API client 'secret'
jamfAPIPass=
# 1 = Removes Static Groups IF found | 0 = For Testing Purposes, ONLY prints Static Groups WITHOUT removing
removeFunction=0

# DO NOT TOUCH variables #
# Serial Number of machine running the script
serialNumber=$(/usr/sbin/system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
#serialNumber=$1
# Current date in Epoch time, used for Bearer Token gathering
current_epoch=$(/bin/date +%s)
# JSON for Reference Computer Groups
full_Json=/tmp/full_memberships.json
# end variables #

# checks for stored credentials file to run this between clients
storedCredentialCheck(){
    if [ -f /private/var/credentials.json ]; then
        fileLoc=/private/var/credentials.json
        echo "Stored Credentials FOUND!"
        jamfProURL=$(cat $fileLoc | jq -r '.credentials.url')
            #echo "$jamfProURL"
        jamfAPIClient=$(cat $fileLoc | jq -r '.credentials.client')
            #echo "$jamfAPIClient"
        jamfAPIPass=$(cat $fileLoc | jq -r '.credentials.secret')
            #echo "$jamfAPIPass"
    fi
}

## FUNCTIONS START ##
# Obtains Jamf Pro API Access Token
getAccessToken() {
    echo "Jamf Access Token: Generating..."

    response=$(/usr/bin/curl --retry 5 --retry-max-time 120 -s -L -X POST "$jamfProURL"/api/oauth/token \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "client_id=$jamfAPIClient" \
        --data-urlencode 'grant_type=client_credentials' \
        --data-urlencode "client_secret=$jamfAPIPass")
    accessToken=$(echo "$response" | plutil -extract access_token raw -)
 	token_expires_in=$(echo "$response" | plutil -extract expires_in raw -)
 	token_expiration_epoch=$(($current_epoch + $token_expires_in - 1))

    if [[ -z "$accessToken" ]]; then
        echo "***** Jamf Access Token: NOT GENERATED! Issues MAY occur from HERE forward! *****"
    else
        #echo "ACCESS TOKEN ID: $accessToken" #troubleshooting line
        echo "Jamf Access Token: AQUIRED!"
    fi
}

# check Jamf Pro API access token expiration
checkTokenExpiration() {
        echo "Jamf Access Token: Checking Expiration..."
        if [[ "$token_expiration_epoch" -ge "$current_epoch" ]]; then
            echo "Jamf Access Token: Valid"
        else
            echo "Jamf Acces Token: Expired! Requesting NEW token..."
                getAccessToken
        fi
}


# Jamf Pro API Permission: Read Computers
# Need to grab Computer ID (neccessary for certain API calls) from Jamf Pro Inventory record
jamfInventory(){
    # make sure we have a valid access token before grabbing inventory
    checkTokenExpiration

    echo "STATUS: Grabbing Jamf Pro Inventory information for $serialNumber..."

    inventory=$(/usr/bin/curl -s -L -X GET "$jamfProURL"/JSSResource/computers/serialnumber/"$serialNumber" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer ${accessToken}" )
    #echo $inventory #troubleshooting line

    # parse Computer ID necessary for FileVault 2 key retrieval (WITHOUT plutil due to issues on Brian's VM...)
     computerID=$(echo "$inventory" | grep -o '"id":*[^"]*' | head -n 1 | sed 's/,*$//g' | cut -f2 -d":")
     # alternate command (plutil, preferred way) to get the computer ID
     #computerID=$(echo "$inventory" | plutil -extract "computer"."general"."id" raw -)
         echo "Computer ID: $computerID"
            if [[ -z "$computerID" ]]; then
                echo "*** ERROR: Jamf Computer ID NOT FOUND! Can not continue. Exiting... ****"
                    exit 1
            fi
}

# view Computer Groups of a machine (this includes BOTH Static and Smart...)
viewStatics(){
    echo "Gathering Jamf Pro Group Memberships..."

    checkTokenExpiration 

    # stores array of memberships, id, name, and grouptype to local file
    /usr/bin/curl -s -L -X GET "$jamfProURL"/api/v1/computers-inventory/"$computerID"?section=GROUP_MEMBERSHIPS \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${accessToken}" | jq -r '.groupMemberships[]' >> "$full_Json"

    # finish modifying the JSON file for proper JQ 'reading'
    modifyArray
}

# gets the Static Group Name from the JSON file ($full_Json)
staticName(){
    # determine the length of ONLY Static Groups ('removed' Smart Groups)
    staticLength=$(cat $full_Json | jq 'del(.[] | select(.smartGroup == true))' | jq length)
        echo "Total Static Groups: $staticLength"
    
    # determine if we need to proceed or abandon ship
    [[ "$staticLength" -lt 1 ]] && echo "No Static Groups to remove! Exiting..." && return

    # process each item of the array that is NOT a Smart Group
    for ((i = 0 ; i < staticLength ; i++)); do
        staticName2=$(cat $full_Json | jq 'del(.[] | select(.smartGroup == true))' | jq -r '.['$i'].groupName')
            echo "Static Group: $staticName2"
        staticID=$(cat $full_Json | jq 'del(.[] | select(.smartGroup == true))' | jq -r '.['$i'].groupId')
            echo "Static Group ID: $staticID"

        staticRemove
    done
}

# remove device from Static Group
staticRemove(){
    [[ $removeFunction -eq 0 ]] && echo "*** Remove Function DISABLED! ***" && return
    # make sure Jamf Access Token is valid before attempting to send the API call
    checkTokenExpiration
    echo "STATUS: Attempting to REMOVE $serialNumber from Static Group: '$staticName2'"

        # API PUT attachment
        staticRemove="<computer_group><computer_deletions><computer><serial_number>$serialNumber</serial_number></computer></computer_deletions></computer_group>"
        
        # Jamf Pro API Permission: Update Computer Static Groups
    removeResponse=$(/usr/bin/curl -s -L -o /dev/null -w "%{http_code}" -X PUT "$jamfProURL"/JSSResource/computergroups/id/"$staticID" \
        -H "Authorization: Bearer ${accessToken}" \
        -H "Content-Type: text/xml" \
        -d "${staticRemove}")
            echo "removeResponse var: $removeResponse"

    if [[ "$removeResponse" == 201 ]]; then
        echo "SUCCESS: Removed '$staticName2'!"
    else
        echo "***** FAIL: to Remove '$staticName2' *****"
    fi
}

# modifies array [JSON] to be JQ readable when ouputted from Jamf Pro
# this took wayyy too long :') but should be very beneficial/helpful for JSON processing in future scripts
modifyArray(){
    echo "Modifying JSON array..."
    # add [ to beginning of file
    printf "[\n$(cat "$full_Json")" > $full_Json
    # add comma to each }, except last
    /usr/bin/sed -i -e '$!s/}/},/' $full_Json
    # add ] to end of file
    echo "]" >> "$full_Json" && echo "Modify complete!"

    # further modification of the JSON file, IMPORTANT!
    modifyJSON

    # verify the JQ 'conversion' works by executing the below command
    if [[ $(jq . "$full_Json") && $? -eq 0 ]]; then 
        echo "JQ | Good conversion!"
    else  
        echo "JQ | Unable to proceed. JQ membership conversion FAILED! Exiting..." && exit 1 
    fi
}

# 4/4/25
# checks the group membership JSON file to make sure there are no extra quotes within the name of the Smart/Static Group which will not allow proper reading of the JSON
modifyJSON(){
    echo "Checking JSON for extra quotes in Static Group names..."
    # set IFS to new lines in leiu of spaces (by default)
    IFS=$'\n'
    # grep the 'groupName' key, head grabs the first entry, sed removes the leading whitespace
    groupName=$(cat "$full_Json" | grep groupName)

        for i in $groupName; do
            # modify the string again to remove ALL quotes (in-case there is quotes in the Smart/Static Group)
            groupName2=$(echo "\"$i\"" | tr -d \", | sed 's/groupName: //' | sed 's/^[[:space:]]*//')
                # new string again to put back the quotes in the correct spot and add the comma at the end
                groupName3="  \"groupName\": \"$groupName2\","
                    # test line to make sure the above edits are correct
                    echo modified: "$groupName3"
                    # make a live change to the JSON file via 'sed'
                    sed -i '' 's/'"\"$i"\"'/'"$groupName3"'/' $full_Json
        done
}
## END FUNCTIONS ##

### MEAT ###
echo "$version"
# checks for JQ
echo "Checking 'JQ' requirement..." && [[ $(jq --version) && $? -eq 0 ]] && echo "JQ FOUND!" || echo "JQ NOT found! Exiting..." exit 1
# checks if there is somehow a JSON membership file already on the machine and removes
echo "Checking if prior JSON exists..." && [ -e "$full_Json" ] && rm -rf "$full_Json" && echo "$full_Json FOUND & deleted!"
echo "Utilizing Serial Number: $serialNumber"
storedCredentialCheck
jamfInventory
    viewStatics
        staticName
# echo we are exiting, set a bad access token, delete the json, then exit
echo "Good exit";accessToken="abc";#rm -rf "$full_Json";
exit 0
