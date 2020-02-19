#!/bin/bash
#set -x

################################################################################
#                      S C R I P T    D E F I N I T I O N
################################################################################
#

#-------------------------------------------------------------------------------
# Revision History
#-------------------------------------------------------------------------------
# 20160112     Jason W. Plummer          Original: A script to automate Docker
#                                        Registry tag expiry
# 20160129     Jason W. Plummer          Fixed missing debug and added curl
#                                        command status checking
#

################################################################################
# DESCRIPTION
################################################################################
#

# NAME: docker-registry-cleanup.sh
#
# This script automates Docker image tag expiry based on date.  Specifically
# this script does the following:
#
# - Gets a list of all namespaces from the registry server
# - Gets a list of all docker images per namespace
# - Identify all tagged images constructed using 'icg-docker-build'
#   - They will be tagged <YYYYMMDDhhmmss>.<git branch>.<git branch commit hash>
# - Cull old docker_images
#   - Keep newest + past 5
#
# OPTIONS:
#
# --registry-host         - The docker registry host name
# --registry-user         - The user needed for docker registry authentication
# --registry-password     - The password needed for docker registry
#                           authentication
# --max-keeper            - The maxiumum count of repo specific image tags to
#                           retain. Defaults to 6
# --debug                 - Don't actually do anything, just report what would
#                           have been done
#

################################################################################
# CONSTANTS
################################################################################
#

PATH=/bin:/usr/bin:/usr/local/bin:/sbin:/usr/sbin:/usr/local/sbin
TERM=vt100
export TERM PATH

SUCCESS=0
ERROR=1

let DEFAULT_MAX_KEEPER=6

STDOUT_OFFSET="    "

SCRIPT_NAME="${0}"

USAGE_ENDLINE="\n${STDOUT_OFFSET}${STDOUT_OFFSET}${STDOUT_OFFSET}${STDOUT_OFFSET}"
USAGE="${SCRIPT_NAME}${USAGE_ENDLINE}"
USAGE="${USAGE}[ --registry-host         <The docker registry host name                            *REQUIRED*> ]${USAGE_ENDLINE}"
USAGE="${USAGE}[ --registry-user         <The user needed for docker registry authentication       *REQUIRED*> ]${USAGE_ENDLINE}"
USAGE="${USAGE}[ --registry-password     <The password needed for docker registry authentication   *REQUIRED*> ]${USAGE_ENDLINE}"
USAGE="${USAGE}[ --max-keeper            <The maxiumum count of repo specific image tags to retain *OPTIONAL*> ]${USAGE_ENDLINE}"
USAGE="${USAGE}[ --debug                 <Show what would have been done                           *OPTIONAL*> ]"

################################################################################
# VARIABLES
################################################################################
#

err_msg=""
exit_code=${SUCCESS}

################################################################################
# SUBROUTINES
################################################################################
#

# WHAT: Subroutine f__check_command
# WHY:  This subroutine checks the contents of lexically scoped ${1} and then
#       searches ${PATH} for the command.  If found, a variable of the form
#       my_${1} is created.
# NOTE: Lexically scoped ${1} should not be null, otherwise the command for
#       which we are searching is not present via the defined ${PATH} and we
#       should complain
#
f__check_command() {
    return_code=${SUCCESS}
    my_command="${1}"
    this_sed=$(unalias sed > /dev/null 2>&1 ; which sed 2> /dev/null)

    if [ "${this_sed}" = ""  ]; then
        echo "${STDOUT_OFFSET}ERROR:  The command \"sed\" cannot be found"
        return_code=${ERROR}
    else
        if [ "${my_command}" != ""  ]; then
            my_command_check=$(unalias "${my_command}" 2> /dev/null ; which "${my_command}" 2> /dev/null)

            if [ "${my_command_check}" = ""  ]; then
                return_code=${ERROR}
            else
                my_command=$(echo "${my_command}" | ${this_sed} -e 's/[^a-zA-Z0-9]/_/g')
                eval "my_${my_command}=\"${my_command_check}\""
            fi

        else
            echo "${STDOUT_OFFSET}ERROR:  No command was specified"
            return_code=${ERROR}
        fi

    fi

    return ${return_code}
}

################################################################################
# MAIN
################################################################################
#

# WHAT: Make sure we have some useful commands
# WHY:  Cannot proceed otherwise
#
if [ ${exit_code} -eq ${SUCCESS} ]; then

    for command in awk curl egrep jq logger sed sort tail ; do
        unalias ${command} > /dev/null 2>&1
        f__check_command "${command}"

        if [ ${?} -ne ${SUCCESS} ]; then
            let exit_code=${exit_code}+1

            if [ ${exit_code} -ne ${SUCCESS} ]; then
                echo "    ERROR:  Could not locate command \"${command}\""
            fi

        fi

    done

fi

