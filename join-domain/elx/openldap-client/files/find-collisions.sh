#!/bin/bash
#
set -euo pipefail
#
# Script to locate collisions within an LDAP directory service
#
######################################################################
PROGNAME="$( basename "${0}" )"
BINDPASS="${CLEARPASS:-}"
CLEANUP="${CLEANUP:-TRUE}"
CRYPTKEY="${CRYPTKEY:-}"
CRYPTSTRING="${CRYPTSTRING:-}"
DEBUG="${DEBUG:-false}"
DIR_DOMAIN="${JOIN_DOMAIN:-}"
DIRUSER="${JOIN_USER:-}"
DOMAINNAME="${JOIN_DOMAIN:-}"
DS_LIST=()
LDAPTYPE="AD"
LDAP_AUTH_TYPE="-x"
LOGFACIL="${LOGFACIL:-kern.crit}"
REQ_TLS="${REQ_TLS:-true}"

# Make interactive-execution more-verbose unless explicitly told not to
if [[ $( tty -s ) -eq 0 ]] && [[ ${DEBUG} == "UNDEF" ]]
then
   DEBUG="true"
fi


#########################
# Function declarations #
#########################

# Error handler function
function err_exit {
   local ERRSTR
   local ISNUM
   local SCRIPTEXIT

   ERRSTR="${1}"
   ISNUM='^[0-9]+$'
   SCRIPTEXIT="${2:-1}"

   if [[ ${DEBUG} == true ]]
   then
      # Our output channels
      logger -i -t "${PROGNAME}" -p "${LOGFACIL}" -s -- "${ERRSTR}"
   else
      logger -i -t "${PROGNAME}" -p "${LOGFACIL}" -- "${ERRSTR}"
   fi

   # Only exit if requested exit is numerical
   if [[ ${SCRIPTEXIT} =~ ${ISNUM} ]]
   then
      return "${SCRIPTEXIT}"
   fi
}

# SaltStack-compatible outputter
function SaltOut {
  if [[ ${OUTPUT} == SALTMODE ]]
  then
      case "${2}" in
        no)
            printf "\n"
            printf "changed=no comment='%s'\n" "${1}"
            ;;
        yes)
            printf "\n"
            printf "changed=yes comment='%s'\n" "${1}"
            ;;
      esac
  fi
}

# Verify tool-dependencies
function VerifyDependencies {
  local CHKRPMS
  local RPM

  # RPMs to check for
  CHKRPMS=(
        bind-utils
        openldap-clients
      )

  for RPM in "${CHKRPMS[@]}"
  do
      err_exit "Checking if dependency on ${RPM} is satisfied... " 0
      if [[ $( rpm --quiet -q "${RPM}" )$? -eq 0 ]]
      then
        err_exit "Dependency on ${RPM} *is* satisfied" 0
      else
        err_exit "Dependency on ${RPM} *not* satisfied" 1
      fi
  done
}

