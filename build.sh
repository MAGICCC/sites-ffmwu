#!/bin/bash -e
# =====================================================================
# Build script for Freifunk MWU firmware
#
# Credits:
# - Freifunk Fulda for their build script
# - Freifunk Bremen for their version schema
# =====================================================================

# Default make options
CORES=$(nproc)
MAKEOPTS="-j$((CORES+1))"

# Default to build all Gluon targets if parameter -t is not set
TARGETS="ar71xx-generic ar71xx-nand mpc85xx-generic x86-generic \
x86-kvm_guest x86-64 x86-xen_domu ramips-rt305x brcm2708-bcm2708 \
brcm2708-bcm2709 sunxi"

# Sites directory
SITES_DIR="./sites"

# Gluon directory
GLUON_DIR="./gluon"

# Deployment directory
DEPLOYMENT_DIR="/var/www/html/firmware/_library"

# Autosign key
SIGN_KEY="${HOME}/.ecdsakey"

# Build targets marked broken
BROKEN=false

# Error codes
E_ILLEGAL_ARGS=126
E_ILLEGAL_TAG=127
E_DIR_NOT_EMPTY=128

# Help function used in error messages and -h option
usage() {
  echo ""
  echo "Build script for Freifunk MWU Gluon firmware."
  echo ""
  echo "-a: Build targets marked as broken (optional)"
  echo "    Default: ${BROKEN}"
  echo "-b: Firmware branch name (testing or experimental)"
  echo "-c: Build command: update | build | sign | deploy"
  echo "-d: Enable bash debug output"
  echo "-h: Show this help"
  echo "-i: Build identifier (optional)"
  echo "    Will be applied to the deployment directory"
  echo "-m: Setting for make options (optional)"
  echo "    Default: \"${MAKEOPTS}\""
  echo "-r: Release suffix (required)"
  echo "-s: Site directory to use (required)"
  echo "    Availible: $(ls -m ${SITES_DIR})"
  echo "-t: Gluon target architectures to build (optional)"
  echo "    Default: \"${TARGETS}\""
}

# Evaluate arguments for build script.
if [[ "${#}" == 0 ]]; then
  usage
  exit ${E_ILLEGAL_ARGS}
fi

# Evaluate arguments for build script.
while getopts ab:c:dhm:i:t:r:s: flag; do
  case ${flag} in
    h)
      usage
      exit
      ;;
    b)
      case "${OPTARG}" in
        testing| \
        experimental)
          BRANCH="${OPTARG}"
          ;;
        *)
          echo "Error: Invalid branch set."
          usage
          exit ${E_ILLEGAL_ARGS}
          ;;
      esac
      ;;
    c)
      case "${OPTARG}" in
        update| \
        build| \
        sign| \
        deploy| \
        clean| \
        dirclean)
          COMMAND="${OPTARG}"
          ;;
        *)
          echo "Error: Invalid build command set."
          usage
          exit ${E_ILLEGAL_ARGS}
          ;;
      esac
      ;;
    d)
      set -x
      ;;
    m)
      MAKEOPTS="${OPTARG}"
      ;;
    i)
      BUILD="${OPTARG}"
      ;;
    t)
      TARGETS="${OPTARG}"
      ;;
    r)
      RELEASE="${OPTARG}"
      ;;
    s)
      if [[ -d "${SITES_DIR}/${OPTARG}" ]]; then
        SITE_DIR="${SITES_DIR}/${OPTARG}"
      elif [[ -d "${OPTARG}" ]]; then
        SITE_DIR="${OPTARG}"
      else
        echo "Error: Invalid site directory set."
        usage
        exit ${E_ILLEGAL_ARGS}
      fi
      SITE_DIR="$(readlink -f ${SITE_DIR})"
      ;;
    a)
      BROKEN=true
      ;;
    *)
      usage
      exit ${E_ILLEGAL_ARGS}
      ;;
  esac
done

# Strip of all remaining arguments
shift $((OPTIND - 1));

# Check if there are remaining arguments
if [[ "${#}" > 0 ]]; then
  echo "Error: To many arguments: ${*}"
  usage
  exit ${E_ILLEGAL_ARGS}
fi

