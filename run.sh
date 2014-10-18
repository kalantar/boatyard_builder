#!/bin/bash

# Change to workspace
cd ${__DATA__}

BREADCRUMB_FILE="docker/breadcrumb"
BREADCRUMB_IMAGE_KEY="tag"

CURL_OPTIONS="--silent --http1.0"

DEBUG=0

#
## Usage function
#
usage () {
   echo "Usage: `basename $0` (-t|--tag) tag [(-b|--builder) image_builder] [(-r|--registry) registry] [-u|--tar_url] tarball_url] [project_directory]"
}

cleanup () {
  echo "Error during build"
  exit 2
}

# If BOATYARD_BUILDER__URL is defined, set IMAGE_BUILDER from it (ie, override IMAGE_BUILDER from ENV).
# We still allow the command line to override this. 
if [ -n "${BOATYARD_BUILDER__URL}" ]; then
  IMAGE_BUILDER=${BOATYARD_BUILDER__URL}
fi

# If DOCKER_REGISTRY__IMAGE_PREFIX is defined, set IMAGE_BUILDER from it (ie, override IMAGE_BUILDER from ENV).
# We still allow the command line to override this. 
if [ -n "${DOCKER_REGISTRY__IMAGE_PREFIX}" ]; then
  REGISTRY=${DOCKER_REGISTRY__IMAGE_PREFIX}
fi

#
## Parse input options; may override value provided in properties file
#
while [ $# -ge 1 ]
do
key="${1}"
shift

case ${key} in
    -t|--tag)
    TAG="${1}"
    shift
    ;;
    -b|--builder)
    IMAGE_BUILDER="${1}"
    shift
    ;;
    -r|--registry)
    REGISTRY="${1}"
    shift
    ;;
    -u|--tar_url)
    TAR_URL="${1}"
    shift
    ;;
    -h|--help)
    usage
    exit 0
    ;;
    -d|--debug)
    DEBUG=1
    ;;
    *)
    # assume is project_dir
    PROJECT_DIR="${key}"
    ;;
esac
done

## Summarize inputs
#
echo TAG           = "${TAG}"
echo IMAGE_BUILDER = "${IMAGE_BUILDER}"
echo REGISTRY      = "${REGISTRY}"
echo TAR_URL       = "${TAR_URL}"
echo PROJECT_DIR   = "${PROJECT_DIR}"

BUILD_API="${IMAGE_BUILDER}/api/v1/build"

## Validate input
#
if [ -z "${TAG}" ]; then
   usage
   exit 1
fi

if [ -z "${IMAGE_BUILDER}" ]; then
   usage
   exit 1
fi

if [ -z "${REGISTRY}" ]; then
   usage
   exit 1
fi

# Identify the (IDS) build number
BUILD_NUMBER=`echo ${BUILD_URL} | sed 's/.*\/\([0-9]\+\)\/$/\1/'`
echo "Identified Build # ${BUILD_NUMBER}"

# The full image_tag (registry/tag:version)
IMAGE_TAG=${REGISTRY}/${TAG}:${BUILD_NUMBER}
#
## Create build request
#

#
# (1) The manifest file in json; include ${TAR_URL} if provided
# Example:
#{
#   "iamge_name": ""
#   "tar_url": ""   # present only if $TAR_URL is set
#   "username": ""  # not currently used
#   "password": ""  # not currently used
#   "email": ""     # not currently used
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
printf "\n" >> ${MANIFEST_FILE}
printf "}\n" >> ${MANIFEST_FILE}

# (2) The tgz file, if not already provided
if [ -z "${TAR_URL}" ]; then
  TAR_FILE=/tmp/project$$.tgz
  tar -cvzf ${TAR_FILE} .
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
  BUILD_STATUS_QUERY="${IMAGE_BUILDER}/api/v1/${JOB_IDENTIFIER}/status"
  echo "status query: ${BUILD_STATUS_QUERY}"

  BUILD_STATUS=`curl ${CURL_OPTIONS} ${BUILD_STATUS_QUERY} | grep Status | awk '{print $2}' | sed 's/^\"//' | sed 's/\"$//'`
  echo `date`">> ${STATUS}"
  if [[ ${BUILD_STATUS} == *Failed* ]]; then cleanup; fi
  until [[ ${BUILD_STATUS} == *Finished* ]]; do
    sleep 30s
    BUILD_STATUS=`curl ${CURL_OPTIONS} ${BUILD_STATUS_QUERY} | grep Status | awk '{print $2}' | sed 's/^\"//' | sed 's/\"$//'`
    echo `date`">> ${BUILD_STATUS}"
    if [[ ${BUILD_STATUS} == *Failed* ]]; then cleanup; fi
    if [[ "${BUILD_STATUS}" == "" ]]; then cleanup; fi
  done 
fi

echo "${BREADCRUMB_IMAGE_KEY}=${IMAGE_TAG}" > ${BREADCRUMB_FILE}
echo "Wrote ${BREADCRUMB_FILE}:"
echo "============"
cat ${BREADCRUMB_FILE}
echo "============"

/bin/rm -f ${MANIFEST_FILE}

## create a test file for testing
#echo "hello world" > docker/my.test
#echo "goodbye" > docker/my.notatest

echo "{\"image\":\"${IMAGE_TAG}\"}" > $__STATUS__/out

exit 0