# Get Candidate DCs
function CandidateDirServ {
  local DNS_SEARCH_STRING

  # Select whether to try to use AD "sites"
  if [[ -n ${ADSITE:-} ]]
  then
    DNS_SEARCH_STRING="_ldap._tcp.${ADSITE}._sites.dc._msdcs.${DIR_DOMAIN}"
  else
    DNS_SEARCH_STRING="_ldap._tcp.dc._msdcs.${DIR_DOMAIN}"
  fi

  # Populate global directory-server array
  mapfile -t DS_LIST < <(
    dig -t SRV "${DNS_SEARCH_STRING}" | \
    sed -e '/^$/d' -e '/;/d' | \
    awk '/\s\s*IN\s\s*SRV\s\s*/{ printf("%s;%s\n",$7,$8) }' | \
    sed -e 's/\.$//'
  )

  if [[ ${#DS_LIST[@]} -eq 0 ]]
  then
    err_exit "Unable to generate a list of candidate servers" 1
    return 1
  else
    err_exit "Found ${#DS_LIST[@]} candidate directory-servers" 0
    return 0
  fi
}

# Make sure directory-server ports are open
function PingDirServ {
  local    DIR_SERV
  local    DS_NAME
  local    DS_PORT
  local -a GOOD_DS_LIST


  for DIR_SERV in "${DS_LIST[@]}"
  do
    DS_NAME="${DIR_SERV//*;/}"
    DS_PORT="${DIR_SERV//;*/}"

    if [[ $(
        timeout 1 bash -c "echo > /dev/tcp/${DS_NAME}/${DS_PORT}"
      ) -eq 0 ]]
    then
      GOOD_DS_LIST+=("${DIR_SERV}")
      err_exit "${DIR_SERV//*;} responds to port-ping" 0
    fi
  done

  if [[ ${#GOOD_DS_LIST[@]} -gt 0 ]]
  then
    # Overwrite global directory-server array with successfully-pinged
    # servers' info
    DS_LIST=("${GOOD_DS_LIST[@]}")
    err_exit "Found ${#DS_LIST[@]} port-pingable directory servers" 0
    return 0
  else
    err_exit "All candidate servers failed port-ping" 1
    return 1
  fi
}

# Decrypt password to use for LDAP queries
function PWdecrypt {
  local PWCLEAR

  # Bail if either of crypt-string or decrpytion-key are null
  if [[ -z ${CRYPTSTRING} ]] || [[ -z ${CRYPTKEY} ]]
  then
    logIt "Missing keystring-decryption values" 1
  fi

  # Lets decrypt!
  if PWCLEAR=$(
    echo "${CRYPTSTRING}" | \
    openssl enc -aes-256-cbc -md sha256 -a -d -salt -pass pass:"${CRYPTKEY}"
  )
  then
    echo "${PWCLEAR}"
    return 0
  else
    echo "Decryption FAILED!"
    return 1
  fi
}

# Check if directory-servers support TLS
function CheckTLSsupt {
  local    DIR_SERV
  local    DS_NAME
  local    DS_PORT
  local -a GOOD_DS_LIST

  for DIR_SERV in "${DS_LIST[@]}"
  do
    DS_NAME="${DIR_SERV//*;/}"
    DS_PORT="${DIR_SERV//;*/}"

    if [[ $(
        echo | \
        openssl s_client -showcerts -starttls ldap \
          -connect "${DS_NAME}:${DS_PORT}" 2> /dev/null | \
        openssl verify > /dev/null 2>&1
      )$? -eq 0 ]]
    then
      GOOD_DS_LIST+=("${DIR_SERV}")
      err_exit "Appending ${DS_NAME} to 'good servers' list" 0
    fi

    # shellcheck disable=SC2199
    # Add servers with good certs to list
    if [[ ${GOOD_DS_LIST[@]+"${GOOD_DS_LIST[@]}"} -gt 0 ]]
    then
      # Overwrite global directory-server array with successfully-pinged
      # servers' info
      DS_LIST=("${GOOD_DS_LIST[@]}")
      LDAP_AUTH_TYPE="-Zx"
      return 0
    else
      # Null the list
      LDAP_AUTH_TYPE="-x"
      DS_LIST=()
      err_exit "${DS_NAME} failed cert-check" 0
    fi
  done
}

function FindComputer {
  local COMPUTERNAME
  local DS_HOST
  local DS_PORT
  local SEARCH_EXIT
  local SEARCHTERM
  local SHORTHOST

  # AD-hosted objects will always be shortnames
  SHORTHOST=${HOSTNAME//.*/}

  # Need to ensure we look for literal, all-cap and all-lower
  SEARCHTERM="(&(objectCategory=computer)(|(cn=${SHORTHOST})(cn=${SHORTHOST^^})(cn=${SHORTHOST,,})))"
  export SEARCHTERM

  # Directory server info
  DS_HOST="${DS_LIST[0]//*;/}"
  DS_PORT="${DS_LIST[0]//;*/}"

  # Perform directory-search
  COMPUTERNAME=$(
    ldapsearch \
      -o ldif-wrap=no \
      -LLL \
      "${LDAP_AUTH_TYPE}" \
      -h "${DS_HOST}" \
      -p "${DS_PORT}" \
      -D "${QUERYUSER}" \
      -w "${BINDPASS}" \
      -b "${SEARCHSCOPE}" \
      -s sub "${SEARCHTERM}" dn
  )

  SEARCH_EXIT="$?"

  COMPUTERNAME=$( echo "${COMPUTERNAME}" | \
        sed -e 's/^.*dn: *//' -e '/^$/d' -e '/#/d' )

  if [[ -n ${COMPUTERNAME:-} ]]
  then
    err_exit "Found ${COMPUTERNAME}" 0
    echo "${COMPUTERNAME}"
  else
    err_exit "Did not find ${COMPUTERNAME}" 0
    echo "NOTFOUND"
  fi

  case "${SEARCH_EXIT}" in
    0)
      err_exit "Found ${COMPUTERNAME} on ${DS_HOST}"j 0
      ;;
    *)
      err_exit "Delete of ${DIRECTORY_OBJECT} with exit-code '${DELETE_EXIT}'" 1
      ;;
  esac
}

function NukeComputer {
  local DIRECTORY_OBJECT
  local DS_HOST
  local DS_INFO
  local DS_PORT
  local DELETE_EXIT

  # Override abort-on-error so we can provide better output
  set +e

  DS_INFO="${1}"
  DIRECTORY_OBJECT="${2}"

  DS_HOST="${DS_INFO//*;/}"
  DS_PORT="${DS_INFO//;*/}"

  ldapdelete \
    "${LDAP_AUTH_TYPE}" \
    -h "${DS_HOST}" \
    -p "${DS_PORT}" \
    -D "${QUERYUSER}" \
    -w "${BINDPASS}" "${DIRECTORY_OBJECT}"

  DELETE_EXIT="$?"

  case "${DELETE_EXIT}" in
    0)
      err_exit "Delete of ${DIRECTORY_OBJECT} succeeded" 0
      ;;
    34)
      err_exit "Delete of ${DIRECTORY_OBJECT} failed: bad DN syntax" 1
      ;;
    *)
      err_exit "Delete of ${DIRECTORY_OBJECT} failed" 1
      ;;
  esac
}




###########################
# CLI option-flag parsing #
###########################

# Ensure parseable arguments have been passed
if [[ $# -eq 0 ]]
then
  logIt "No arguments given. Aborting" 1
fi

# Define flags to look for...
OPTIONBUFR=$(getopt -o c:d:f:hk:l:p:s:t:u: --long domain-name:,help,hostname:,join-crypt:,join-key:,join-password:,join-user:,ldap-host:,ldap-type:,mode:,ad-site: -n "${PROGNAME}" -- "$@")

# Check for mutually-exclusive arguments
if [[ ${OPTIONBUFR} =~ p\ |join-password && ${OPTIONBUFR} =~ c\ |join-crypt ]] ||
  [[ ${OPTIONBUFR} =~ p\ |join-password && ${OPTIONBUFR} =~ c\ |join-key ]]
then
  EXCLUSIVEARGS=TRUE
  UsageMsg
fi

eval set -- "${OPTIONBUFR}"

#+---------------------------------+
#| Parse contents of ${OPTIONBUFR} |
#+---------------------------------+

while true
do
  case "$1" in
      -c|--join-crypt)
        case "$2" in
            "")
              logIt "Error: option required but not specified" 1
              shift 2;
              exit 1
              ;;
            *)
              CRYPTSTRING="${2}"
              shift 2;
              ;;
        esac
        ;;
      -d|--domain-name)
        case "$2" in
            "")
              logIt "Error: option required but not specified" 1
              shift 2;
              exit 1
              ;;
            *)
              DOMAINNAME="${2}"
              shift 2;
              ;;
        esac
        ;;
      -f|--hostname)
        case "$2" in
            "")
              logIt "Error: option required but not specified" 1
              shift 2;
              exit 1
              ;;
            *)
              HOSTNAME="${2}"
              shift 2;
              ;;
        esac
        ;;
      -h|--help)
        UsageMsg
        ;;
      -k|--join-key)
        case "$2" in
            "")
              logIt "Error: option required but not specified" 1
              shift 2;
              exit 1
              ;;
            *)
              CRYPTKEY="${2}"
              shift 2;
              ;;
        esac
        ;;
      -l|--ldap-host)
        case "$2" in
            "")
              logIt "Error: option required but not specified" 1
              shift 2;
              exit 1
              ;;
            *)
              LDAPHOST="${2}"
              shift 2;
              ;;
        esac
        ;;
      --mode)
        case "$2" in
            "")
              logIt "Error: option required but not specified" 1
              shift 2;
              exit 1
              ;;
            cleanup)
              CLEANUP=TRUE
              OUTPUT=INTERACTIVE
              shift 2;
              ;;
            saltstack)
              CLEANUP=TRUE
              OUTPUT=SALTMODE
              shift 2;
              ;;
            *)
              CLEANUP=FALSE
              OUTPUT=INTERACTIVE
              shift 2;
              ;;
        esac
        ;;
      -p|--join-password)
        case "$2" in
            "")
              logIt "Error: option required but not specified" 1
              shift 2;
              exit 1
              ;;
            *)
              BINDPASS="${2}"
              shift 2;
              ;;
        esac
        ;;
      -s|--ad-site)
        case "$2" in
            "")
              logIt "Error: option required but not specified" 1
              shift 2;
              exit 1
              ;;
            *)
              ADSITE="${2}"
              shift 2;
              ;;
        esac
        ;;
      -t|--ldap-type)
        case "$2" in
            "")
              logIt "Error: option required but not specified" 1
              shift 2;
              exit 1
              ;;
            ad|AD)
              LDAPTYPE="AD"
              shift 2;
              ;;
            *)
              logIt "Error: unsupported directory-type" 1
              shift 2;
              exit 1
              ;;
        esac
        ;;
      -u|--join-user)
        case "$2" in
            "")
              logIt "Error: option required but not specified" 1
              shift 2;
              exit 1
              ;;
            *)
              DIRUSER="${2}"
              shift 2;
              ;;
        esac
        ;;
      --)
        shift
        break
        ;;
      *)
        logIt "Missing value" 1
        exit 1
        ;;
  esac
