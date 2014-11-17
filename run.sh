#!/bin/bash

CURL_OPTIONS="--silent --http1.0"

DEBUG=0

#
## Usage function
#
function usage () {
   echo "Usage: `basename $0` (-t|--tag) tag [(-b|--builder) image_builder] [(-r|--registry) registry] [-u|--tar_url] tarball_url] [project_directory]"
}

function cleanup () {
  echo "Error during build"
  exit 2
}

#
# All inputs should be in the form of environment variables. In particular, we expect:
## Summarize inputs
#
echo "                     BUILD_ID = ${BUILD_ID}"
echo "                          TAG = ${TAG}"
echo "        BOATYARD_BUILDER__URL = ${BOATYARD_BUILDER__URL}"
echo "DOCKER_REGISTRY__IMAGE_PREFIX = ${DOCKER_REGISTRY__IMAGE_PREFIX}"
echo "                      TAR_URL = ${TAR_URL}"
echo "                  PROJECT_DIR = ${PROJECT_DIR}"
echo "                   DOCKER_DIR = ${DOCKER_DIR}"
echo "        DOCKER_REGISTRY__USER = ${DOCKER_REGISTRY__USER}"
echo "    DOCKER_REGISTRY__PASSWORD = ${DOCKER_REGISTRY__PASSWORD}"
echo "      DOCKER_REGISTRY__EMAIL = ${DOCKER_REGISTRY__EMAIL}"

## Validate input
#
if [[ -z "${TAG}" ]]; then usage; exit 1; fi
if [[ -z "${BOATYARD_BUILDER__URL}" ]]; then usage; exit 1; fi
if [[ -z "${DOCKER_REGISTRY__IMAGE_PREFIX}" ]]; then usage; exit 1; fi

BUILD_API="${BOATYARD_BUILDER__URL}/api/v1/build"
echo "Computed BUILD_API=${BUILD_API}"

# The full image_tag (registry/tag:version)
IMAGE_TAG=${DOCKER_REGISTRY__IMAGE_PREFIX}/${TAG}:${BUILD_ID}
echo "Computed IMAGE_TAG=${IMAGE_TAG}"

# Verify DOCKER_DIR is defined
if [[ -z "${DOCKER_DIR}" ]]; then 
  DOCKER_DIR=.;
  echo "Updated DOCKER_DIR=${DOCKER_DIR}"
fi

#
## Create build request
#

#
# (1) The manifest file in json; include ${TAR_URL} if provided
# Example:
#{
#   "image_name": ""
#   "tar_url": ""   # present only if $TAR_URL is set
#   "username": ""  # present only if $DOCKER_REGISTRY__USER is set
#   "password": ""  # present only if $DOCKER_REGISTRY__PASSWORD is set
#   "email": ""     # present only if $DOCKER_REGISTRY__EMAIL is set
#}
MANIFEST_FILE=/tmp/manifest$$.json
printf "{\n" > ${MANIFEST_FILE}
#   "image_name" : 
printf "  \"image_name\": \"${IMAGE_TAG}\"" >> ${MANIFEST_FILE}
#   "tar_url":  (maybe)
if [ -n "${TAR_URL}" ]; then
  printf ",\n" >> ${MANIFEST_FILE}
  printf "  \"tar_url\": \"${TAR_URL}\"" >> ${MANIFEST_FILE}
fi
if [ -n "${DOCKER_REGISTRY__USER}" ]; then
  printf ",\n" >> ${MANIFEST_FILE}
  printf "  \"username\": \"${DOCKER_REGISTRY__USER}\"" >> ${MANIFEST_FILE}
fi
if [ -n "${DOCKER_REGISTRY__PASSWORD}" ]; then
  printf ",\n" >> ${MANIFEST_FILE}
  printf "  \"password\": \"${DOCKER_REGISTRY__PASSWORD}\"" >> ${MANIFEST_FILE}
fi
if [ -n "${DOCKER_REGISTRY__EMAIL}" ]; then
  printf ",\n" >> ${MANIFEST_FILE}
  printf "  \"email\": \"${DOCKER_REGISTRY__EMAIL}\"" >> ${MANIFEST_FILE}
fi
printf "\n" >> ${MANIFEST_FILE}
printf "}\n" >> ${MANIFEST_FILE}

# (2) The tgz file, if not already provided
if [ -z "${TAR_URL}" ]; then
  TAR_FILE=/tmp/project$$.tgz
  pushd ${DOCKER_DIR}
  tar -cvzf ${TAR_FILE} .
  popd
fi

#
## POST request
#
echo "Manifest:"
echo "============"
cat ${MANIFEST_FILE}
echo "============"

if [ ${DEBUG} -eq 0 ]; then
  if [ -z "${TAR_URL}" ]; then
    echo "Posting tarball: ${TAR_FILE}"
    RESULT=`curl ${CURL_OPTIONS} ${BUILD_API} --form "TarFile=@${TAR_FILE};type=application/x-gzip" --form "Json=@${MANIFEST_FILE};type=application/json"`
  else
    echo "Posting tarball URL: ${TAR_URL}"
    RESULT=`curl ${CURL_OPTIONS} --request POST ${BUILD_API} --data @${MANIFEST_FILE}`
  fi
  echo "Result:"
  echo "============"
  echo ${RESULT}
  echo "============"

  # if error then exit
  if [[ ${RESULT} == *Failed* ]]; then
    echo "Error creating docker image"
    # need to clean up build server
    exit 1
  fi
   
  # Identify the job identifier and the query for status
  JOB_IDENTIFIER=`echo "$RESULT" | grep JobIdentifier | sed 's/.*: "\(.*\)"/\1/'`
  BUILD_STATUS_QUERY="${BOATYARD_BUILDER__URL}/api/v1/${JOB_IDENTIFIER}/status"
  echo "status query: ${BUILD_STATUS_QUERY}"

  QUERY_STATUS=$(curl ${CURL_OPTIONS} ${BUILD_STATUS_QUERY})
  echo "Status: ${QUERY_STATUS}"
  BUILD_STATUS=$(echo ${QUERY_STATUS} | grep Status | awk '{print $3}' | sed 's/^\"//' | sed 's/\"$//')
  echo `date`">> ${BUILD_STATUS}"
  if [[ ${BUILD_STATUS} == *Failed* ]]; then cleanup; fi
  until [[ ${BUILD_STATUS} == *Finished* ]]; do
    sleep 30s
    QUERY_STATUS=$(curl ${CURL_OPTIONS} ${BUILD_STATUS_QUERY})
    echo "Status: ${QUERY_STATUS}"
    BUILD_STATUS=$(echo ${QUERY_STATUS} | grep Status | awk '{print $3}' | sed 's/^\"//' | sed 's/\"$//')
    echo `date`">> ${BUILD_STATUS}"
    if [[ ${BUILD_STATUS} == *Failed* ]]; then cleanup; fi
    if [[ "${BUILD_STATUS}" == "" ]]; then cleanup; fi
  done 
fi

/bin/rm -f ${MANIFEST_FILE}

# Generate output
# Recall: IMAGE_TAG=${DOCKER_REGISTRY__IMAGE_PREFIX}/${TAG}:${BUILD_ID}
read -d '' OUTPUT << EOF
{
  "registry":"$DOCKER_REGISTRY__IMAGE_PREFIX",
  "repository":"$TAG",
  "tag":"$BUILD_ID",
  "image":"$IMAGE_TAG"
}
EOF

echo $OUTPUT > $__LOG__/out
# echo "{\"image\":\"${IMAGE_TAG}\"}" > $__LOG__/out

exit 0