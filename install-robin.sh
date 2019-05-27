#!/usr/bin/bash

echoerr() { printf "${RED}Failed${NC}\nError: %s\n" "$*" >&2; }
echowarn() { printf "${YELLOW}Warning: %s${NC}\n" "$*" >&2; }

LOGFILE="/tmp/robin-install.log"
NAMESPACE="robinio"
function validate_k8s_cluster() {
    # Check kubectl
    OIFS=$IFS
    IFS=$'\n'
    get_kube_command
    $KUBE_COMMAND get nodes > /dev/null
    if [[ $? != 0 ]]; then
        echoerr "$KUBE_COMMAND failed to run."
        exit 1
    fi

    out=($($KUBE_COMMAND get nodes -o custom-columns=Name:.metadata.name,OSImage:.status.nodeInfo.osImage,KubeVersion:.status.nodeInfo.kubeProxyVersion,CPU:.status.capacity.cpu,Memory:.status.capacity.memory,providerID:.spec.providerID --no-headers | sed -e "s/  /,/g"| tr -s ","))

    if [[ $? != 0 ]]; then
        echoerr "$KUBE_COMMAND failed to run."
        exit 1
    fi

    # Check number of  nodes
    if [[ ${#out[@]} < 3 ]]; then
        echowarn "Robin recommends having 3 or more nodes in kubernetes for high availability"
    fi

    first=true
    k8s_provider=""
    host_type="physical"
    for host in ${out[@]}; do
        IFS=$','
        host="$(echo -e "${host}" | tr -d '[:space:]')"
        hostDetails=(${host})
        hostName=${hostDetails[0]}
        osImage=${hostDetails[1]}
        kubeVersion=${hostDetails[2]}
        cpu=${hostDetails[3]}
        memory=${hostDetails[4]}
        providerID=${hostDetails[5]}
        if [[ "$first" == true ]];  then
            checkOpenShift4=$($KUBE_COMMAND get nodes $hostName -o "jsonpath={.metadata.labels.node\.openshift\.io/os_version}")
            checkOpenShift3=$($KUBE_COMMAND get nodes $hostName -o "jsonpath={.metadata.annotations.node\.openshift\.io/md5sum}")
            if [[ $checkOpenShift3 != "" ]] || [[ $checkOpenShift4 != "" ]]; then
                k8s_provider="openshift"
            else
                checkGKE=$($KUBE_COMMAND get nodes $hostName -o "jsonpath={.metadata.labels.cloud\.google\.com/gke-os-distribution}")
                if [[ $checkGKE != "" ]]; then
                    if [[ $checkGKE == "cos" ]]; then
                        echoerr "Robin is not supported on Container optimized OS"
                        exit 1
                    fi
                    k8s_provider="gke"
                fi
            fi
            if [[ $providerID =~ aws ]]; then
                host_type="ec2"
            elif [[ $providerID =~ gce ]]; then
                host_type="gcp"
            fi
        fi

        # Check kubernetes version
        if ! [[ $kubeVersion =~ v1.1[1-3] ]]; then
            echoerr "Kubernetes version $kubeVersion is not supported for robin installation"
            exit 1
        fi
        # Check min CPU
        if [[ $cpu -lt 2 ]]; then
            echoerr "Kubernetes nodes should have more than 2 CPUs but node has $cpu"
            exit 1
        fi
        #Assume unit is Ki which is always the case
        # Check min memory
        mem=${memory/%Ki/}
        if [[ $mem -lt 4000000 ]]; then
            echoerr "Kubernetes nodes should have more than 4 GB memory"
            exit 1
        fi
    done
    IFS=$OIFS
    echo "Host type=$host_type k8s_provider=$k8s_provider" >> $LOGFILE
}

function validate_perms() {
    if [[ $k8s_provider == 'gke' ]] && [[ $host_type == 'gcp' ]]; then
        which gcloud > /dev/null
        if [[ $? != 0 ]]; then
            return
        fi
        gout=$(gcloud container clusters describe $CLUSTER_NAME --zone $ZONE_NAME)
        echo $gout | grep "https://www.googleapis.com/auth/cloud-platform" > /dev/null 2>&1
        if [[ $? != 0 ]]; then
            echo $gout | grep 'https://www.googleapis.com/auth/compute' > /dev/null 2>&1
            if [[ $? != 0 ]]; then
                echoerr "Robin needs 'Compute Engine: Read Write' and 'Storage: Full' API  access. Alternatively, You can also give 'Full access to cloud APIs'. You can set it while creating GKE cluster by navigating to Create cluster -> nodepool: More options -> Security:Access scopes"
                exit 1
            fi
            echo $gout | egrep 'https://www.googleapis.com/auth/devstorage.full_control|https://www.googleapis.com/auth/devstorage.read_write' > /dev/null 2>&1
            if [[ $? != 0 ]]; then
                echoerr "Robin needs 'Compute Engine: Read Write' and 'Storage: Full' API  access. Alternatively, You can also give 'Full access to cloud APIs'. You can set it while creating GKE cluster by navigating to Create cluster -> nodepool: More options -> Security:Access scopes"
                exit 1
            fi
        fi

    fi
}

function validate_cr_yaml() {
    cr_file=""
    if [[ $k8s_provider == "openshift" ]]; then
        if [[ $host_type == "ec2" ]]; then
            cr_file="robin-aws-openshift.yaml"
            cp -f ${cr_file} ${cr_file}.tmp
            sed -i "s/ACCESS_KEY/$ACCESS_KEY/" ${cr_file}.tmp
            sed -i "s/SECRET_KEY/$SECRET_KEY/" ${cr_file}.tmp
            cr_file=${cr_file}.tmp
        elif [[ $host_type == "physical" ]]; then
            cr_file="robin-onprem-openshift.yaml"
        fi
    elif [[ $k8s_provider == "gke" ]]; then
        cr_file="robin-gke.yaml"
    else
        echoerr "Robin installation via get.robin.io is not supported on this kuberenetes flavor. Please contact robin at slack at https://robinio.slack.com or email at support@robin.io to get installable for this kubernetes flavor"
        exit 1
    fi
}


function install_operator() {
    $KUBE_COMMAND create -f ./robin-operator.yaml >> $LOGFILE
    if [[ $? != 0 ]]; then
        echoerr "Failed to install robin operator"
        exit 1
    fi
    retries="100"
    i="0"

    while [ $i -lt $retries ]
    do
        $KUBE_COMMAND get crd robinclusters.robin.io >> $LOGFILE
        if [[ $? == 0 ]]; then
          break
        fi
        i=$[$i+1]
        sleep 1
    done
}

function install_robin_cluster() {

    $KUBE_COMMAND create -f ./$cr_file >> $LOGFILE
    if [[ $? != 0 ]]; then
        echoerr "Failed to install robin cluster"
        exit 1
    fi

    retries="100"
    i="0"

    while [ $i -lt $retries ]
    do
        master_ip=$($KUBE_COMMAND describe robinclusters -n $NAMESPACE | grep Master | awk -F':' '{print $2}' | tr -d " \n")
        if [[ $? == 0 ]] && [[ $master_ip != ""  ]]; then
          break
        fi
        i=$[$i+1]
        sleep 6
    done
}

function setup_robin_client() {

    uname_s=$(uname -s | tr -d " \n")
    os=""
    if [[ $uname_s == "Darwin" ]]; then
        os="mac"
    elif [[ $uname_s == "Linux" ]]; then
        os="linux"
    else
        echoerr "Robin is installed but robin client is only supported on linux or mac"
        exit 1
    fi

    get_master_ip
    ROBIN_SERVER=$master_ip
    export ROBIN_SERVER
    echo "export ROBIN_SERVER=$master_ip" > ~/robinenv
    while true; do
        out=$(curl -k -s https://$master_ip:29451/api/v3/robin_server)
        if [[ $? == 0 ]]; then
            echo "Robin server is up" >> $LOGFILE
            break
        fi
        echo "Waiting for robin server to come up" >> $LOGFILE
        sleep 5
    done

    $(curl -k -s https://$master_ip:29451/api/v3/robin_server/client/$os -o robin) >> $LOGFILE 2>/dev/null
    if [[ $? != 0 ]]; then
        echowarn "Failed to install robin client. Make sure port 29451 is open to connect"
        return
    fi
    chmod +x robin

    retries="100"
    i="0"

    while [ $i -lt $retries ]
    do
        ./robin login admin --password Robin123 >> $LOGFILE 2>/dev/null
        if [[ $? == 0 ]]; then
            break
        fi
        echo "Failed to login to robin cluster, Retries $i/$retries" >> $LOGFILE
        i=$[$i+1]
        sleep 5
    done
}

function get_master_ip() {
    is_cloud
    if [[ $cloud == 0 ]]; then
        return
    fi
    while true; do
        if [[ $host_type == 'ec2' ]]; then
            lb_hostname=$($KUBE_COMMAND get service -n $NAMESPACE robin-master-lb -o custom-columns=LBHostName:.status.loadBalancer.ingress[*].hostname --no-headers)
        elif [[ $host_type == 'gcp' ]]; then
            lb_hostname=$($KUBE_COMMAND get service -n $NAMESPACE robin-master-lb -o custom-columns=LBHostName:.status.loadBalancer.ingress[*].ip --no-headers)
        fi
        if [[ $? == 0 ]] && [[ ! -z $lb_hostname ]] && [[ $lb_hostname != ""  ]]; then
            echo "Load balancer hostname is $lb_hostname" >> $LOGFILE
            break
        fi
        echo "Waiting for load balancer getting hostname" >> $LOGFILE
        sleep 5
    done
    master_ip=$lb_hostname
}

function is_cloud() {
    if [[ $host_type == 'gcp' ]] || [[ $host_type == 'ec2' ]]; then
        cloud=1
    else
        cloud=0
    fi
}

function handle_license(){
    echo -e "Access to robin command can be enabled by ${YELLOW}'source ~/robinenv'${NC}\n"
    cat << EOF
        Activate your ROBIN cluster license by running the following commands:
        $ ./robin license activate <UUID>

       Note: You can get your UUID after registering on https://get.robin.io. This command will only work if the host on which the
             ROBIN client is running on has an internet connection. If this is not the case please retrieve the license key by following
             the instructions at https://get.robin.io/activate and apply it using the command './robin license apply <key>'
EOF
}

function parse_arguments(){
    for ARGUMENT in "$@"
    do

        KEY=$(echo $ARGUMENT | cut -f1 -d=)
        VALUE=$(echo $ARGUMENT | cut -f2 -d=)

        case "$KEY" in
                -a | --access-key)              ACCESS_KEY=${VALUE} ;;
                -s | --secret-key)              SECRET_KEY=${VALUE} ;;
                -c | --cluster-name)            CLUSTER_NAME=${VALUE} ;;
                -z | --zone-name)               ZONE_NAME=${VALUE} ;;
                -u | --uninstall)               UNINSTALL=1 ;;
                -y | --yes)                     YES=1;;
                -d | --debug)                   set -x;;
                -h | --help)                    help;;
                *)
        esac
    done
}