# WHAT: Make sure any passed commands are valid
# WHY:  Cannot continue otherwise
#
if [ ${exit_code} -eq ${SUCCESS} ]; then

    while (( "${#}"  )); do
        key=$(echo "${1}" | ${my_sed} -e 's?\`??g')

        case "${key}" in

            --registry-host|--registry-user|--registry-password|--max-keeper)
                key=$(echo "${key}" | ${my_sed} -e 's?^--??g' -e 's?-?_?g')
                value=$(echo "${2}" | ${my_sed} -e 's?\`??g')

                if [ "${value}" != "" ]; then
                    assign="yes"

                    if [ "${key}" = "max_keeper" ]; then
                        digit_check=$(echo "${value}" | sed -e 's?[^0-9]??g')

                        if [ "${digit_check}" != "${value}" ]; then
                            assign="no"
                        else

                            if [ ${value} -le 0 ]; then
                                assign="no"
                            fi

                        fi

                    fi

                    if [ "${assign}" = "yes" ]; then
                        eval "${key}=\"${value}\""
                        shift
                        shift
                    fi

                else
                    echo "${STDOUT_OFFSET}ERROR:  No value assignment can be made for command line argument \"--${key}\""
                    exit_code=${ERROR}
                    shift
                fi

            ;;

            --debug)
                key=$(echo "${key}" | ${my_sed} -e 's?^--??g' -e 's?-?_?g')
                eval "${key}=\"yes\""
                shift
            ;;

            *)
                # We bail immediately on unknown or malformed inputs
                echo "${STDOUT_OFFSET}ERROR:  Unknown command line argument ... exiting"
                exit
            ;;

        esac

    done

    if [ "${max_keeper}" = "" ]; then
        let max_keeper=${DEFAULT_MAX_KEEPER}
    fi

    if [ "${registry_host}" = "" -o "${registry_user}" = "" -o "${registry_password}" = "" ]; then
        err_msg="Arguments --registry-host, --registry-user, and --registry-password are required"
        exit_code=${ERROR}
    fi

fi

# WHAT: Find expired docker image tags
# WHY:  The reason we are here
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    docker_repos=$(${my_curl} https://${registry_host}/v1/search 2> /dev/null | ${my_jq} ".results[].name" | ${my_sed} -e 's?"??g' | ${my_awk} -F'/' '{print $1}' | ${my_sort} -u)

    for docker_repo in ${docker_repos} ; do
        #echo "Docker Repo: ${docker_repo}"

        docker_images=$(${my_curl} https://${registry_host}/v1/search?q=${docker_repo} 2> /dev/null | ${my_jq} ".results[].name" | ${my_awk} -F'/' '{print $NF}' | ${my_sed} -e 's?"$??g' | ${my_sort} -u)

        for docker_image in ${docker_images} ; do
            #echo "    Docker Image: ${docker_repo}/${docker_image}"
            docker_image_tags=$(${my_curl} https://${registry_host}/v1/repositories/${docker_repo}/${docker_image}/tags 2> /dev/null | ${my_jq} "." | ${my_egrep} "[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.[a-zA-Z0-9\.\-]*\.[a-zA-Z0-9]*\":" | ${my_awk} '{print $1}' | ${my_sed} -e 's?"??g' -e 's?:$??g' | ${my_sort} -u)
            docker_branches=$(echo "${docker_image_tags}" | ${my_awk} -F'.' '{print $2}' | ${my_sort} -u)

            for docker_branch in ${docker_branches} ; do
                #echo -ne "\nBranches (${docker_repo}/${docker_image}):\n${docker_branch}\n"
                #read -p "" discard
                target_tags=$(echo "${docker_image_tags}" | ${my_egrep} "^[0-9]*\.${docker_branch}\.[a-zA-Z0-9]*$" | ${my_sort} -n)
                keepers=$(echo "${target_tags}" | ${my_tail} -${max_keeper} | ${my_sed} -e "s:\(^.*\)\$:${docker_repo}/${docker_image}/\1:g")

                if [ "${keepers}" != "" ]; then
                    #echo -ne "Keepers:\n${keepers}\n"
                    #read -p "" discard

                    for target_tag in ${target_tags} ; do
                        can_delete=$(echo "${keepers}" | ${my_egrep} -c "${docker_repo}/${docker_image}/${target_tag}")

                        if [ ${can_delete} -eq 0 ]; then

                            if [ "${debug}" = "yes" ]; then
                                echo "Can delete \"${docker_repo}/${docker_image}/${target_tag}\""
                            else
                                echo "Deleting docker image tag \"https://${registry_host}/v1/repositories/${docker_repo}/${docker_image}/tags/${target_tag}\"" | ${my_logger} -t "${SCRIPT_NAME}"
                                let command_status=$(${my_curl} --user ${registry_user}:${registry_password} -X DELETE https://${registry_host}/v1/repositories/${docker_repo}/${docker_image}/tags/${target_tag} | ${my_egrep} -c "true")

                                if [ ${command_status} -eq 0 ]; then
                                    echo "    ALERT:  An error was encountered while attempting to delete \"${docker_repo}/${docker_image}/${target_tag}\""
                                fi

                            fi

                        fi

                    done

                fi

            done

        done

    done

fi

# WHAT: Complain if necessary and exit
# WHY:  Success or failure, either way we are through
#
if [ ${exit_code} -ne ${SUCCESS} ]; then

    if [ "${err_msg}" != "" ]; then
        echo
        echo -ne "${STDOUT_OFFSET}ERROR:  ${err_msg} ... processing halted\n"
        echo
    fi

    echo
    echo -ne "${STDOUT_OFFSET}USAGE:  ${USAGE}\n"
    echo
fi

exit ${exit_code}
