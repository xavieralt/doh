#!/bin/bash

DOH_VERSION="0.3"

# Setup output logging
DOH_LOGFILE=/tmp/doh.log
DOH_LOGLEVEL="${DOH_LOGLEVEL:-info}"
DOH_PROFILE_LOADED="0"
DOH_PARTS="main addons extra client"

# HELPERS GLOBALS
declare -A GITLAB_CACHED_AUTH_TOKENS
declare -A GITLAB_CACHED_AUTH_USERS
declare -A GITLAB_CACHED_AUTH_PASSWD
declare GITLAB_API_RESULT

doh_setup_logging() {

exec 6>&1
exec 7>&2

>${DOH_LOGFILE}
exec > >(tee -a "${DOH_LOGFILE}")
exec 2> >(tee -a "${DOH_LOGFILE}" >&2)
exec 5<>${DOH_LOGFILE}

}

#
# Internal: Logging methods
#

declare -A LOG_COLOR=([INFO]=37 [DEBUG]=34 [WARN]=33 [OK]=32 [ERROR]=31)
declare TRUE=0
declare FALSE=1

eecho() {
    # echo "$@" | tee -a ${LOG_FILE}
    echo "$@"
}
ecolor() {
    loglevel="$1"; shift;
    echo -ne "\033[40m\033[1;${LOG_COLOR[$loglevel]}m$1\033[0m"
}

erunquiet() {
    edebug "will run: $@"
    "$@" 2>&1 >>${DOH_LOGFILE}
    return $?
}

erun() {
    if [ x"$1" = x"-q" ]; then
        quiet=1; shift;
    fi
    edebug "will run: $@"
    if [ x"$1" = x"--show" ]; then
        shift;
        "$@" >&6 2>&7
    else
        "$@" >>${DOH_LOGFILE} 2>&1
    fi
    return $?
}

urlencode() {
    sed 's/%/%25/g;s/ /%20/g;s/ /%09/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;s/\$/%24/g;s/\&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;s/\*/%2a/g;s/+/%2b/g;s/,/%2c/g;s/-/%2d/g;s/\./%2e/g;s/\//%2f/g;s/:/%3a/g;s/;/%3b/g;s//%3e/g;s/?/%3f/g;s/@/%40/g;s/\[/%5b/g;s/\\/%5c/g;s/\]/%5d/g;s/\^/%5e/g;s/_/%5f/g;s/`/%60/g;s/{/%7b/g;s/|/%7c/g;s/}/%7d/g;s/~/%7e/g;s/      /%09/g;'
}

elogmsg() {
    loglevel="$1"; shift;
    OPTIND=1
    while getopts ":n" opt; do
        case $opt in
            n)
                noecho=true
                ;;
        esac
    done
    shift $(($OPTIND - 1))

    ecolor $loglevel "*"
    if [ x"$noecho" = x"true" ]; then
        eecho -ne " $@"
    else
        eecho -e " $@"
    fi
}

elog() { elogmsg 'OK' "$@"; }
ewarn() { elogmsg 'WARN' "$@"; }
eerror() { elogmsg 'ERROR' "$@" >&2; }
edebug() {
    if [ x"${DOH_LOGLEVEL}" = x"debug" ]; then
        elogmsg 'DEBUG' "$@" >&2;
    else
        echo "$@" >>${DOH_LOGFILE}
    fi
}

estatus() {
    status=$?
    if [ $status -ne 0 ]; then
        ecolor 'ERROR' 'fail'
    else
        ecolor 'OK' 'ok'
    fi
    eecho ""
    return $status
}

die() { eerror "$1"; exit 2; }

eexist() {
    [ -d ${!1} ]
    return $?
}

eremove() {
    if [ -e "$1" ] ; then
        ewarn "Deleting $1"
        rm -Rf "$1"
    fi
}

conf_env_get() {
    # $1: key, $2: default value
    r=$(key="${1^^}"; confkey="CONF_${key//./_}"; echo -n "${!confkey:-${2}}")
    echo -n "${r}"
    if [ x"${r}" = x"" ]; then
        return $FALSE
    else
        return $TRUE
    fi
}

conf_file_get_sections() {
    local conffile="$1"
    sed -n '/^\[\(.*\)\]/{s/\[//;s/\]//;p}' "${conffile}"
}

conf_file_get_options() {
    local conffile="$1"
    local section="$2"
    if (grep -E "^\[${section}\]$" "${conffile}" >/dev/null); then
        sed -n "/^\[${section}\]/,$ { /^\[/{s/^\[\(.*\)\]$/\1/; x; d}; x; /^${section}$/!{x; d; n}; x; /^#/d; s/[ \\t]*$//; p;}" "${conffile}"
        return $TRUE
    else
        return $FALSE
    fi
}

conf_file_unset() {
    local conffile="$1"
    local section="${2%%.*}"
    local option="${2#*.}"

    if [ x"${option}" != x"" ]; then
        # remove the specific option
        sed -i "/^\[${section}\]/,$ { /^\[/{h; s/^\[\(.*\)\]$/\1/; x;}; x; /^${section}$/{x; /^${option}=/d; x}; x;}" "${conffile}"

        local x=$(conf_file_get_options "${conffile}" "${section}" | sed '/^$/d' | wc -l)
        if [ $x -eq 0 ]; then
            # no more option, remote the section
            sed -i "/^\[${section}\]/d" "${conffile}"
        fi
    # else
    #     # remote the whole section
    #     sed -i "/^\[${section}\]/,$ { /^\[/{h; s/^\[\(.*\)\]$/\1/; x;}; x; /^${section}$/{x; d; n;}; x; /^#/d;}" "${conffile}"
    fi
}

conf_file_get() {
    # $1: conf file, $2: section.option
    local conffile="$1"
    local section="${2%%.*}"
    local option="${2#*.}"
    local opt_name=""
    local opt_value=""

    OLDIFS="${IFS}"
    local VARS=$(conf_file_get_options "${conffile}" "${section}")
    IFS=$'\n'; while read -r var; do
        opt_name="${var%%=*}"
        opt_value="${var#*=}"
        if [ x"${opt_name}" = x"${option}" ]; then
            echo -n "${opt_value}"
            break;
        fi
    done <<< "${VARS}"
    IFS="$OLDIFS"
}