function help(){
    echo -e "Usage: $0 [-a|--access-key AWS-ACCESS-kEY -s|--secret-key AWS-SECRET-KEY]"
    echo -e "          [-c|--cluster-name GKE-CLUSTER-NAME -z|--zone GKE-CLUSTER-ZONE]"
    echo -e "          [-u|--uninstall] [-y|--yes] [-d|--debug] [-h|--help]"
    exit 0
}

function check_args(){
    if [[ $host_type == 'ec2' ]]; then
        if [[ ! -z $ACCESS_KEY ]]; then
            input_access_key=0
        fi
        access_key_valid=1
        while [[ $access_key_valid  == 1 ]]; do
            if [[ $input_access_key != 0 ]]; then
                echo -n "Enter AWS access key: "
                read ACCESS_KEY
            fi
            ACCESS_KEY="$(echo -e "${ACCESS_KEY}" | tr -d '[:space:]')"
            validate_access_key
            if [[ $access_key_valid  == 1 ]]; then
                echoerr "Access key $ACCESS_KEY invalid"
                if [[ $input_access_key == 0 ]]; then
                    exit 1
                fi
            fi
        done
        if [[ ! -z $SECRET_KEY ]]; then
            input_secret_key=0
        fi
        secret_key_valid=1
        while [[ $secret_key_valid == 1 ]]; do
            if [[ $input_secret_key  != 0 ]]; then
                echo -n "Enter AWS secret key: "
                read SECRET_KEY
            fi
            SECRET_KEY="$(echo -e "${SECRET_KEY}" | tr -d '[:space:]')"
            validate_secret_key
            if [[ $secret_key_valid == 1 ]]; then
                echoerr "Secret key $SECRET_KEY invalid"
                if [[ $input_secret_key == 0 ]]; then
                    exit 1
                fi
            fi
        done
    fi
    if [[ $host_type == 'gcp' ]] && [[ $k8s_provider == 'gke' ]]; then
        which gcloud > /dev/null
        if [[ $? != 0 ]]; then
            echowarn "gcloud not available so cannot verify cluster permissions"
            return
        fi
        if [[ -z $CLUSTER_NAME ]]; then
            echo -n "Enter GKE cluster name: "
            read CLUSTER_NAME
        fi
        if [[ -z $ZONE_NAME ]]; then
            echo -n "Enter GKE zone name: "
            read ZONE_NAME
        fi
    fi
}