# Set branch name
if [[ -z "${BRANCH}" ]]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
fi

# Set command
if [[ -z "${COMMAND}" ]]; then
  echo "Error: Build command missing."
  usage
  exit ${E_ILLEGAL_ARGS}
fi

# Set release number
if [[ -z "${RELEASE}" ]]; then
  echo "Error: Release suffix missing."
  usage
  exit ${E_ILLEGAL_ARGS}
fi

if [[ "${BRANCH}" == "experimental" ]]; then
  GLUON_TAG=$(git --git-dir="${GLUON_DIR}/.git" describe --always)
  GLUON_TAG="${GLUON_TAG#v}"
  GLUON_TAG="${GLUON_TAG//-*}"
elif [[ "${BRANCH}" == "testing" ]]; then
  if ! GLUON_TAG=$(git --git-dir="${GLUON_DIR}/.git" describe --exact-match) ; then
    echo 'The gluon tree is not checked out at a tag.'
    echo 'Please use `git checkout <tagname>` to use an official gluon release'
    echo 'or build it manually. Only with a tag we can autogenerate the'
    echo 'release string!'
    exit ${E_ILLEGAL_TAG}
  fi
  GLUON_TAG="${GLUON_TAG#v}"
fi

RELEASE="${GLUON_TAG}+${RELEASE}"

# Number of days that may pass between releasing an updating
PRIORITY=0

update() {
  make ${MAKEOPTS} \
       GLUON_SITEDIR="${SITE_DIR}" \
       update
}

build() {
  echo
  echo "--- Build Gluon ${GLUON_TAG} as ${RELEASE}"

  for TARGET in ${TARGETS}; do
    echo
    echo "--- Build Gluon Images for target: ${TARGET}"
    make ${MAKEOPTS} \
         GLUON_SITEDIR="${SITE_DIR}" \
         GLUON_RELEASE="${RELEASE}" \
         GLUON_BRANCH="${BRANCH}" \
         GLUON_TARGET="${TARGET}" \
         BROKEN="${BROKEN}" \
         all
  done

  echo
  echo "--- Build Gluon Manifest"
  make ${MAKEOPTS} \
       GLUON_SITEDIR="${SITE_DIR}" \
       GLUON_RELEASE="${RELEASE}" \
       GLUON_BRANCH="${BRANCH}" \
       GLUON_PRIORITY="${PRIORITY}" \
       manifest
}

sign() {
  echo
  echo "--- Sign Gluon Firmware Build: "

  # Add the signature to the local manifest
  contrib/sign.sh \
      "${SIGN_KEY}" \
      "output/images/sysupgrade/${BRANCH}.manifest"
}

deploy() {
  # Create the deployment directory
  TARGET="${DEPLOYMENT_DIR}/${RELEASE}"
  if [[ -n ${BUILD} ]]; then
    TARGET="${TARGET}~${BUILD}"
  fi

  echo
  echo "--- Deploy Gluon ${RELEASE} Firmware to ${TARGET}"
  mkdir --parents --verbose "${TARGET}"

  # Check if target directory is empty
  if [[ "$(ls -A ${TARGET})" ]]; then
    echo "Error: Target directory not empty"
    exit ${E_DIR_NOT_EMPTY}
  fi

  # Copy images and modules to DEPLOYMENT_DIR
  CP_CMD="cp --verbose --recursive --no-dereference"
  $CP_CMD "output/images/factory"         "${TARGET}/factory"
  $CP_CMD "output/images/sysupgrade"      "${TARGET}/sysupgrade"
  $CP_CMD "output/modules/"*"${RELEASE}"  "${TARGET}/modules"
}

clean(){
  for TARGET in ${TARGETS}; do
    make ${MAKEOPTS} \
         GLUON_SITEDIR="${SITE_DIR}" \
         GLUON_TARGET="${TARGET}" \
         BROKEN="${BROKEN}" \
         clean
  done
}

dirclean(){
  make ${MAKEOPTS} \
       GLUON_SITEDIR="${SITE_DIR}" \
       BROKEN="${BROKEN}" \
       dirclean
}

(
  # Change working directory to gluon tree
  cd "${GLUON_DIR}"

  # Execute the selected command
  ${COMMAND}
)