conf_file_set() {
    # $1: conf file, $2: section.option, $3: value
    local conffile="$1"
    local section="${2%%.*}"
    local option="${2#*.}"
    local value="$3"

    local section_exists=$(conf_file_get_sections "${conffile}" | grep -E "^${section}$" | wc -l)
    if [ $section_exists -ne 0 ]; then
            sed -i "/^\[${section}\]/,$ {
                x; # hold
                /^$/ { s#.*#${section}:0# } # hold buffer empty, set it to current section.

                /^${section}:[01]$/ {
                    # we are in the current section
                    x; # pattern
                    /^\[${section}\]/ { # current line in section header, skip it
                        $ {  # already at end-of-file, 'set' could not have already occurred, force adding option line
                            a\
${option}=${value}
                        }
                        n;
                    }
                    x; # hold
                    /^${section}:1$/ {  # 'set' already occured, skip
                        x; # pattern
                        n;
                    }
                    /^${section}:0$/ {  # 'set' still searching
                        x; # pattern;
                        /^${option}=/ {  # option found
                            x; # hold
                            s/:0$/:1/
                            x; # pattern
                            c\
${option}=${value}
                            n;
                        }
                        /^\[/ {  # start of next section
                            x; # hold
                            s/:0$/:1/
                            x; # pattern
                            i\
${option}=${value}
                            n;
                        }
                        $ {
                            x; # hold
                            s/:0$/:1/
                            x; # pattern
                            a\
${option}=${value}
                            n;
                        }
                    }
                    #l;
                    x; # hold
                }

                x;  # get back pattern buffer
            }" "${conffile}"
    else
        echo -e "\n[${section}]\n${option}=${value}" >> "${conffile}"
    fi
}

gitlab_cache_auth_token() {
    # $1: gitlab url
    if [ x"${GITLAB_CACHED_AUTH_TOKENS[$1]}" = x"" ]; then
        # ask user about user/password
        local gitlab_username
        local gitlab_password
        while true; do
            read -p "Please enter gitlab username: " REPLY
            if [ x"${REPLY}" != x"" ]; then
                gitlab_username="${REPLY}"
            fi
            if [ x"${gitlab_username}" != x"" ]; then
                break
            fi
        done
        while true; do
            read -s -p "Please enter gitlab password: " REPLY
            if [ x"${REPLY}" != x"" ]; then
                gitlab_password="${REPLY}"
            fi
            if [ x"${gitlab_password}" != x"" ]; then
                break;
            fi
        done
        echo "" >&2  # force empty line after password no-echo
        local session_url="$1/api/v3/session"
        gitlab_username=$(echo "${gitlab_username}" | urlencode)
        gitlab_password=$(echo "${gitlab_password}" | urlencode)
        local session=$(curl -f -s "${session_url}" --data "login=${gitlab_username}&password=${gitlab_password}")
        if [ x"${session}" = x"" ]; then
            eerror 'Unable to authenticate to gitlab (wrong password?)'
            return $FALSE
        fi
        local private_token=$(echo "${session}" | py_json_get_value "private_token")
        if [ x"${private_token}" = x"" ]; then
            eerror 'Error unable to get session authentication token'
            return $FALSE
        fi
        local session_username=$(echo "${session}" | py_json_get_value "username")
        if [ x"${session_username}" = x"" ]; then
            eerror 'Error unable to get session username'
            return $FALSE
        fi
        GITLAB_CACHED_AUTH_TOKENS[$1]="${private_token}"
        GITLAB_CACHED_AUTH_USERS[$1]="${session_username}"
        GITLAB_CACHED_AUTH_PASSWD[$1]="${gitlab_password}"
    fi
    return $TRUE
}

gitlab_extract_baseurl() {
    gitlab_host_url_match='^((http)[s]?://([^/]+))[/]?.*$'
    if [[ "$1" =~ $gitlab_host_url_match ]]; then
        echo "${BASH_REMATCH[1]}"
        return $TRUE
    else
        return $FALSE
    fi
}

gitlab_identify_site() {
    gitlab_url=$(gitlab_extract_baseurl "$1") || return $FALSE
    session_url="${gitlab_url}/api/v3/session"
    session_url_status=$(wget -O- -S -q "${session_url}" 2>&1 | sed -n '/\s*HTTP/{s#\s*HTTP\/.\.. \([0-9]*\) .*#\1#; p; q};')
    if [ x"$session_url_status" = x"405" ]; then
        return $TRUE
    else
        return $FALSE
    fi
}

gitlab_api_query() {
    # $1: gitlab url
    # $2: wget extra args
    gitlab_url=$(gitlab_extract_baseurl "$1")
    if [ $? -ne 0 ]; then
        die "Unable to extract Gitlab base url from $1"
    fi

    gitlab_cache_auth_token "${gitlab_url}" || die "Unable to get authentication token"
    auth_token="${GITLAB_CACHED_AUTH_TOKENS[${gitlab_url}]}"

    GITLAB_API_RESULT=$(wget -q -O- --header "PRIVATE-TOKEN: ${auth_token}" "$1" $2)
    if [ $? -eq 0 ]; then
        return $TRUE
    else
        return $FALSE
    fi
}


assert_in() {
    local r=$FALSE
    for v in $2; do
        if [ x"$1" = x"$v" ]; then
            r=$TRUE
        fi
    done
    return $r
}

_H_KNOWN_REPO_TYPE="git bzr hg"

helper_is_dir_repo() {
    # 1: dir, 2: repository type
    assert_in "git" "${_H_KNOWN_REPO_TYPE}" || die 'Invalid repository type $2'
    local dir_path="$1"
    local repo_type="$2"
    local dir_repo_path="${dir_path}/.${repo_type}"

    if [ -d "${dir_path}" ] && [ -d "${dir_repo_path}" ]; then
        return $TRUE
    else
        return $FALSE
    fi
}

install_bootstrap_depends() {
    erunquiet sudo apt-get -y --no-install-recommends install p7zip-full git
}

doh_check_odoo_depends() {
    doh_profile_load

    DEPENDS=$(sed -ne '/^Depends:/, /^[^ ]/{/^Depends:/{n;n};/^[^ ]/{q;};s/,$//;p;}' \
        "${DIR_MAIN}/debian/control")
    erunquiet sudo apt-get -y --no-install-recommends install ${DEPENDS}
}

doh_git_ssh_handler() {
    local profile=$(doh_profile_find "$PWD")
    local profile_root_dir=$(dirname "${profile}")
    local profile_conf_dir="${profile_root_dir}/conf"

    local deploy_key_url=$(conf_file_get "${profile}" "profile.deploy_key")
    local deploy_key_file="${profile_conf_dir}/deploy.key"

    local SSH_EXTRA_ARGS=""
    if [ x"${deploy_key_url}" != x"" ] && [ -f "${deploy_key_file}" ]; then
        SSH_EXTRA_ARGS="-i ${deploy_key_file}"
    fi
    ssh $SSH_EXTRA_ARGS "$@"
}

doh_gitlab_project_set_forked_from() {
    # $1: gitlab url, $2: project, $3: forked_from_project
    if [ $# -lt 3 ]; then
        die "Wrong number of parameters for 'doh_gitlab_project_set_forked_from'"
    fi

    url=$(gitlab_extract_baseurl "$1")
    api_url="${url}/api/v3"

    edebug "querying project id for project name '${2}'"
    project_name=$(echo "$2" | urlencode)
    gitlab_api_query "${api_url}/projects/${project_name}" \
        || die "Unable to get project '$2' information"
    project_id=$(echo "${GITLAB_API_RESULT}" | py_json_get_value "id")

    edebug "querying project id for project name '${3}'"
    forked_project_name=$(echo "$3" | urlencode)
    gitlab_api_query "${api_url}/projects/${forked_project_name}" \
        || die "Unable to get project '$3' information"
    forked_project_id=$(echo "${GITLAB_API_RESULT}" | py_json_get_value "id")

    edebug "setting project '${2}' (id: ${project_id}) as forked from '${3}' (id: ${forked_project_id})"
    gitlab_api_query "${api_url}/projects/${project_id}/fork/${forked_project_id}" "--method=POST"
}

doh_fetch_file() {
    # $1: URL, "$2": output file
    if [ $# -lt 2 ]; then
        die "Wrong number of parameters for 'doh_fetch_file'"
    fi

    gitlab_url_match='^((http)[s]?://([^/]+)[/]?)((.*)/snippets/([0-9]|[^/]*).*)$'
    if [[ "${1}" =~ ${gitlab_url_match} ]]; then
        edebug "loading remote gitlab snippet from: ${1}"
        profile_baseloc="${BASH_REMATCH[1]}"
        gitlab_project_name="${BASH_REMATCH[-2]}"
        gitlab_snippet_id="${BASH_REMATCH[-1]}"

        local api_url="${profile_baseloc}api/v3"

        project_name_urlencoded=$(echo "${gitlab_project_name}" | urlencode)

        edebug "querying project id for project name '${gitlab_project_name}'"
        gitlab_api_query "${api_url}/projects/${project_name_urlencoded}" \
            || die "Unable to get project \"${gitlab_project_name}\" information"
        project_id=$(echo "${GITLAB_API_RESULT}" | py_json_get_value "id")
        [ x"${project_id}" = x"" ] && die "Unable to get project Id"

        if ! [[ "${gitlab_snippet_id}" =~ ^[0-9]*$ ]]; then
            edebug "querying snippet id from snipped name '${gitlab_snippet_id}'"
            gitlab_api_query "${api_url}/projects/${project_id}/snippets"
            gitlab_snippet_id=$(echo "${GITLAB_API_RESULT}" \
                | py_json_get_value "" "m=[v['id'] for v in obj if v['file_name'] == '${gitlab_snippet_id}' or v['title'] == '${gitlab_snippet_id}'];print(m[0] if m else '')")
        fi

        edebug "fetching snippet id ${gitlab_snippet_id}"
        gitlab_api_query "${api_url}/projects/${project_id}/snippets/${gitlab_snippet_id}/raw" \
            || die "Unable to get snippet content (or snippet is empty)"
        echo "${GITLAB_API_RESULT}" | sed 's/\r$//'> "${2}"
        return $TRUE
    elif [[ "${1}" =~ ^(http|ftp)[s]?://.* ]]; then
        edebug "loading remote file from: ${1}"
        # wget + load file
        wget -q -O "${2}" "${1}" || die 'Unable to fetch remote file'
        return $TRUE
    fi
    return $FALSE
}

install_postgresql_server() {
    erunquiet sudo apt-get -y --no-install-recommends install postgresql
}

db_client_setup_env() {
    doh_profile_load

    if [ x"$CONF_DB_HOST" != x"" ]; then
        if [ x"$CONF_DB_USER" = x"" ]; then
            die "Config parameter DB_USER is mandatory when using DB_HOST"
        fi
        if [ x"$CONF_DB_PASS" = x"" ]; then
            die "Config parameter DB_PASS is mandatory when using DB_HOST"
        fi
    fi
    for v in HOST PORT USER PASS; do
        db_var="CONF_DB_${v}"
        pg_var="PG${v}"
        if [ x"${!db_var}" != x"" ]; then
            export $pg_var=${!db_var}
        fi
    done
}

db_get_server_version() {
    db_client_setup_env
    echo -n $(psql -A -t -c 'SHOW server_version' postgres)
}

db_get_server_local_cmd() {
    local v=$(db_get_server_version | cut -d'.' -f -2)
    local server_bin_path="/usr/lib/postgresql/${v}/bin"

    if [ -d "${server_bin_path}" ]; then
        echo -n "${server_bin_path}/$1"
    else
        # no specific version, fallback to standard PATH search order
        echo "$1"
    fi
}

db_config_local_server() {
    db_client_setup_env

    ROLES=$(erun sudo -u postgres psql -Atc "SELECT rolname FROM pg_roles WHERE rolname = '$USER'" postgres)
    ROLES_COUNT=$(echo $ROLES | sed '/^$/d' | wc -l)
    if [ $ROLES_COUNT -eq 0 ]; then
        elog "creating postgresql role for user $USER"

        CREATE_USER_ARGS="NOSUPERUSER CREATEDB NOCREATEROLE INHERIT LOGIN;"
        if [ x"$DB_PASS" != x"" ]; then
            CREATE_USER_ARGS="ENCRYPTED PASSWORD '${DB_PASS}' $CREATE_USER_ARGS"
        fi
        erunquiet sudo -u postgres psql -Atc "CREATE ROLE $USER $CREATE_USER_ARGS" || die 'Unable to create database user'
    fi
}

doh_generate_server_config_file() {
    doh_profile_load

    ODOO_CONF_FILE="${DIR_CONF}/odoo-server.conf"
    # ODOO_ADDONS_PATH="${DIR_ADDONS},${DIR_EXTRA}"
    ODOO_ADDONS_PATH="${DOH_ADDONS_PATH}"

    elog "generating odoo config file"
    cat <<EOF | erunquiet tee "${ODOO_CONF_FILE}"
[addons]
[options]
; This is the password that allows database operations:
; admin_passwd = admin
db_host = ${CONF_DB_HOST:-False}
db_port = ${CONF_DB_PORT:-False}
db_user = ${CONF_DB_USER}
db_password = ${CONF_DB_PASS:-False}
addons_path = ${ODOO_ADDONS_PATH}
EOF
    elog "fixing permissions for odoo config file"
    erunquiet sudo chmod 640 "${ODOO_CONF_FILE}"
    erunquiet sudo chown "${CONF_PROFILE_RUNAS}:adm" "${ODOO_CONF_FILE}"
}

doh_generate_server_init_file() {
    doh_profile_load

    ODOO_LOG_FILE="${DIR_LOGS}/odoo-server.log"
    ODOO_CONF_FILE="${DIR_CONF}/odoo-server.conf"

    if [[ "${CONF_PROFILE_VERSION:-8.0}" =~ ^(6.0)$ ]]; then
        TMPL_INIT_FILE="${DIR_MAIN}/debian/openerp-server.init"
    elif [[ "${CONF_PROFILE_VERSION:-8.0}" =~ ^(6.1|7.0)$ ]]; then
        TMPL_INIT_FILE="${DIR_MAIN}/debian/openerp.init"
    else # 8.0 and later
        TMPL_INIT_FILE="${DIR_MAIN}/debian/init"
    fi

    elog "updating odoo init script"
    sed \
        -e "s#^DAEMON=.*\$#DAEMON=${DIR_MAIN}/openerp-server#" \
        -e "s/^\\(NAME\\|DESC\\)=.*\$/\\1=${CONF_PROFILE_NAME}/" \
        -e "s#^CONFIG=.*\$#CONFIG=${ODOO_CONF_FILE}#" \
        -e "s#^LOGFILE=.*\$#LOGFILE=${ODOO_LOG_FILE}#" \
        -e "s/^USER=.*\$/USER=${CONF_PROFILE_RUNAS}/" \
        -e "s#--pidfile /var/run/#--pidfile ${DIR_RUN}/#" \
        ${TMPL_INIT_FILE} | erunquiet sudo tee "/etc/init.d/odoo-${CONF_PROFILE_NAME}"
    erunquiet sudo chmod 755 "/etc/init.d/odoo-${CONF_PROFILE_NAME}"
}

py_json_get_value() {
    parse_json="${2:-print(obj.get('$1'))}"
    python -c "import sys,json;obj=json.load(sys.stdin);${parse_json}"
}

doh_profile_find() {
    SEARCH_PWD="${1:-$PWD}"
    while [ x"$SEARCH_PWD" != x"/" ]; do
        if [ -f "${SEARCH_PWD}/odoo.profile" ]; then
            echo "${SEARCH_PWD}/odoo.profile";
            return $TRUE
        fi
        SEARCH_PWD=$(dirname "$SEARCH_PWD")
    done
    return $FALSE
}

doh_profile_load() {
    if [ x"${DOH_PROFILE_LOADED}" = x"1" ]; then
        return
    fi

    # $1: odoo.profile
    export DIR_ROOT="${PWD}"
    export DIR_MAIN="${PWD}/main"
    export DIR_ADDONS="${PWD}/main/addons"
    export DIR_EXTRA="${PWD}/extra"
    export DIR_CLIENT="${PWD}/client"
    export DIR_CONF="${PWD}/conf"
    export DIR_LOGS="${PWD}/logs"
    export DIR_RUN="${PWD}/run"

    local profile="${1:-odoo.profile}"
    if [[ "${profile}" =~ ^(http|ftp)[s]?://.* ]]; then
        local profile_url="${profile}"
        profile="${DIR_ROOT}/odoo.profile"
        doh_fetch_file "${profile_url}" "${profile}" || die 'Unable to fetch remote profile'

    elif [ -f "${profile}" ]; then
        if [ ! "${profile}" -ef "${DIR_ROOT}/odoo.profile" ]; then
            cp "${profile}" "${DIR_ROOT}/odoo.profile"
        fi
        edebug "loading local profile file: ${profile}"
    else
        die "unable to load profile: ${profile}"
    fi
    OLDIFS="${IFS}"
    SECTIONS=$(conf_file_get_sections "${DIR_ROOT}/odoo.profile")
    for section in ${SECTIONS}; do
        export CONF_${section^^}="1"  # mark section as present
        VARS=$(conf_file_get_options "${DIR_ROOT}/odoo.profile" "${section}")
        IFS=$'\n'; while read -r var; do
            var_name="${var%%=*}"
            var_value="${var#*=}"
            export CONF_${section^^}_${var_name^^}="${var_value}"
        done <<< "${VARS}"
        IFS="$OLDIFS"
    done

    if [ x"${CONF_MAIN}" = x"" ]; then
        # old profile version, move main specific part to main
        export CONF_MAIN="1"
        export CONF_MAIN_BRANCH="${CONF_PROFILE_BRANCH}"
        export CONF_MAIN_REPO="${CONF_PROFILE_REPO}"
        export CONF_MAIN_PATCHSET="${CONF_PROFILE_PATCHSET}"
        export CONF_EXTRA_TYPE="${CONF_EXTRA_TYPE:-archive}"  # set extra, as type="archive"
    fi

    if [ x"${CONF_ADDONS}" != x"" ]; then
        # addons is in a separate directory
        local ADDONS_PATH="${DIR_ROOT}/addons"
        if [ x"${CONF_ADDONS_SUBDIR}" != x"" ]; then
            ADDONS_PATH="${ADDONS_PATH}/${CONF_ADDONS_SUBDIR}"
        fi
        export DIR_ADDONS="${DIR_ROOT}/addons"
    fi

    local ADDONS_PATH=""
    for part in ADDONS EXTRA; do
        local v="CONF_$part";
        local d="DIR_$part";
        local part_path="";

        if [ x"${!v}" = x"1" ]; then
            local vsub="${v}_SUBDIR"
            if [ x"${!vsub}" != x"" ]; then
                part_path="${!d}/${!vsub}"
            else
                part_path="${!d}"
            fi
        elif [ x"${part}" = x"ADDONS" ]; then
            # addons part, but specific section
            part_path="${DIR_MAIN}/addons"
        fi

        if [ x"${part_path}" != x"" ]; then
            if [ x"${ADDONS_PATH}" != x"" ]; then
                ADDONS_PATH="${ADDONS_PATH},"
            fi
            ADDONS_PATH="${ADDONS_PATH}${part_path}"
        fi
    done
    export DOH_ADDONS_PATH="${ADDONS_PATH}"

    export CONF_PROFILE_RUNAS="${CONF_PROFILE_RUNAS:-${USER}}"
    if [ x"${CONF_PROFILE_RUNAS}" != x"$USER" ]; then
        die "error: please re-run this command as '${CONF_PROFILE_RUNAS}' user (this is enforced by current profile)"
    fi

    DOH_PROFILE_LOADED="1"
}

doh_reconfigure() {
    doh_profile_load
    doh_check_dirs

    elog "installing odoo dependencies (sudo)"
    doh_check_odoo_depends

    # fetch remote deploy-key if none local
    if [ x"${CONF_PROFILE_DEPLOY_KEY}" != x"" ]; then
        doh_check_dirs "DIR_CONF"
        elog "fetching profile deploy-key"
        doh_fetch_file "${CONF_PROFILE_DEPLOY_KEY}" "${DIR_CONF}/deploy.key"
        chmod 0400 "${DIR_CONF}/deploy.key"
    fi

    doh_generate_server_config_file
    doh_generate_server_init_file

    elog "fixing permissions for odoo log file"
    erunquiet sudo mkdir -p $(dirname "${ODOO_LOG_FILE}")
    erunquiet sudo touch "${ODOO_LOG_FILE}"
    erunquiet sudo chmod 640 "${ODOO_LOG_FILE}"
    erunquiet sudo chown "${CONF_PROFILE_RUNAS}:adm" "${ODOO_LOG_FILE}"

    if [ x"${CONF_PROFILE_AUTOSTART}" = x"1" ]; then
        elog "adding odoo '${CONF_PROFILE_NAME}' to autostart"
        erunquiet sudo update-rc.d "odoo-${CONF_PROFILE_NAME}" defaults
    fi
}

doh_check_dirs() {
    # check if required dirs exists
    doh_profile_load

    if [ x"$1" != x"" ]; then
        local BASE_DIRS="$1"
    else
        local BASE_DIRS="DIR_ROOT DIR_MAIN DIR_ADDONS DIR_EXTRA DIR_LOGS DIR_RUN DIR_CONF"
        local V="${CONF_PROFILE_VERSION:-8.0}"
        if [ x"${V}" = x"6.0" ] || [ x"${V}" = x"6.1" ]; then
            BASE_DIRS="$BASE_DIRS DIR_CLIENT"
        fi
    fi

    for dir in $BASE_DIRS; do
        if [ ! -d "${!dir}" ]; then
            elog "creating directory ${!dir}"
            mkdir -p "${!dir}"
        fi
    done
}

doh_update_section() {
    [ $# -lt 1 ] && return
    # whitelist allowed sections
    doh_profile_load

    ([ x"${1,,}" != x"main" ] && [ x"${1,,}" != x"addons" ] \
      && [ x"${1,,}" != x"extra" ] && [ x"${1,,}" != x"client" ]) && die "Invalid section ${section}"
    [ x"$(conf_env_get "${1}")" != x"1" ] && return  # section is not defined

    local section="${1^^}"
    local section_dir=$(d="DIR_${section^^}"; echo -n "${!d}")
    local section_repo_url=$(conf_env_get "${section}.repo")
    local section_type=$(conf_env_get "${section}.type" "git")
    local section_branch=$(conf_env_get "${section}.branch")
    local section_patchset=$(conf_env_get "${section}.patchset")
    local section_sparsecheckout=$(conf_env_get "${section}.sparse_checkout")

    if [[ x"${section_type}" = x"git" ]]; then
        elog "updating ${section,,}"
        [ x"${section_repo_url}" = x"" ] && die "No repository url specified for section ${1}"
        section_branch="${section_branch:-master}"  # follow git default branch, i.e 'master'

        export GIT_SSH="$0"

        if ! helper_is_dir_repo "${section_dir}" "${section_type}" "${section_repo_url}"; then
            edebug "creating new empty repository"
            erun rm -Rf -- "${section_dir}"
            erun git init "${section_dir}"
        fi

        # check origin remote url
        local remote_url=$(git -C "${section_dir}" config --get remote.origin.url)
        if [ x"${remote_url}" != x"${section_repo_url}" ]; then
            if [ x"${remote_url}" != x"" ]; then
                erun git -C "${section_dir}" remote remove origin
            fi
            erun git -C "${section_dir}" remote add origin "${section_repo_url}"
        fi

        # check for sparse checkout
        erun git -C "${section_dir}" config core.sparsecheckout true
        local sparsecheckout_path="${section_dir}/.git/info/sparse-checkout"
        if [ x"${section_sparsecheckout}" != x"" ]; then
            echo "${section_sparsecheckout}" | tr ',' '\n'  > "${sparsecheckout_path}"
        else
            echo '/*' > "${sparsecheckout_path}" # default, all files
        fi

        erun git -C "${section_dir}" checkout -f . # remove local changes
        erun --show git -C "${section_dir}" pull -f origin "${section_branch}" || die 'Unable to fetch git repository'
        erun git -C "${section_dir}" checkout -f "${section_branch}"

        unset GIT_SSH

    elif [ x"${section_type}" = x"archive" ]; then
        elog "fetching odoo extra modules"
        local extra_tmp=`mktemp`
        local extra_tmpdir=`mktemp -d`
        erun wget -O "${extra_tmp}" "${CONF_EXTRA_URL}"
        elog "extracting odoo extra modules"
        erunquiet 7z x -y "-o${extra_tmpdir}" "${extra_tmp}"
        rm -Rf "${section_dir}"
        mkdir "${section_dir}"
        local module_parent_dirs=""
        for module_path in $(find "${extra_tmpdir}" -name __openerp__.py -exec dirname {} \;); do
            module_parent_path=$(dirname "${module_path}")
            module_parent_dirs="${module_parent_dir}\n${module_parent_path}"
            local module_name=$(basename "${module_path}")
            elog "extracting module -- ${module_name}"
            mv "${module_path}" "${section_dir}"
        done
        module_parent_dir_unique=$(echo -e "${module_parent_dirs}" | sed '/^$/d' | sort -u | wc -l)
        if [ $module_parent_dir_unique -eq 1 ]; then
            module_parent_dir=$(echo -e "${module_parent_dirs}" | sed '/^$/d' | sort -u)
            if [ -d "${module_parent_dir}/.git" ]; then
                elog "extracting extra git repository"
                mv "${module_parent_dir}/.git" "${section_dir}"
            fi
        fi
        eremove "${extra_tmp}"
        eremove "${extra_tmpdir}"
    else
        die "Unknown section type ${section_type}"
    fi


    if [ x"${section_patchset}" != x"" ]; then
        pushd "${section_dir}"
        elog "fetching odoo patch"
        local patchset_tmp=`mktemp`
        erunquiet wget -q -O "${patchset_tmp}" "${section_patchset}"
        elog "apply odoo patch locally"
        erunquiet git -C "${section_dir}" apply "${patchset_tmp}"
        eremove "${patchset_tmp}"
    fi
}

doh_profile_update() {
    doh_profile_load
    if [ x"${CONF_PROFILE_URL}" != x"" ]; then
        elog "updating odoo profile"
        tmp_profile=`mktemp`
        erunquiet wget -q -O "${tmp_profile}" "${CONF_PROFILE_URL}" || die 'Unable to update odoo profile'
        mv "${tmp_profile}" "${DIR_ROOT}/odoo.profile"
    fi
}

doh_sublime_project_template() {
    doh_profile_load

    PROJ_TMPL_FILE="${DIR_ROOT}/odoo.sublime-project"
    cat >"${PROJ_TMPL_FILE}" <<EOF
{
    "folders":
    [
        {
            "follow_symlinks": true,
            "name": "${CONF_PROFILE_NAME}",
            "path": "./"
        }
    ]
}
EOF
  elog "created sublime-text project template in: ${PROJ_TMPL_FILE}"
}

doh_run_server() {
    doh_profile_load
    doh_check_dirs

    if [ ! -e "${DIR_CONF}/odoo-server.conf" ]; then
        doh_generate_server_config_file
    fi

    local v="${CONF_PROFILE_VERSION:-8.0}"
    if [ x"${v}" = x"8.0" ] || [ x"${v}" = x"7.0" ] || [ x"${v}" = x"master" ]; then
        "${DIR_MAIN}/openerp-server" -c "${DIR_CONF}/odoo-server.conf" "$@"
    elif [ x"${v}" = "6.1" ] || [ x"${v}" = x"6.0" ]; then
        "${DIR_MAIN}/bin/openerp-server.py" -c "${DIR_CONF}/odoo-server.conf" "$@"
    else
        die "No known way to start server for version ${v}"
    fi
}

doh_run_client_gtk() {
    doh_profile_load

    if [ x"${CONF_CLIENT}" != x"1" ]; then
        die "Unable to start gtk client, no 'client' section defined in odoo.profile"
    fi

    local v="${CONF_PROFILE_VERSION:-8.0}"
    if [ x"${v}" != x"6.0" ] && [ x"${v}" != x"6.1" ]; then
        die 'The gtk client is not support for you odoo version'
    fi

    erun "${DIR_CLIENT}/bin/openerp-client.py" "$@"
}

doh_svc_is_running() {
    doh_profile_load

    PIDFILE="${DIR_RUN}/${CONF_PROFILE_NAME}.pid"
    if [ ! -x "${PIDFILE}" ]; then
        # no pidfile, probably not running.
        # still make a 2nd check is ps directly
        PID=$(ps ax | grep "${DIR_MAIN}/openerp-server" | grep -v "grep" | awk '{print $1}')
        if [ x"${PID}" != x"" ]; then
            return 0
        fi
        return 1
    fi
    PID=$(cat "${PIDFILE}")
    RUNNING=$(ps ax | sed 's/^[ ]//g' | grep "^${PID}")
    echo "$RUNNING"
    if [ x"${RUNNING}" != x"" ]; then
        return 0
    fi
    return 1
}

doh_svc_start() {
    if ! doh_svc_is_running; then
        elog "starting service: odoo-${CONF_PROFILE_NAME}"
        erunquiet sudo service "odoo-${CONF_PROFILE_NAME}" start
    fi
}

doh_svc_stop() {
    if doh_svc_is_running; then
        elog "stopping service: odoo-${CONF_PROFILE_NAME}"
        erunquiet sudo service "odoo-${CONF_PROFILE_NAME}" stop
    fi
}

doh_svc_restart() {
    doh_svc_stop
    doh_svc_start
}

#
# Odoo-Helper Commands
#

cmd_help() {
: <<HELP_CMD_HELP
Usage: doh [OPTS | COMMAND] [COMMANDS OPTS...]

Availables standalone options
  --self-upgrade    self-update doh to latest version
  --version         display doh version

Available commands
  install    install and setup a new odoo instance
  upgrade    upgrade odoo and extra modules
  config     get and set odoo profile options
  create-db  create a new database using current profile
  drop-db    drop an existing database
  upgrade-db upgrade a specific database
  start      start odoo service
  stop       stop odoo service
  help       show this help message

Use "doh help CMD" for detail about a specific command
HELP_CMD_HELP

    CMD=${1:-help}
    CMD="${CMD//-/_}"
    CMDTYPE=$(type -t cmd_${CMD})
    if [ x"$CMDTYPE" = x"function" ]; then
        sed --silent \
            -e "/HELP_CMD_${CMD^^}\$/,/^HELP_CMD_${CMD^^}\$/p" "$0" \
          | sed -e "/HELP_CMD_${CMD^^}\$/d"
        exit 2
    else
        echo "odoo-helper: unknown help for command: $1"
        cmd_help "help"
    fi
}

cmd_internal() {
    if [ $# -lt 1 ]; then
	echo "usage: missing commands"
    fi

    CMD="doh_${1//-/_}"; shift;
    $CMD $@
}

cmd_config() {
: <<HELP_CMD_CONFIG
doh config [name [value] | -u name | -l]

Get and set odoo profile options

options:

-l            list all profile variables
-u            unset the following config option
HELP_CMD_CONFIG
    local listall="0"
    local varunset="0"

    OPTIND=1
    while getopts ":lu" opt; do
        case $opt in
            l)
                listall="1"
                ;;
            u)
                varunset="1"
                ;;
        esac
    done
    shift $(($OPTIND - 1))

    if [ x"${listall}" != x"1" ] && [ x"${varunset}" != x"1" ] && [ $# -lt 1 ]; then
        echo "Usage: doh config: missing argument -- NAME"
        cmd_help "config"
    fi

    doh_profile_load
    local conffile="${DIR_ROOT}/odoo.profile"

    if [ x"${listall}" = x"1" ]; then
        local SECTIONS=$(conf_file_get_sections "${conffile}")
        local OLDIFS="${IFS}"
        local opt_name=""
        local opt_value=""

        for section in ${SECTIONS}; do
            VARS=$(conf_file_get_options "${DIR_ROOT}/odoo.profile" "${section}")
            IFS=$'\n'; while read -r var; do
                [ x"${var}" = x"" ] && continue
                opt_name="${var%%=*}"
                opt_value="${var#*=}"
                echo "${section}.${opt_name}=${opt_value}"
            done <<< "${VARS}"
            IFS="$OLDIFS"
        done
    elif [ x"${varunset}" = x"1" ]; then
        conf_file_unset "${DIR_ROOT}/odoo.profile" "$1"
    elif [ $# -ge 2 ]; then
        conf_file_set "${DIR_ROOT}/odoo.profile" "$1" "$2"
    else
        echo $(conf_file_get "${DIR_ROOT}/odoo.profile" "$1")
    fi
}

cmd_init() {
: <<HELP_CMD_INIT
doh init [-f] [-t VERSION] [DIR]

Create a new odoo.profile

options:

-f                  force creation if odoo.profile already exists
-a                  force autostart of profile
-t TEMPLATE         generate a odoo profile based on template
                    (you can use odoo/VERSION for standard template)
HELP_CMD_INIT

    local force="0"
    local template=""
    local autostart=""
    OPTIND=1
    while getopts "ft:" opt; do
        case $opt in
            f)
                force="1"
                ;;
            a)
                autostart="1"
                ;;
            t)
                template="${OPTARG}"
                ;;
        esac
    done
    shift $(($OPTIND - 1))

    DIR="${1:-.}"
    if [ ! -d "$DIR" ]; then
        mkdir -p "$DIR"
    fi

    if [ -f "$DIR/odoo.profile" ] && [ x"${force}" != x"1" ]; then
        die "Unable to create template odoo.profile, file exists. Use -f to override"
    fi

    local n_profile_name='PROFILE_NAME'
    local n_profile_version='8.0'
    local n_profile_update_url=''
    local n_profile_autostart='0'
    local n_main_repo='https://github.com/odoo/odoo'
    local n_main_branch='8.0'

    if [ x"${autostart}" != x"" ]; then
        n_profile_autostart='1'
    fi

    if [ x"${template}" != x"" ]; then

        if [[ "${template}" =~ ^odoo/.* ]]; then
            local n_name="${template:5}"
            n_profile_name="${n_name}"
            n_profile_version="${n_name}"
            n_main_branch="${n_name}"
        else
            # TODO: implement custom template
            die "Custom template not implemented, use odoo/VERSION template instead."
        fi
    fi

    cat <<TMPL_ODOO_PROFILE >${DIR}/odoo.profile
[profile]
name=${n_profile_name}
version=${n_profile_version}
autostart=${n_profile_autostart}
url=${n_profile_update_url}

[main]
repo=${n_main_repo}
branch=${n_main_branch}
patchset=

# [extra]
# repo=
# url=

# [db]
# host=
# port=
# user=
# pass=
# init_modules_on_create=base
# init_extra_args=

TMPL_ODOO_PROFILE
}

cmd_install() {
: <<HELP_CMD_INSTALL
doh install [-d] [-a] [-t TEMPLATE | -p URL] [INSTALL_DIR]

options:

 -d                  install PostgreSQL database server
 -a                  automated startup, start on system boot
 -p URL INSTALL_DIR  load profile from a remote url
 -t TEMPLATE         load profile using a predefined template
HELP_CMD_INSTALL

    local profdir=""
    local profname=""
    local template=""
    OPTIND=1
    while getopts "dat:p:" opt; do
        case $opt in
            d)
                # Install and use local database
                local local_database=true
                ;;
            a)
                # Autostart profile on boot
                local autostart=true
                ;;
            p)
                profname="${OPTARG}"
                ;;
            t)
                template="${OPTARG}"
                ;;
            \?)
                cmd_help "install"
                ;;
        esac
    done
    shift $(($OPTIND - 1))
    profdir="${1:-.}"

    if [ x"$template" = x"" ] && [ x"$profname" = x"" ]; then
        echo "Usage: doh install: missing argument -- template or profile"
        echo -e "    you need to specify at least a template or a profile url\n"
        cmd_help "install"
    fi

    if [ ! -d "$profdir" ]; then
        mkdir -p "$profdir"
    fi
    cd "$profdir"

    if [ x"$template" != x"" ]; then
        cmd_init -t "$template"
    fi

    doh_profile_load "${profname}"

    # override autostart if set on command line
    if [ x"$autostart" = x"true" ]; then
        CONF_PROFILE_AUTOSTART="1"
    fi

    # ensure all directories exists
    doh_check_dirs

    elog 'installing prerequisite dependencies (sudo)'
    install_bootstrap_depends

    elog "fetching odoo from remote git repository (this can take some time...)"
    for part in $DOH_PARTS; do
        doh_update_section "${part}"
    done

    if [ x"$local_database" = x"true" ]; then
        elog "installing postgresql server (sudo)"
        install_postgresql_server
        erunquiet sudo service postgresql start || die 'PostgreSQL server doesnt seems to be running'
        db_config_local_server
    fi

    doh_reconfigure

    if [ x"${CONF_PROFILE_AUTOSTART}" = x"1" ]; then
        elog "starting odoo (sudo)"
        erun sudo service odoo-${CONF_PROFILE_NAME} start

        elog "installation sucessfull, you can now access odoo using http://localhost:8069/"
    else
        elog "installation sucessfull, do not forget to start server (doh start) before accessing odoo using http://localhost:8069/"
    fi
}

cmd_upgrade() {
: <<HELP_CMD_UPGRADE
doh upgrade [DATABASE ...]
HELP_CMD_UPGRADE

    doh_profile_load
    doh_profile_update
    doh_check_dirs

    for part in $DOH_PARTS; do
        doh_update_section "${part}"
    done

    if [ $# -gt 0 ]; then
        for db in $@; do
            cmd_upgrade_db "${db}"
        done
    fi
}

cmd_create_db() {
: <<HELP_CMD_CREATE_DB
doh create-db NAME

HELP_CMD_CREATE_DB
    if [ $# -lt 1 ]; then
        echo "Usage: doh create-db: missing arguemnt -- NAME"
        cmd_help "create_db"
    fi
    local createdb=$(db_get_server_local_cmd "createdb")
    DB="$1"

    doh_profile_load
    db_client_setup_env
    elog "creating database ${DB}"
    erunquiet "${createdb}" -E unicode "${DB}" || die "Unable to create database ${DB}"
    elog "initializing database ${DB} for odoo"
    erunquiet doh_run_server -d "${DB}" --stop-after-init -i "${CONF_DB_INIT_MODULES_ON_CREATE:-base}" ${CONF_DB_INIT_EXTRA_ARGS} || die "Failed to initialize database ${DB}"
    elog "database ${DB} created successfully"
}

cmd_drop_db() {
: <<HELP_CMD_DROP_DB
doh drop-db NAME

HELP_CMD_DROP_DB
    if [ $# -lt 1 ]; then
        echo "Usage: doh drop-db: missing arguments -- NAME"
        cmd_help "drop_db"
    fi
    local dropdb=$(db_get_server_local_cmd "dropdb")
    DB="$1"

    doh_profile_load
    db_client_setup_env
    doh_svc_stop
    elog "droping database ${DB}"
    erunquiet "${dropdb}" "${DB}" || die "Unable to drop database ${DB}"
}

cmd_copy_db() {
: <<HELP_CMD_COPY_DB
doh copy-db TEMPLATE_NAME NAME

HELP_CMD_COPY_DB
    if [ $# -lt 2 ]; then
        echo "Usage: doh copy-db: missing arguments -- TEMPLATE_NAME NAME"
        cmd_help "copy_db"
    fi
    local psql=$(db_get_server_local_cmd "psql")
    TMPL_DB="$1"
    DB="$2"

    doh_profile_load
    db_client_setup_env
    doh_svc_stop
    elog "copying database ${TMPL_DB} to ${DB}"
    erunquiet "${psql}" postgres -c "CREATE DATABASE ${DB} ENCODING 'unicode' TEMPLATE ${TMPL_DB}" || die "Unable to copy database ${TMPL_DB} to ${DB}"
}

cmd_upgrade_db() {
: <<HELP_CMD_UPGRADE_DB
doh upgrade-db [-f] NAME

options:

 -f   start server in foreground

HELP_CMD_UPGRADE_DB

    if [ x"$1" = x"-f" ]; then
        run_in_foreground="1"
    shift
    fi

    if [ $# -lt 1 ]; then
        echo "Usage: doh upgrade-db: missing argument -- NAME"
        cmd_help "upgrade_db"
    fi
    DB="$1"

    doh_profile_load
    elog "upgrading ${DB}... (will take some time)"
    if [ x"${run_in_foreground}" != x"" ]; then
        exec 1>&6 6>&-
        exec 2>&7 7>&-
        doh_run_server -d "${DB}" --stop-after-init -u all || die 'Unable to upgrade database'
    else
        erunquiet doh_run_server -d "${DB}" --stop-after-init -u all || die 'Unable to upgrade database'
    fi
    elog "database ${DB} upgraded successfully"
}

cmd_client() {
: <<HELP_CMD_CLIENT
doh client

HELP_CMD_CLIENT

    doh_profile_load
    doh_run_client_gtk "$@"
}

cmd_start() {
: <<HELP_CMD_START
doh start [-f]

options:

 -f   start server in foreground
HELP_CMD_START

    if [ x"$1" = x"-f" ]; then
        run_in_foreground="1"
	shift
    fi

    doh_profile_load
    if [ x"${run_in_foreground}" != x"" ]; then
        exec 1>&6 6>&-
        exec 2>&7 7>&-
        doh_run_server "$@"
    else
        doh_svc_start
    fi
}

cmd_stop() {
: <<HELP_CMD_STOP
doh start [-f]

HELP_CMD_STOP
    doh_profile_load
    doh_svc_stop
}

# special case when calling our-self as GIT_SSH handler
ppid_exe=$(readlink /proc/$PPID/exe)
ppid_name=$(basename "${ppid_exe}")
if [ x"${GIT_SSH}" = x"$0" ] && [ x"${ppid_name}" = x"git" ]; then
    doh_git_ssh_handler "$@";
    exit 0;
fi

CMD="$1"; shift;
case $CMD in
    internal-self-upgrade|--self-upgrade)
        # TOOD: add self-upgrading function
        elog "going to upgrade doh (path: $0) with remote version, press ENTER to continue or Ctrl-C to cancel"
        read ok
        tmp_doh=`mktemp`
        wget -q -O "${tmp_doh}" "https://raw.githubusercontent.com/xavieralt/doh/master/doh" || die 'Unable to fetch remote doh'
        (cat "${tmp_doh}" | sudo tee "$0" >/dev/null) || die 'Unable to update doh'
        sudo chmod 755 "$0"  # ensure script is executable
        exit 0
        ;;
    --version)
        echo "doh v${DOH_VERSION}"
        ;;
    *)
        doh_setup_logging
        if [ x"$CMD" != x"" ]; then
            CMD_FUNC="cmd_${CMD//-/_}"
            CMD_TYPE=$(type -t "$CMD_FUNC")
            if [ x"$CMD_TYPE" = x"function" ]; then
                $CMD_FUNC "$@"
            else
                echo "odoo-helper: unknown command: $CMD"
                cmd_help
            fi
        else
            cmd_help
        fi
        ;;
esac
