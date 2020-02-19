#!/bin/bash
#set -x

SUCCESS=0
ERROR=1

max_age=1

my_docker=`unalias docker 2> /dev/null ; which docker 2> /dev/null`

# Find all ${my_docker} images that are more than ${age} weeks old
if [ "${my_docker}" != "" ]; then

    for i in `${my_docker} images 2> /dev/null | egrep "weeks ago" | awk '{print $(NF-4) ":" $(NF-5)}' | sort -u` ; do
        let image_age=`echo "${i}" | awk -F':' '{print $1}'` 
        image_id=`echo "${i}" | awk -F':' '{print $NF}'` 
    
        if [ ${image_age} -gt ${max_age} ]; then
            echo -ne "Removing docker image ${image_id} because it is ${image_age} weeks old ... "
            docker_output=`${my_docker} rmi ${image_id} 2>&1`
    
            if [ ${?} -ne ${SUCCESS} ]; then
                echo "FAILED"
                container_id=`echo "${docker_output}" | egrep -i "because the container.*.is using it" | awk '{print $(NF-7)}'`
                let multi_container=`echo "${docker_output}" | egrep -ic "because it is tagged in multiple repositories"`
    
                if [ "${container_id}" != "" ]; then
                    let is_active=`${my_docker} ps -a 2> /dev/null | egrep "${container_id}" | egrep -c "Exited.*.weeks ago"`
    
                    if [ ${is_active} -eq 0 ]; then
                        echo -ne "  Removing inactive dependency container ${container_id} as part of docker image ${image_id} cleanup ... "
                        ${my_docker} rm ${container_id} > /dev/null 2>&1
    
                        if [ ${?} -eq ${SUCCESS} ]; then
                            echo "SUCCESS"
                            echo -ne "    Second attempt to remove docker image ${image_id} ... "
                            ${my_docker} rmi ${image_id} > /dev/null 2>&1
    
                            if [ ${?} -eq ${SUCCESS} ]; then
                                echo "SUCCESS"
                            else
                                echo "FAILED"
                            fi
    
                        else
                            echo "FAILED"
                        fi
    
                    else
                        echo "  Docker image ${image_id} is actively being used by container ${container_id}"
                    fi
                    
                fi
    
                if [ ${multi_container} -gt 0 ]; then
                    echo -ne "  Removing docker image ${image_id} by force ... "
                    ${my_docker} rmi -f ${image_id} > /dev/null 2>&1
    
                    if [ ${?} -eq ${SUCCESS} ]; then
                        echo "SUCCESS"
                    else
                        echo "FAILED"
                    fi
    
                fi
    
            else
                echo "SUCCESS"
            fi
    
        fi
    
    done

fi            

exit