done

################
# Main program #
################

# Set directory-user value as appropriate
if [[ ${LDAPTYPE} == AD ]]
then
  QUERYUSER="${DIRUSER}@${DOMAINNAME}"
else
  QUERYUSER="${DIRUSER}"
fi
export QUERYUSER

# Convert domain to a search scope
SEARCHSCOPE="$( printf "DC=%s" "${DOMAINNAME//./,DC=}" )"
export SEARCHSCOPE

# Query-Users's password-string
if [[ -z ${BINDPASS} ]]
then
  BINDPASS="$( PWdecrypt )"
fi


# Verify that RPM-dependencies are met
VerifyDependencies

# Identify list of candidate directory servers
if [[ -z ${LDAPHOST} ]]
then
  CandidateDirServ
fi

# Port-ping candidate directory servers
PingDirServ

# Verify candidate directory servers' properly-functioning TLS support
if [[ ${REQ_TLS} == "true" ]]
then
  err_exit "Performing TLS-support test" 0
  CheckTLSsupt
else
  err_exit "Skipping TLS-support test" 0
fi

# Emit number of servers found
err_exit "Found ${#DS_LIST[@]} potentially-good directory servers" 0

# Find target computerObject
OBJECT_DN="$( FindComputer )"

case "${OBJECT_DN}" in
  NOTFOUND)
    err_exit "Coult not ${HOSTNAME} in ${SEARCHSCOPE}" 1
    CLEANUP="FALSE"
    ;;
  *)
    err_exit "Found ${HOSTNAME} in ${SEARCHSCOPE}" 0
    ;;
esac

# Delete detected collision
if [[ ${CLEANUP} == "TRUE" ]]
then
  NukeComputer "${DS_LIST[0]}" "${OBJECT_DN}"
else
  err_exit "Script called with 'no-cleanup' requested" 0
fi