function validate_access_key {
    ACCESS_KEY="$(echo -e "${ACCESS_KEY}" | tr -d '[:space:]')"
    if ! [[ $ACCESS_KEY =~ ^[A-Z0-9]{20}\s? ]]; then
        access_key_valid=1
        return
    fi
    access_key_valid=0
}

function validate_secret_key() {
    SECRET_KEY="$(echo -e "${SECRET_KEY}" | tr -d '[:space:]')"
    if ! [[ $SECRET_KEY =~ ^[A-Za-z0-9/+=]{40}\s? ]]; then
        secret_key_valid=1
        return
    fi
    secret_key_valid=0
}

function get_kube_command {
    # Check kubectl
    KUBE_COMMAND="kubectl"
    which kubectl > /dev/null 2>&1
    if [[ $? != 0 ]]; then
        which oc > /dev/null 2>&1
        if [[ $? != 0 ]]; then
            echoerr "kubectl/oc is not found in the path"
            exit 1
         fi
         KUBE_COMMAND="oc"
    fi
}

function uninstall_robin_cluster {
    get_kube_command
    $KUBE_COMMAND delete -f robin-operator.yaml
    while true; do
        $KUBE_COMMAND get ns $NAMESPACE
        if [[ $? != 0 ]]; then
            break
        fi
        sleep 5
    done
}

