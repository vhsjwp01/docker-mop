#!/bin/bash
#set -x
trap f__info EXIT INT

################################################################################
#                      S C R I P T    D E F I N I T I O N
################################################################################
#

#-------------------------------------------------------------------------------
# Revision History
#-------------------------------------------------------------------------------
# 201602l6     Konrad Kleine             Original: https://gist.github.com/kwk/c5443f2a1abcf0eb1eaa
#                                        A script to cleanup untagged docker images
# 20160301     Jason W. Plummer          Modified to fit this template
#

################################################################################
# DESCRIPTION
################################################################################
#

# NAME: remove-orphan-images.sh
#
# This script locates docker containers in a v1 registry path with no referring
# tags, then expunges them
#
# - Gets a list of all images from the registry server storage path
# - Makes a list of all images with tags
# - Subtracts the list of tagged images from the list of all images to create
#   a list of unused images
# - Updates each namespace with the images in use
# - Deletes the untagged images from each namespace
#
# OPTIONS:
#
# --registry-path         - The path to a docker v1 registry storage directory
# --debug                 - Don't actually do anything, just report what would
#                           have been done

################################################################################
# CONSTANTS
################################################################################
#

PATH="/bin:/usr/bin:/usr/local/bin:/sbin:/usr/sbin:/usr/local/sbin"
TERM="vt100"
export TERM PATH

SUCCESS=0
ERROR=1

STDOUT_OFFSET="    "

SCRIPT_NAME="${0}"

USAGE_ENDLINE="\n${STDOUT_OFFSET}${STDOUT_OFFSET}${STDOUT_OFFSET}${STDOUT_OFFSET}"
USAGE="${SCRIPT_NAME}${USAGE_ENDLINE}"
USAGE="${USAGE}[ --registry-path         <The docker v1 registry storage path                      *REQUIRED*> ]${USAGE_ENDLINE}"
USAGE="${USAGE}[ --debug                 <Show what would have been done                           *OPTIONAL*> ]"

################################################################################
# VARIABLES
################################################################################
#

err_msg=""
exit_code=${SUCCESS}

shopt -s nullglob
base_dir=""

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

# WHAT: Subroutine info
# WHY:  This subroutine echos the location of artifacts produced by the script
#
f__info() {

    if [ "${output_dir}" != "" ]; then
        echo -e "\nArtifacts available in directory: \"${output_dir}\""
    fi

}

# WHAT: Subroutine f__image_history
# WHY:  This subroutine echos the location of artifacts produced by the script
#
f__image_history() {
    local readonly image_hash="${1}"
    ${my_jq} '.[]' "${image_dir}/${image_hash}/ancestry" | ${my_tr} -d  '"'
}

################################################################################
# MAIN
################################################################################
#

# WHAT: Make sure we have some useful commands
# WHY:  Cannot proceed otherwise
#
if [ ${exit_code} -eq ${SUCCESS} ]; then

    for command in awk cat cp cut du grep jq ls mktemp rm sed sort tail tr wc xargs ; do
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

            --registry-path)
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

    if [ "${registry_path}" = "" ]; then
        err_msg="Argument --registry-path is required"
        exit_code=${ERROR}
    fi

fi

# WHAT: Check that ${registry_path} is a directory
# WHY:  Cannot proceed otherwise
#
if [ ${exit_code} -eq ${SUCCESS} ]; then

    if [ -d "${registry_path}" ]; then
        base_dir="${registry_path}"
    else
        err_msg="Could not find directory \"${registry_path}\""
        exit_code=${ERROR}
    fi
    
fi

if [ ${exit_code} -eq ${SUCCESS} ]; then
    output_dir="$(${my_mktemp} -d -t trace-images-XXXX)"
    repository_dir="${base_dir}/repositories"

    if [ -d "${repository_dir}" ]; then
        image_dir="${base_dir}/images"
        all_images="${output_dir}/all"
        used_images="${output_dir}/used"
        unused_images="${output_dir}/unused"
        
        echo "Collecting orphan images"
        
        for library in ${repository_dir}/*; do
            echo "Library $(basename ${library})" 
        
            for repo in ${library}/*; do
        
                echo " Repo $(basename ${repo})" 
        
                for tag in ${repo}/tag_*; do
                    echo "  Tag $(basename ${tag})" 
        
                    tagged_image=$(${my_cat} ${tag})
                    f__image_history ${tagged_image}
                done
        
            done
        
        done | ${my_sort} -u > ${used_images}
        
        ${my_ls} ${image_dir} > ${all_images}
        ${my_grep} -v -F -f ${used_images} ${all_images} > ${unused_images}
        
        all_image_count=$(${my_wc} -l ${all_images} | ${my_awk} '{print $1}')
        used_image_count=$(${my_wc} -l ${used_images} | ${my_awk} '{print $1}')
        unused_image_count=$(${my_wc} -l ${unused_images} | ${my_awk} '{print $1}')
        unused_image_size=$(cd ${image_dir} ; ${my_du} -hc $(${my_cat} ${unused_images}) | ${my_tail} -n1 | ${my_cut} -f1)
        
        echo "${all_image_count} images, ${used_image_count} used, ${unused_image_count} unused"
        echo "Unused images consume ${unused_image_size}"
        echo -e "\nTrimming _index_images..."

        unused_images_flatten="${output_dir}/unused.flatten"
        ${my_cat} ${unused_images} | ${my_sed} -e 's/\(.*\)/\"\1\" /' | ${my_tr} -d "\n" > ${unused_images_flatten}
        
        for library in ${repository_dir}/*; do
            echo "Library $(basename $library)"
        
            for repo in ${library}/*; do
                echo " Repo $(basename $repo)"
                mkdir -p "${output_dir}/$(basename $repo)"
                ${my_jq} '.' "${repo}/_index_images" > "${output_dir}/$(basename $repo)/_index_images.old"
                ${my_jq} -s '.[0] - [ .[1:][] | {id: .} ]' "${repo}/_index_images" ${unused_images_flatten} > "${output_dir}/$(basename $repo)/_index_images"
                if [ "${debug}" = "yes" ]; then
                    echo -e "\n    DEBUG: We would run the following command to update repo \"${repo}\":"
                    echo -e "           ${my_cp} \"${output_dir}/$(basename ${repo})/_index_images\" \"${repo}/_index_images\"\n"
                else
                    ${my_cp} "${output_dir}/$(basename ${repo})/_index_images" "${repo}/_index_images"
                fi

            done
        
        done
        
        if [ "${debug}" = "yes" ]; then
            echo -e "\n    DEBUG: We would run the following command to purge images:"
            echo -e "           ${my_cat} ${unused_images} | ${my_xargs} -I{} ${my_rm} -rf ${image_dir}/{}\n"
        else
            echo -e "\nRemoving images"
            ${my_cat} ${unused_images} | ${my_xargs} -I{} ${my_rm} -rf ${image_dir}/{}
        fi

    fi

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
