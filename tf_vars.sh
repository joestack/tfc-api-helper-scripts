#!/bin/bash
#set -o xtrace

##TODOs
# create_varset .. $2 ( global true,false) 

version=230323

created=`date +%d.%m.%y-%H:%M:%S`

workdir=/root
logdir=$workdir/logs

[[ -d $logdir ]] || mkdir $logdir
cd $logdir


check_tfc_token() {
    if [[ ! -e ~/.terraform.d/credentials.tfrc.json ]] ; then
        #echo "No TFC/TFE token found. Please execute 'terraform login'" && exit 1
        exit 1
    else
        tfc_token=$(cat ~/.terraform.d/credentials.tfrc.json | jq -r ".credentials.\"${address}\".token ")
        #echo "Using TFC/TFE token from ~/.terraform.d/credentials.tfrc.json"
    fi
}

check_environment() {
    if [[ ! -e $workdir/environment.conf ]] ; then
        #echo "no environment.conf file found in $workdir" && exit 1
        exit 1
    else
        source $workdir/environment.conf
        #echo "environment.conf successfully sourced."
    fi
}


execute_curl() {
    local token="$1"
    local http_method="$2"
    local url="$3"
    local payload="$4"

    case $http_method in
        GET | DELETE)
            local result=$(curl -Ss \
                --header "Authorization: Bearer ${token}" \
                --header "Content-Type: application/vnd.api+json" \
                --request "${http_method}" \
            "${url}")
            ;;
        PATCH | POST)
            local result=$(curl -Ss \
                --header "Authorization: Bearer ${token}" \
                --header "Content-Type: application/vnd.api+json" \
                --request "${http_method}" \
                --data @${payload} \
            "${url}")
            ;;
        *)
            echo "invalid tf_curl request" && exit 1
    esac

    echo "${result}"
}

create_varset_api() {
    local var_set=$1
    
tee $logdir/varset.json > /dev/null <<EOF

{
  "data": {
    "type": "varsets",
    "attributes": {
      "name": "$var_set",
      "description": "To store the initial Vault root token for further programatic workflows",
      "global": true
    }
  }
}
EOF

local result=$(
        execute_curl $tfc_token "POST" \
                "https://${address}/api/v2/organizations/${organization}/varsets" \
                "varset.json"
        )

}

list_varsets_api() {
    local result=$(
        execute_curl $tfc_token "GET" \
                "https://${address}/api/v2/organizations/${organization}/varsets" \
        )
    echo $result | jq  
    #echo $result | jq -r ".data[] | select (.attributes.name == \"foo\") | .id" 
}

find_varset_api() {
    local var_set=$1
    local result=$(
        execute_curl $tfc_token "GET" \
                "https://${address}/api/v2/organizations/${organization}/varsets" \
        )
    echo $result | jq -r ".data[] | select (.attributes.name == \"$var_set\") | .id" 
}

delete_varset_api() {
    local var_set=$1
    var_set_id=`find_varset_api $1`
    #echo $var_set_id
    if [[ $var_set_id == "" ]]
        then
        echo "nothing to delete because varset does not exist"
        else
        echo "Variable Set $var_set deleted"
        local result=$(
          execute_curl $tfc_token "DELETE" \
                "https://${address}/api/v2/varsets/$var_set_id" \
        ) 
    fi 
}


inject_var_into_varset_api() {
    pit=`date +%s@%N`

    var_set_id=`find_varset_api $var_set`

    tee $logdir/variable-$pit.json > /dev/null <<EOF

{
  "data": {
    "type": "vars",
    "attributes": {
      "key": "$key",
      "value": "$value",
      "description": "",
      "sensitive": $sensitive,
      "category": "$category",
      "hcl": $hcl
    }
  }
}
EOF


    local result=$(
        execute_curl $tfc_token "POST" \
                "https://${address}/api/v2/varsets/$var_set_id/relationships/vars" \
                "variable-$pit.json"
        )

    echo "$(echo -e ${result} | jq -cM '. | @text ')"
    echo "Adding variable $key in category $category "
}