function confirm_ports {
    if [[ ! -z $YES ]] && [[ $YES == 1 ]]; then
        return
    fi
    is_cloud
    if [[ $cloud == 1 ]]; then
        echo -e "\nConfirm that ports 29451-29463,8300-8301 and 5432 are open between kubernetes nodes"
    fi
    echo -e "Make sure the cluster meets prerequisites mentioned at https://s3-us-west-2.amazonaws.com/robinio-docs/5.1.1/install.html#minimum-node-requirements"
	while true; do
        echo "Type yes to confirm that cluster meets the prerequisites: "
        read var
        if [[ ! -z $var ]] && ([[ $var == 'yes' ]] || [[ $var == 'YES' ]]) ; then
            return
        fi
        if [[ ! -z $var ]] && ([[ $var == 'no' ]] || [[ $var == 'NO' ]]); then
            exit 1
        fi
	done
}

function finish(){
    exit_code=$?
    set +x
    exit ${exit_code}
}


GREEN='\033[0;32m'
YELLOW='\033[1;35m'
RED='\033[0;31m'
NC='\033[0m' # No Color
trap finish EXIT
parse_arguments "$@"
if [[ ! -z $UNINSTALL ]] && [[ $UNINSTALL == 1 ]]; then
    echo -n "Uninstalling Robin cluster......"
    uninstall_robin_cluster
    echo -e "${GREEN}Done${NC}"
    exit 0
fi
echo -n "Validating Kubernetes cluster......"
validate_k8s_cluster
echo -e "${GREEN}Done${NC}"
confirm_ports
check_args
echo -n "Validating kubernetes cluster permissions......"
validate_perms
echo -e "${GREEN}Done${NC}"
echo -n "Validating robin cluster yaml......"
validate_cr_yaml
echo -e "${GREEN}Done${NC}"
echo -n "Installing Robin operator..........."
install_operator
echo -e "${GREEN}Done${NC}"
echo -n "Installing Robin cluster............"
install_robin_cluster
echo -e "${GREEN}Done${NC}"
echo -n "Setting up robin client............"
setup_robin_client
echo -e "${GREEN}Done${NC}\n"
echo -n "Activate robin license............"
echo -e "${YELLOW}Required${NC}\n"
handle_license