inject_var_into_workspace_api() {
    pit=`date +%s@%N`
    tee $logdir/variable-$pit.json > /dev/null <<EOF
{
  "data": {
    "type":"vars",
    "attributes": {
      "key":"$key",
      "value":"$value",
      "category":"$category",
      "hcl":$hcl,
      "sensitive":$sensitive
    }
  },
  "filter": {
    "organization": {
      "username":"$organization"
    },
    "workspace": {
      "name":"$workspace"
    }
  }
}
EOF


    local result=$(
        execute_curl $tfc_token "POST" \
                "https://${address}/api/v2/vars?filter%5Borganization%5D%5Bname%5D=${organization}&filter%5Bworkspace%5D%5Bname%5D=${workspace}" \
                "variable-$pit.json"
        )

    echo "$(echo -e ${result} | jq -cM '. | @text ')"
    echo "Adding variable $key in category $category "
}



create_varset() {
    create_varset_api $1 
}

list_varsets() {
    list_varsets_api
}

find_varset() {
    find_varset_api $1
}

delete_varset() {
    delete_varset_api $1
}

inject_var_into_varset() {
    echo $1 | while IFS=',' read -r var_set key value category hcl sensitive
    do
        #pit=`date +%s@%N`
        inject_var_into_varset_api $var_set $key $value $category $hcl $sensitive
    done 
}

inject_var_into_workspace() {
    echo $1 | while IFS=',' read -r workspace key value category hcl sensitive
    do
        #pit=`date +%s@%N`
        inject_var_into_workspace_api $workspace $key $value $category $hcl $sensitive
    done 
}

# check_environment
# delete_varset $tfc_var_set
# create_varset $tfc_var_set
# n=1 
# cat /root/vault_init.txt | grep ^"Recovery Key " | awk -F: '{print $2}' |\
#     while read key 
#     do 
#         inject_var_into_varset $tfc_var_set,recovery_key_$n,$key,terraform,false,false
#         n=$(( $n +1 )) 
#     done
# cat /root/vault_init.txt | grep ^"Initial Root Token:" | awk -F: '{print $2}' |\
#     while read token
#     do
#         inject_var_into_varset $tfc_var_set,root_token,$token,terraform,false,false 
#     done 

#### MAIN ####

while getopts "c:f:d:i:l" opt
do
    case $opt in
        c) 
            check_environment
            #check_tfc_token
            create_varset $OPTARG
            ;;
        l)
            check_environment
            #check_tfc_token
            list_varsets
            ;;
        f)
            check_environment
            #check_tfc_token
            find_varset $OPTARG
            ;;
        d)
            check_environment
            #check_tfc_token
            delete_varset $OPTARG
            ;;
        i)
            check_environment
            #check_tfc_token
            inject_var_into_varset $OPTARG
            ;;
        V)
            check_environment
            delete_varset $tfc_var_set
            create_varset $tfc_var_set
            n=1 
            cat /root/vault_init.txt | grep ^"Recovery Key " | awk -F: '{print $2}' |\
                while read key 
                do 
                    inject_var_into_varset $tfc_var_set,recovery_key_$n,$key,terraform,false,false
                    n=$(( $n +1 )) 
                done
            cat /root/vault_init.txt | grep ^"Initial Root Token:" | awk -F: '{print $2}' |\
                while read token
                do
                    inject_var_into_varset $tfc_var_set,root_token,$token,terraform,false,false 
                done
            ;;
        W)
            check_environment
            n=1
            cat /root/vault_init.txt | grep ^"Recovery Key " | awk -F: '{print $2}' |\
                while read key 
                do 
                    inject_var_into_workspace $workspace,recovery_key_$n,$key,terraform,false,false
                    n=$(( $n +1 )) 
                done
            cat /root/vault_init.txt | grep ^"Initial Root Token:" | awk -F: '{print $2}' |\
                while read token
                do
                    inject_var_into_workspace $workspace,root_token,$token,terraform,false,false 
                done
            ;;  
    esac
done

exit 0 

