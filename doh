#!/bin/bash

DOH_VERSION="0.5"

# Setup output logging
#DOH_LOGFILE=/tmp/doh.$$.log
DOH_LOGLEVEL="${DOH_LOGLEVEL:-info}"
DOH_PROFILE_LOADED="0"
DOH_PARTS="main addons extra enterprise themes client"
DOH_USER_GLOBAL_CONFIG="$HOME/.config/doh"

# HELPERS GLOBALS
declare -A GITLAB_CACHED_AUTH_TOKENS
declare -A GITLAB_CACHED_AUTH_USERS
declare -A GITLAB_CACHED_AUTH_PASSWD
declare GITLAB_API_RESULT


# GLOBAL CONFIG (default)
export CONF_RUNTIME_DEVELOPER_MODE=0

export CONF_RUNTIME_DOCKER=0
export CONF_RUNTIME_DOCKER_NETWORK=odoo
export CONF_RUNTIME_DOCKER_PGHOST=db
export CONF_RUNTIME_DOCKER_PGUSER=odoo
export CONF_RUNTIME_DOCKER_PGPASSWD=odoo
export CONF_RUNTIME_DOCKER_DATAVOLUME=odoo-data
export CONF_RUNTIME_DOCKER_PGIMAGE=postgres:9.4

doh_setup_logging() {

if [ x"${DOH_LOGFILE}" = x"" ]; then
    return
fi

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
    if [ x"${DOH_LOGFILE}" != x"" ]; then
        "$@" 2>&1 >>${DOH_LOGFILE}
    else
        "$@" >/dev/null 2>&1
    fi
    return $?
}

erun() {
    if [ x"$1" = x"--show" ]; then
        shift;
        edebug "will run: $@"
        if [ x"${DOH_LOGFILE}" != x"" ]; then
            "$@" >&6 2>&7
        else
            "$@"
        fi
    else
        edebug "will run: $@"
        if [ x"${DOH_LOGFILE}" != x"" ]; then
            "$@" >>${DOH_LOGFILE} 2>&1
        else
            "$@" >/dev/null 2>&1
        fi
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
    elif [ x"${DOH_LOGFILE}" != x"" ]; then
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
        edebug "deleting $1"
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
        sed -n "/^\[${section}\]/,$ { /^\[/{s/^\[\(.*\)\]$/\1/; x; d}; x; /^${section}$/!{x; d; n}; x; /^#/d; s/[ \\t]*$//; /^$/d; p;}" "${conffile}"
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

sanitize_url_to_cache_dirname() {
    local cache_name=$(echo "$1" | sed -r 's#^[a-zA-Z0-9]*://(.*@)?##; s/\.git$//; s/[^a-zA-Z0-9]/_/g')
    local cache_dir="${CONF_GIT_CACHE_DIR}/${cache_name}"
    echo "${cache_dir}"
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
        local session=$(curl -s -f "${session_url}" --data "login=${gitlab_username}&password=${gitlab_password}")
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
    session_url_status=$(curl -s --dump-header - "${session_url}" 2>&1 | sed -n '/\s*HTTP/{s#\s*HTTP\/.\.. \([0-9]*\) .*#\1#; p; q};')
    if [ x"$session_url_status" = x"405" ]; then
        return $TRUE
    else
        return $FALSE
    fi
}

gitlab_api_query() {
    # $1: gitlab url
    # $2: curl extra args
    gitlab_url=$(gitlab_extract_baseurl "$1")
    if [ $? -ne 0 ]; then
        die "Unable to extract Gitlab base url from $1"
    fi

    gitlab_cache_auth_token "${gitlab_url}" || die "Unable to get authentication token"
    auth_token="${GITLAB_CACHED_AUTH_TOKENS[${gitlab_url}]}"

    GITLAB_API_RESULT=$(curl -s -f --header "PRIVATE-TOKEN: ${auth_token}" "$1" $2)
    if [ $? -eq 0 ]; then
        return $TRUE
    else
        return $FALSE
    fi
}

dpkg_check_packages_installed() {
    local installed="$(dpkg --list | grep '^ii' | awk '{print $2}')"
    local missing_pkgs=""

    for pkg in $@; do
        if ! (echo "${installed}" | grep -E "^${pkg}\$" >/dev/null 2>&1); then
            missing_pkgs="${missing_pkgs} ${pkg}"
        fi
    done

    if ! [ -z "${missing_pkgs}" ]; then
        elog "installing missing dependencies: ${missing_pkgs} (sudo)"
        DEBIAN_FRONTEND="noninteractive" erunquiet sudo apt-get -y --no-install-recommends install ${missing_pkgs}
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
    elif [ -f "${dir_repo_path}" ] && grep -q -E "^gitdir: .*worktrees.*" "${dir_repo_path}"; then
        return $TRUE  # this a worktree instance
    else
        return $FALSE
    fi
}

doh_check_stage0_depends() {
    if ! (which sudo >/dev/null 2>&1); then
        echo "please install sudo before continuing";
        exit 2;
    fi
    if ! (which curl >/dev/null 2>&1); then
        if [ -t 0 ]; then
            while true; do
                read -p "we need to install 'curl' before continuing, proceed? [y/n] " yn
                case $yn in
                    [yY]* ) dpkg_check_packages_installed "curl"; break;;
                    [nN]* ) exit 2;;
                    * ) echo "please choose Y or N";;
                esac
            done
        else
            dpkg_check_packages_installed "curl"
        fi
    fi
}

doh_check_bootstrap_depends() {
    local deps="p7zip-full git python patch openssh-client"
    local missing_pkg=""
    local dpkg
    local dexe
    local dexe_path

    dpkg_check_packages_installed $deps

    if ! (dpkg --compare-versions "$(git --version | awk '{print $NF}')" ">=" "1.9"); then
        die "please upgrade git version to at least 1.9
    sudo apt-get install python-software-properties
    sudo add-apt-repository ppa:git-core/ppa
    sudo apt-get update
    sudo apt-get install git
"
    fi

    return $TRUE
}

doh_check_odoo_depends() {
    doh_profile_load

    if [ x"${CONF_RUNTIME_DOCKER}" != x"0" ]; then
        dpkg_check_packages_installed "docker-engine"
        return
    fi

    local depend_parts="MAIN"
    if [ x"${CONF_CLIENT}" = x"1" ]; then
        depend_parts="${depend_parts} CLIENT"
    fi

    for p in ${depend_parts}; do
        elog "checking ${p,,} dependencies"
        pdir="DIR_${p}"
        pextra_depends="CONF_${p}_EXTRADEPENDS"

        DEPENDS=$(
            sed -ne '/\(^Depends:\)/,/^[^ ]/{p}' ${!pdir}/debian/control \
                | sed '1d; $d' | tr ',' '\n' | sed 's/^\s*\([^ ]*\).*/\1/; /^\$/d; /^$/d')

        if [ x"${!pextra_depends}" != x"" ]; then
            DEPENDS="$DEPENDS ${!pextra_depends}"
        fi

        dpkg_check_packages_installed $DEPENDS

    done
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
    gitlab_api_query "${api_url}/projects/${project_id}/fork/${forked_project_id}" "--request POST"
}

doh_fetch_file() {
    # $1: URL, "$2": output file
    if [ $# -lt 2 ]; then
        die "Wrong number of parameters for 'doh_fetch_file'"
    fi

    gitlab_url_match='^((http)[s]?://([^/]+)[/]?)((.*)/snippets/([0-9]+|[^/]*).*)$'
    if [[ "${1}" =~ ${gitlab_url_match} ]]; then
        edebug "loading remote gitlab snippet from: ${1}"
        profile_baseloc="${BASH_REMATCH[1]}"
        gitlab_project_name="${BASH_REMATCH[5]}"
        gitlab_snippet_id="${BASH_REMATCH[6]}"

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
        # fetch + load file
        (curl -s -f "${2}" > "${1}") || die 'Unable to fetch remote file'
        return $TRUE
    fi
    return $FALSE
}

db_client_setup_env() {
    # $1: postgresql env to set
    doh_profile_load

    local pgvars_all="HOST PORT USER PASSWORD"
    local pgvars="${1:-${pgvars_all}}"
    local db_var
    local pg_var

    for v in ${pgvars_all}; do
        unset "PG${var}"
    done
    for v in ${pgvars}; do
        db_var="CONF_DB_${v}"
        pg_var="PG${v}"
        if [ x"${!db_var}" != x"" ]; then
            export $pg_var=${!db_var}
        fi
    done
}

db_get_server_is_local() {
    # $1: database hostname
    [[ "${CONF_DB_HOST}" =~ ^(|localhost|127.0.0.1)$ ]]
    return $?
}

db_get_server_local_cmd() {
    doh_profile_load

    if [ x"${CONF_RUNTIME_DOCKER}" != x"0" ]; then
        local cmd="$1"
        local dk_network="${CONF_RUNTIME_DOCKER_NETWORK}"
        local dk_db_name="${CONF_RUNTIME_DOCKER_PGHOST}"
        local dk_db_container_name="${dk_network}-${dk_db_name}"
        local dk_extra_args="${DOH_DOCKER_CMD_EXTRA:-}"
        local dk_mode="-it"
        if [ x"${DOH_DOCKER_NO_TTY}" = x"1" ] || [ ! -t 0 ]; then
            dk_mode="-i"
        fi
        if [ x"$1" = x"psql" ]; then
            dk_extra_args="${dk_extra_args} -e TERM"
            if [ -f "$HOME/.psql_history" ]; then
                dk_extra_args="${dk_extra_args} -v ${HOME}/.psql_history:/root/.psql_history"
            fi
            # dk_extra_args="${dk_extra_args} -e PAGER=/bin/less -v /usr/bin/less:/bin/less:ro"

            # Force using psql (link pg_wrapper) to preload readline,
            # otherwise line / completion is pretty fucked up.
            cmd="/usr/bin/psql"
        fi
        echo docker run --rm ${dk_mode} --net=${dk_network} \
            -e PGHOST="${dk_db_name}" \
            -e PGUSER="${CONF_RUNTIME_DOCKER_PGUSER}" \
            -e PGPASSWORD="${CONF_RUNTIME_DOCKER_PGPASSWD}" \
            ${dk_extra_args} \
            ${CONF_RUNTIME_DOCKER_PGIMAGE} \
            ${cmd}
        return $TRUE
    elif ! db_get_server_is_local; then
        echo "$1";
        return $TRUE
    fi
    db_client_setup_env "PORT"
    local v=$(psql -A -t -c 'SHOW server_version' postgres | cut -d'.' -f -2)
    local server_bin_path="/usr/lib/postgresql/${v}/bin"

    if [ -d "${server_bin_path}" ]; then
        echo -n "${server_bin_path}/$1"
    else
        # no specific version, fallback to standard PATH search order
        echo "$1"
    fi
}

db_config_local_server() {
    doh_profile_load

    if [ x"${CONF_RUNTIME_DOCKER}" != x"0" ]; then
        local dk_network="${CONF_RUNTIME_DOCKER_NETWORK}"
        local dk_db_name="${CONF_RUNTIME_DOCKER_PGHOST}"
        local dk_db_container_name="${dk_network}-${dk_db_name}"

        docker_network_create "${dk_network}"
        docker_volume_create "${dk_db_container_name}-data"
        if ! docker_container_exist "${dk_db_container_name}"; then
            elog "Creating database container: ${dk_db_container_name}"
            docker run -d --name=${dk_db_container_name} \
                --net=${dk_network} --net-alias=${dk_db_name} \
                -v "${dk_db_container_name}-data:/var/lib/postgresql/data" \
                -e POSTGRES_USER=${CONF_RUNTIME_DOCKER_PGUSER} \
                -e POSTGRES_PASSWD=${CONF_RUNTIME_DOCKER_PGPASSWD} \
                ${CONF_RUNTIME_DOCKER_PGIMAGE}
        fi

    elif db_get_server_is_local; then
        edebug "configuring local database server"

        # only export PGPORT environement
        # - server is local (dont care about HOST)
        # - running admin ops (dont care about USER PASS)
        db_client_setup_env "PORT"

        local psql_bin_path=$(db_get_server_local_cmd "psql")
        local roles=$(sudo -u postgres ${psql_bin_path} -Atc "SELECT rolname FROM pg_roles WHERE rolname = '${CONF_DB_USER}'" postgres)
        local roles_count=$(echo ${roles} | sed '/^$/d' | wc -l)

        if [ ${roles_count} -eq 0 ]; then
            elog "creating postgresql role for user: ${CONF_DB_USER}"

            create_user_args="NOSUPERUSER CREATEDB NOCREATEROLE INHERIT LOGIN;"
            if [ x"$DBPASS" != x"" ]; then
                create_user_args="ENCRYPTED PASSWORD '${CONF_DB_PASSWORD}' ${create_user_args}"
            fi
            erunquiet sudo -u postgres ${psql_bin_path} -Atc "CREATE ROLE \"${CONF_DB_USER}\" ${create_user_args}" || die 'Unable to create database user'
        fi
    fi
}

doh_generate_server_config_file() {
    doh_profile_load

    ODOO_CONF_FILE="${DIR_CONF}/odoo-server.conf"
    # ODOO_ADDONS_PATH="${DIR_ADDONS},${DIR_EXTRA}"
    ODOO_ADDONS_PATH="${DOH_ADDONS_PATH}"

    local with_sudo="sudo"
    if [ x"${CONF_RUNTIME_DEVELOPER_MODE}" != x"0" ]; then
        with_sudo=""
    fi


    if [ ! -f ${ODOO_CONF_FILE} ]; then
        elog "generating odoo config file"
        cat <<EOF | erunquiet ${with_sudo} tee "${ODOO_CONF_FILE}"
[options]
; This is the password that allows database operations:
; admin_passwd = admin
db_host = ${CONF_DB_HOST:-False}
db_port = ${CONF_DB_PORT:-False}
db_user = ${CONF_DB_USER}
db_password = ${CONF_DB_PASSWORD:-False}
addons_path = ${ODOO_ADDONS_PATH}
EOF
    fi

    VARS=$(conf_file_get_options "${DIR_ROOT}/odoo.profile" "server")
    if [ x"${VARS}" != x"" ]; then
        elog "merging custom odoo config value from profile"
        OLDIFS="${IFS}#"
        IFS=$'\n'; while read -r var; do
            var_name="${var%%=*}"
            var_value="${var#*=}"
            conf_file_set "${ODOO_CONF_FILE}" "options.${var_name}" "${var_value}"
        done <<< "${VARS}"
        IFS="$OLDIFS"
    fi

    local odoo_conf_file_perm="640"
    if [ x"${CONF_RUNTIME_DEVELOPER_MODE}" != x"0" ]; then
        odoo_conf_file_perm="644"
    fi
    if [ x$(stat -c %a ${ODOO_CONF_FILE}) != x"${odoo_conf_file_perm}" ]; then
        elog "fixing permissions for odoo config file"
        erunquiet ${with_sudo} chmod ${odoo_conf_file_perm} "${ODOO_CONF_FILE}"
    fi

    if [ x"${CONF_RUNTIME_DEVELOPER_MODE}" = x"0" ]; then
        erunquiet sudo chown "${CONF_PROFILE_RUNAS}:adm" "${ODOO_CONF_FILE}"
    fi
}

doh_generate_server_init_file() {
    doh_profile_load

    if [ "${CONF_PROFILE_INITRC:-1}" -eq 0 ]; then
        return $FALSE
    fi

    ODOO_LOG_FILE="${DIR_LOGS}/odoo-server.log"
    ODOO_CONF_FILE="${DIR_CONF}/odoo-server.conf"
    ODOO_DAEMON="${DIR_MAIN}/openerp-server"

    if [[ "${CONF_PROFILE_VERSION:-8.0}" =~ ^(6.0)$ ]]; then
        TMPL_INIT_FILE="${DIR_MAIN}/debian/openerp-server.init"
        ODOO_DAEMON="${DIR_MAIN}/bin/openerp-server.py"
    elif [[ "${CONF_PROFILE_VERSION:-8.0}" =~ ^(6.1|7.0)$ ]]; then
        TMPL_INIT_FILE="${DIR_MAIN}/debian/openerp.init"
    else # 8.0 and later
        TMPL_INIT_FILE="${DIR_MAIN}/debian/init"
    fi

    elog "updating odoo init script"
    sed \
        -e "s#^DAEMON=.*\$#DAEMON=${ODOO_DAEMON}#" \
        -e "s/^\\(NAME\\|DESC\\)=.*\$/\\1=${CONF_PROFILE_NAME}/" \
        -e "s#^CONFIG=.*\$#CONFIG=${ODOO_CONF_FILE}#" \
        -e "s#^LOGFILE=.*\$#LOGFILE=${ODOO_LOG_FILE}#" \
        -e "s/^USER=.*\$/USER=${CONF_PROFILE_RUNAS}/" \
        -e "s#--pidfile /var/run/#--pidfile ${DIR_RUN}/#" \
        -e "s#--config=[^ ]* #--config=${ODOO_CONF_FILE} #" \
        -e "s#--logfile=[^ ]*#--logfile=${ODOO_LOG_FILE} #" \
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

    local user_profile_only="0"
    if [ x"$1" = x"--user-profile-only" ]; then
        user_profile_only="1"
    fi

    local profile="${1:-odoo.profile}"
    local ROOT="${PWD}"

    if [ -f "${profile}" ]; then
        ROOT=$(dirname "${profile}")
    elif [[ x"${user_profile_only}" != x"1" ]] && [[ ! "${profile}" =~ ^(http|ftp)[s]?://.* ]]; then
       # try to find profile in upper directories
       local initpwd="$PWD"
       NEW_ROOT=$(while [ x"${DIRSTACK[0]}" != x"/" ]; do
           if [ -f "${profile}" ]; then
               echo "${PWD}"
               break
           fi
           pushd .. >/dev/null 2>&1
       done)
       if [ x"${NEW_ROOT}" != x"" ] && [ -f "${NEW_ROOT}/${profile}" ]; then
           ROOT="${NEW_ROOT}"
           cd "${ROOT}"
       fi
    fi

    # $1: odoo.profile
    export DIR_ROOT="${ROOT}"
    export DIR_MAIN="${ROOT}/main"
    export DIR_ADDONS="${ROOT}/main/addons"
    export DIR_EXTRA="${ROOT}/extra"
    export DIR_ENTERPRISE="${ROOT}/enterprise"
    export DIR_THEMES="${ROOT}/themes"
    export DIR_CLIENT="${ROOT}/client"
    export DIR_CONF="${ROOT}/conf"
    export DIR_LOGS="${ROOT}/logs"
    export DIR_RUN="${ROOT}/run"

    if [ -f ${DIR_ROOT}/odoo-server.conf ]; then
        export DIR_CONF="${ROOT}"
    fi

    # load user global config
    if [ -f "${DOH_USER_GLOBAL_CONFIG}" ]; then
        edebug "loading user global profile"
        OLDIFS="${IFS}"
        SECTIONS=$(conf_file_get_sections "${DOH_USER_GLOBAL_CONFIG}")
        for section in ${SECTIONS}; do
            if [ x"${section}" = x"server" ]; then
                continue  # server section contain only odoo-server.conf options
            fi
            export CONF_${section^^}="1"  # mark section as present
            VARS=$(conf_file_get_options "${DOH_USER_GLOBAL_CONFIG}" "${section}")
            IFS=$'\n'; while read -r var; do
                var_name="${var%%=*}"
                var_value="${var#*=}"
                export CONF_${section^^}_${var_name^^}="${var_value}"
            done <<< "${VARS}"
            IFS="$OLDIFS"
        done
    fi

    if [ x"${user_profile_only}" = x"1" ]; then
        # do not try to load repository profile
        # do not set DOH_PROFILE_LOADED
        return
    fi

    local profile="${1:-odoo.profile}"
    if [[ "${profile}" =~ ^(http|ftp)[s]?://.* ]]; then
        local profile_url="${profile}"
        profile="${DIR_ROOT}/odoo.profile"
        doh_fetch_file "${profile_url}" "${profile}" || die 'Unable to fetch remote profile'
        sudo chmod 640 "${profile}"
        sudo chown "$USER:adm" "${profile}"

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
    local EXTRA_PARTS=""
    for section in ${SECTIONS}; do
        if [ x"${section}" = x"server" ]; then
            continue  # server section contain only odoo-server.conf options
        fi
        export CONF_${section^^}="1"  # mark section as present
        VARS=$(conf_file_get_options "${DIR_ROOT}/odoo.profile" "${section}")
        IFS=$'\n'; while read -r var; do
            var_name="${var%%=*}"
            var_value="${var#*=}"
            export CONF_${section^^}_${var_name^^}="${var_value}"
        done <<< "${VARS}"
        IFS="$OLDIFS"
        if [ x"${section:0:5}" = x"extra" ] && [ x"${section}" != x"extra" ]; then
            EXTRA_PARTS=" ${EXTRA_PARTS} ${section^^}"
            export DIR_${section^^}="${ROOT}/${section}"
        fi
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
    local DOCKER_VOLUMES=${DOCKER_VOLUMES:-}
    local DOCKER_VOLUMES_PATH=""
    for part in  ${EXTRA_PARTS} EXTRA ENTERPRISE ADDONS THEMES; do
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
                DOCKER_VOLUMES_PATH="${DOCKER_VOLUMES_PATH},"
            fi
            ADDONS_PATH="${ADDONS_PATH}${part_path}"
            DOCKER_VOLUMES="${DOCKER_VOLUMES} -v $(readlink -f ${part_path}):/mnt/${part,,}:ro"
            DOCKER_VOLUMES_PATH="${DOCKER_VOLUMES_PATH}/mnt/${part,,}"
        fi
    done
    export DOH_ADDONS_PATH="${ADDONS_PATH}"
    export DOH_DOCKER_VOLUMES="${DOCKER_VOLUMES}"
    export DOH_DOCKER_VOLUMES_PATH="${DOCKER_VOLUMES_PATH}"

    export CONF_PROFILE_RUNAS="${CONF_PROFILE_RUNAS:-${USER}}"

    # check for db configuration
    export CONF_DB_USER="${CONF_DB_USER:-${CONF_PROFILE_RUNAS}}"
    export CONF_DB_PORT="${CONF_DB_PORT:-5432}"

    if [ x"${CONF_DB_PASSWORD}" != x"" ] && [ x"${CONF_DB_HOST}" = x"" ]; then
        CONF_DB_HOST="localhost"
    fi
    if [ x"${CONF_DB_USER}" != x"${CONF_PROFILE_RUNAS}" ] && [ x"${CONF_DB_HOST}" = x"" ]; then
        die "please set db host in odoo.profile\n\
    connecting to database local socket with a database user different from server's running user is not supported"
    fi
    if [ x"$CONF_DB_HOST" != x"" ]; then
        if [ x"${CONF_DB_USER}" = x"" ]; then
            die "Config parameter DB_USER is mandatory when using DB_HOST"
        fi
        if [ x"${CONF_DB_PASSWORD}" = x"" ]; then
            die "Config parameter DB_PASSWORD is mandatory when using DB_HOST"
        fi
    fi

    local v="${CONF_PROFILE_VERSION:-8.0}"
    if [[ x"${v}" =~ ^x(10.0|master)$ ]]; then
        export CONF_SERVER_RCFILE="odoo.conf"
        export CONF_SERVER_CMD="odoo"
        export CONF_SERVER_CMDDEV="odoo-bin"
        export CONF_SERVER_PKGDIR="odoo"
    else
        export CONF_SERVER_RCFILE="openerp-server.conf"
        export CONF_SERVER_CMD="openerp-server"
        export CONF_SERVER_CMDDEV="openerp-server"
        export CONF_SERVER_PKGDIR="openerp"
    fi

    DOH_PROFILE_LOADED="1"
}

doh_reconfigure() {
    # $1: stage
    doh_profile_load
    doh_check_dirs

    local stage="${1:-all}"

    if [[ "${stage}" =~ ^(pre|all)$ ]]; then
        # doh_check_bootstrap_depends

        # check run-as user
        runas_entry=$(getent passwd "${CONF_PROFILE_RUNAS}")
        if [ $? -ne 0 ] && [ x"${CONF_RUNTIME_DEVELOPER_MODE}" = x"0" ]; then
            elog "adding new system user '${CONF_PROFILE_RUNAS}' (sudo)"
            erun sudo adduser --system --quiet --group "${CONF_PROFILE_RUNAS}"
        fi

        # fetch remote deploy-key if none local
        if [ x"${CONF_PROFILE_DEPLOY_KEY}" != x"" ] \
                && [ x"${CONF_RUNTIME_DEVELOPER_MODE}" = x"0" ]; then
            doh_check_dirs "DIR_CONF"
            elog "fetching profile deploy-key"
            touch "${DIR_CONF}/deploy.key"
            chmod 0600 "${DIR_CONF}/deploy.key"
            doh_fetch_file "${CONF_PROFILE_DEPLOY_KEY}" "${DIR_CONF}/deploy.key"
        fi
    fi

    if [[ "${stage}" =~ ^(post|all) ]]; then
        # doh_check_odoo_depends

        # db_config_local_server

        doh_generate_server_config_file

        if [ x"${CONF_RUNTIME_DEVELOPER_MODE}" = x"0" ]; then
            doh_generate_server_init_file

            elog "fixing permissions for odoo log file"
            doh_check_dirs "DIR_LOGS"
            ODOO_LOG_FILE="${DIR_LOGS}/odoo-server.log"
            erunquiet sudo mkdir -p $(dirname "${ODOO_LOG_FILE}")
            erunquiet sudo touch "${ODOO_LOG_FILE}"
            erunquiet sudo chmod 640 "${ODOO_LOG_FILE}"
            erunquiet sudo chown "${CONF_PROFILE_RUNAS}:adm" "${ODOO_LOG_FILE}"

            if [ x"${CONF_PROFILE_AUTOSTART}" = x"1" ] && [ "${CONF_PROFILE_INITRC:-1}" -ne 0 ]; then
                elog "adding odoo '${CONF_PROFILE_NAME}' to autostart"
                erunquiet sudo update-rc.d "odoo-${CONF_PROFILE_NAME}" defaults
            fi
        fi
    fi
}

doh_check_dirs() {
    # check if required dirs exists
    doh_profile_load

    if [ x"$1" != x"" ]; then
        local BASE_DIRS="$1"
    else
        local BASE_DIRS="DIR_ROOT DIR_MAIN DIR_ADDONS DIR_EXTRA"
        if [ x"${CONF_RUNTIME_DEVELOPER_MODE}" = x"0" ]; then
            BASE_DIRS="${BASE_DIR} DIR_LOGS DIR_RUN DIR_CONF"
        fi
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

doh_cache_update() {
    doh_profile_load --user-profile-only

    local repourl=""
    if [ x"${CONF_GIT_CACHE_DIR}" != x"" ] && [ -d "${CONF_GIT_CACHE_DIR}" ]; then
        for repodir in $(ls -1 "${CONF_GIT_CACHE_DIR}"); do
            repourl=$(git -C "${CONF_GIT_CACHE_DIR}/${repodir}" config remote.origin.url)
            elog "updating cached repository from ${repourl}"
            erun git -C "${CONF_GIT_CACHE_DIR}/${repodir}" --bare fetch all

            #git -C "${CONF_GIT_CACHE_DIR}/${repodir}" --bare repack -a -d -l
        done
    fi
}

doh_cache_migrate_existing_section() {
    doh_profile_load

    local section="${1,,}"
    local section_dir=$(d="DIR_${section^^}"; echo -n "${!d}")
    local section_repo_url=$(conf_env_get "${section}.repo")

    local cache_dir=$(sanitize_url_to_cache_dirname "${section_repo_url}")
    local obj_alternate_file="${section_dir}/.git/objects/info/alternates"

    if [ ! -e "${cache_dir}" ]; then
        die "Unable to migrate, cached repository does not exists"
    fi
    if [ -e "${obj_alternate_file}" ]; then
        die "Unable to migrate, objects alternates already exists"
    fi

    edebug "configure section ${section} to use objects from cache"
    echo "${cache_dir}/objects" > "${obj_alternate_file}"

    edebug "repacking section ${section}"
    erun git -C "${section_dir}" repack -a -d -l
}

doh_update_section() {
    local section_clean="0"

    OPTIND=1
    while getopts ":c" opt; do
        case $opt in
            c)
                section_clean="1"
                ;;
        esac
    done
    shift $(($OPTIND - 1))

    [ $# -lt 1 ] && return
    # whitelist allowed sections
    doh_profile_load

    ([ x"${1,,}" != x"main" ] && [ x"${1,,}" != x"addons" ] \
      && [ x"${1,,}" != x"extra" ] && [ x"${1,,}" != x"client" ] \
      && [ x"${1,,}" != x"enterprise" ] && [ x"${1,,}" != x"themes" ]
      ) && die "Invalid section ${section}"
    [ x"$(conf_env_get "${1}")" != x"1" ] && return  # section is not defined

    local section="${1^^}"
    local section_name="$1"
    local section_dir=$(d="DIR_${section^^}"; echo -n "${!d}")
    local section_repo_url=$(conf_env_get "${section}.repo")
    local section_type=$(conf_env_get "${section}.type" "git")
    local section_branch=$(conf_env_get "${section}.branch")
    local section_patchset=$(conf_env_get "${section}.patchset")
    local section_sparsecheckout=$(conf_env_get "${section}.sparse_checkout")

    if [ x"${section_patchset}" != x"" ]; then
        # when have section with patch, forcing cleanup
        section_clean="1"
    fi

    if [[ x"${section_type}" = x"git" ]]; then
        elog "updating ${section,,}"
        [ x"${section_repo_url}" = x"" ] && die "No repository url specified for section ${1}"
        section_branch="${section_branch:-master}"  # follow git default branch, i.e 'master'
        local newly_created_git_repo="0"

        export GIT_SSH="$0"

        if ! helper_is_dir_repo "${section_dir}" "${section_type}" "${section_repo_url}"; then
            newly_created_git_repo="1"
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

        # check for object store reference/cache directory (saving spaces)
        if [ x"${CONF_GIT_CACHE_DIR}" != x"" ]; then
            if [ ! -d "${CONF_GIT_CACHE_DIR}" ]; then
                mkdir -p "${CONF_GIT_CACHE_DIR}"
            fi
            local cache_dir=$(sanitize_url_to_cache_dirname "${section_repo_url}")

            if [ ! -e "${cache_dir}" ]; then
                edebug "cloning repository to cache"
                erun git -c "credential.helper=cache" clone --bare "${section_repo_url}" "${cache_dir}" || die 'Unable to clone cache git repository'
            else
                edebug "updating repository to cache"
                erun git -C "${cache_dir}" -c "credentail.helper=cache" fetch --all || die 'Unable to update cache git repository'
            fi

            if [ x"${newly_created_git_repo}" = x"1" ]; then
                doh_cache_migrate_existing_section "${section}"
            fi
        fi

        # pre-fetch
        local section_current_branch=$(git -C "${section_dir}" symbolic-ref --short HEAD)
        if [ x"${section_clean}" = x"1" ]; then
            edebug "update-section ${section_name}: pre-fetch: removing local changes"
            erun git -C "${section_dir}" checkout -f . # remove local changes
        fi

        # fetch
        edebug "update-section ${section_name}: fetch: fetching from origin/${section_branch}"
        erun --show git -C "${section_dir}" -c "credential.helper=cache" fetch -f origin "${section_branch}" || die 'Unable to fetch git repository'

        # post-fetch
        if [ x"${section_clean}" = x"1" ] || [ x"${newly_created_git_repo}" = x"1" ]; then
            edebug "update-section ${section_name}: post-fetch: checking out from origin/${section_branch}"
            erun git -C "${section_dir}" reset --hard "origin/${section_branch}"
            erun git -C "${section_dir}" checkout -f "${section_branch}"
        elif [ x$(git -C "${section_dir}" config branch.${section_current_branch}.rebase) = x"true" ]; then
            edebug "update-section ${section_name}: rebasing onto branch ${section_branch}"
            erun git -C "${section_dir}" rebase "${section_branch}"
        else
            edebug "update-section ${section_name}: merging with last head"
            erun git -C "${section_dir}" merge FETCH_HEAD
        fi

        unset GIT_SSH

    elif [ x"${section_type}" = x"archive" ]; then
        elog "fetching odoo extra modules"
        local extra_tmp=`mktemp`
        local extra_tmpdir=`mktemp -d`
        erun curl -s -f "${CONF_EXTRA_URL}" > "${extra_tmp}"
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
        doh_fetch_file "${section_patchset}" "${patchset_tmp}"
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
        (erunquiet curl -s -f  "${CONF_PROFILE_URL}" > "${tmp_profile}") || die 'Unable to update odoo profile'
        mv "${tmp_profile}" "${DIR_ROOT}/odoo.profile"
    fi
}

doh_sublime_project_template() {
    doh_profile_load

    PROJ_TMPL_FILE="${DIR_ROOT}/odoo.sublime-project"
    PROJ_PYTHON_VERSION="2.7"
    cat >"${PROJ_TMPL_FILE}" <<EOF
{
    "SublimeLinter": {
        "@python": ${PROJ_PYTHON_VERSION}
    },
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

    local v="${CONF_PROFILE_VERSION:-8.0}"

    if [ x"$CONF_RUNTIME_DOCKER" != x"0" ]; then
        doh_run_server_docker "$@"
        return
    fi

    if [ ! -e "${DIR_CONF}/odoo-server.conf" ]; then
        die "odoo server configuration file is missing, please re-run 'doh reconfigure'"
    fi

    local start=""
    if [ x"${USER}" != x"${CONF_PROFILE_RUNAS}" ]; then
	start="sudo -u ${CONF_PROFILE_RUNAS}"
    fi

    if [[ x"${v}" =~ ^x(10.0|9.0|8.0|7.0|master)$ ]]; then
        edebug "Starting server using: ${start} ${DIR_MAIN}/${CONF_SERVER_CMDDEV} -c ${DIR_CONF}/odoo-server.conf $@"
        ${start} "${DIR_MAIN}/${CONF_SERVER_CMDDEV}" -c "${DIR_CONF}/odoo-server.conf" "$@"
    elif [[ x"${v}" =~ ^x(6.1|6.0)$ ]]; then
        edebug "Starting server using: ${start} ${DIR_MAIN}/bin/openerp-server.py -c ${DIR_CONF}/odoo-server.conf $@"
        ${start} "${DIR_MAIN}/bin/openerp-server.py" -c "${DIR_CONF}/odoo-server.conf" "$@"
    else
        die "No known way to start server for version ${v}"
    fi
}

docker_network_create() {
    docker network inspect ${1} >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        elog "Creating docker network: ${1}"
        docker network create ${1}
    fi
}

docker_volume_create() {
    docker volume inspect ${1} >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        elog "Creating docker volume: ${1}"
        docker volume create --name=${1}
    fi
}

docker_container_exist() {
    docker ps -a --format '{{.Names}}' | grep "^${1}$" >/dev/null
    return $?
}

doh_run_server_docker() {
    doh_profile_load
    doh_check_dirs

    CONF_RUNTIME_DOCKER_RAW_ARGS="0"
    if [ x"$1" = x"--raw" ]; then
        CONF_RUNTIME_DOCKER_RAW_ARGS="1";
        DOH_DOCKER_NO_OPTS="1"
        shift;
    fi

    local v="${CONF_PROFILE_VERSION:-8.0}"
    if ! [[ x"${v}" =~  ^x(10.0|9.0|8.0|7.0|master) ]]; then
        die "Docker runtime only supportted work for odoo 8.0 and later"
    fi

    local docker_image="odoo:${v}"
    if [ -f ${DIR_EXTRA}/Dockerfile ]; then
        docker_image="$(basename `readlink -f ${DIR_ROOT}`):latest"
    fi
    if [ x"${CONF_RUNTIME_DOCKER_IMAGE}" != x"" ]; then
        docker_image=${CONF_RUNTIME_DOCKER_IMAGE}
    fi

    if ! [[ x"$docker_image" =~ ^xodoo: ]]; then
        docker_image_id=$(\
                docker images --format "{{.ID}} {{.Repository}}:{{.Tag}}" \
                | grep "${docker_image}" \
                | awk '{print $1}')
        if [ x"${docker_image_id}" = x"" ]; then
            die "Unable to find image '${docker_image}', please pull or build it manually."
        fi
    fi

    local docker_args="${DOH_DOCKER_VOLUMES}"
    if [ -f "${DIR_CONF}/odoo-server.conf" ]; then
        docker_args="${docker_args} -v $(readlink -f ${DIR_CONF}/odoo-server.conf):/etc/odoo/${CONF_SERVER_RCFILE}:ro"
    fi
    if [ x"$v" = x"7.0" ]; then
        docker_args="${docker_args} -e OE_SESSIONS_PATH=/var/lib/openerp"
    fi

    local odoo_args=${odoo_args:-}
    local odoo_subcommand=""
    odoo_args="${odoo_args} --addons-path=${DOH_DOCKER_VOLUMES_PATH}"
    if [[ x"${v}" =~ ^x(8.0) ]]; then
        # Odoo 8.0 does not support passing database args as environment
        # variable, force it args arguments
        odoo_args="${odoo_args} --db_host=${CONF_RUNTIME_DOCKER_PGHOST}"
        odoo_args="${odoo_args} --db_user=${CONF_RUNTIME_DOCKER_PGUSER}"
        odoo_args="${odoo_args} --db_password=${CONF_RUNTIME_DOCKER_PGPASSWD}"
    fi
    if [ x"${DOH_DOCKER_NO_OPTS}" = x"1" ]; then
        # do not provide automatic config option to odoo
        # (this is used for scafolding)
        odoo_args=""
    fi
    local arg;
    local opt_xmlrpc_port="";
    for arg in "$@"; do
        if [ x"${opt_xmlrpc_port}" = x"+" ]; then
            opt_xmlrpc_port="$arg"; break
        fi
        if [[ x"${arg}" =~ ^x--xmlrpc-port= ]]; then
            opt_xmlrpc_port="${arg#*=}"
        elif [ x"${arg}" = x"--xmlrpc-port" ]; then
            opt_xmlrpc_port="+"
        elif [ x"${arg}" = x"--no-xmlrpc" ]; then
            opt_xmlrpc_port=""
            DOH_DOCKER_NO_PUBLISH=1
        fi
    done
    if [ $((${opt_xmlrpc_port} + 0)) -eq 0 ]; then
        if [ -f "${DIR_CONF}/odoo-server.conf" ]; then
            opt_xmlrpc_port=$(conf_file_get "${DIR_CONF}/odoo-server.conf" options.xmlrpc_port)
        fi
        opt_xmlrpc_port=${opt_xmlrpc_port:-8069}
    fi
    if [ x"${DOH_DOCKER_NO_PUBLISH}" != x"1" ]; then
        docker_args="${docker_args} -p 0.0.0.0:${opt_xmlrpc_port}:${opt_xmlrpc_port}"
        if (echo "$@" | grep -- "--workers=" -); then
            docker_args="${docker_args} -p 0.0.0.0:8072:8072"
        fi
    fi
    docker_args="${docker_args} ${DOH_DOCKER_EXTRA_ARGS}"

    local datavolume_ctpath="/var/lib/odoo"
    if [ x"$v" = x"7.0" ]; then
        datavolume_ctpath="/var/lib/openerp"
    fi

    local docker_interactive="-it"
    if [ ! -t 0 ]; then
        edebug "Running in no TTY-mode"
        docker_interactive="-i"
    fi

    if [ x"$1" = x"--" ]; then
        if [ x"$2" = x"shell" ]; then
            odoo_subcommand="-- shell"
            shift 2;
        fi
    fi

    docker_network_create "${CONF_RUNTIME_DOCKER_NETWORK}"
    docker_volume_create "${CONF_RUNTIME_DOCKER_DATAVOLUME}"
    erun --show docker run --rm ${docker_interactive} \
        --net=${CONF_RUNTIME_DOCKER_NETWORK} \
        -e PGHOST=${CONF_RUNTIME_DOCKER_PGHOST} \
        -e PGUSER=${CONF_RUNTIME_DOCKER_PGUSER} \
        -e PGPASSWORD=${CONF_RUNTIME_DOCKER_PGPASSWD} \
        -v ${CONF_RUNTIME_DOCKER_DATAVOLUME}:${datavolume_ctpath} \
        ${docker_args} \
        -v $(readlink -f ${DIR_MAIN})/${CONF_SERVER_PKGDIR}:/usr/lib/python2.7/dist-packages/${CONF_SERVER_PKGDIR}:ro \
        ${docker_image} \
        ${odoo_subcommand} \
        ${odoo_args} \
        "$@"

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
    if [ ! -f "${PIDFILE}" ]; then
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
Usage: doh [OPTIONS] COMMAND [COMMANDS OPTS...]

Availables options

  --self-upgrade    self-update doh to latest version
  --version         display doh version

Available commands

  install       install and setup a new odoo instance
  update        update odoo and extra modules code
  reconfigure   check and regenerate server/db configuration

  help          show this help message
  config        get and set odoo profile options

Database commands

  sql           open a console to the server (psql like)
  create-db     create a new database using current profile
  drop-db       drop an existing database
  copy-db       duplicate an existing database
  restore-db    restore a database from a backup dump (custom format)
  upgrade-db    upgrade a specific database

Development commands:

  run           run odoo server in foreground
  coverage      run odoo server in coverage mode
  scaffold      create a new module based on a template
  shell         get an odoo shell prompt

Service commands

  start         start odoo service
  stop          stop odoo service

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
doh config [--global] [name [value] | -u name | -l]

Get and set odoo profile options

options:

-l            list all profile variables
-u            unset the following config option
HELP_CMD_CONFIG
    local listall="0"
    local varunset="0"
    local user_global_file="0"

    if [ x"$1" == x"--global" ]; then
        user_global_file="1"
        shift;
    fi

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

    if [ x"${user_global_file}" = x"1" ]; then
        local conffile="${DOH_USER_GLOBAL_CONFIG}"
        if [ ! -e "${DOH_USER_GLOBAL_CONFIG}" ]; then
            local user_config_dir=$(dirname "${DOH_USER_GLOBAL_CONFIG}")
            mkdir -p "${user_config_dir}"
            touch "${DOH_USER_GLOBAL_CONFIG}"
        fi
    else
        local conffile=$(doh_profile_find)
    fi

    if [ x"${listall}" = x"1" ]; then
        local SECTIONS=$(conf_file_get_sections "${conffile}")
        local OLDIFS="${IFS}"
        local opt_name=""
        local opt_value=""

        for section in ${SECTIONS}; do
            VARS=$(conf_file_get_options "${conffile}" "${section}")
            IFS=$'\n'; while read -r var; do
                [ x"${var}" = x"" ] && continue
                opt_name="${var%%=*}"
                opt_value="${var#*=}"
                echo "${section}.${opt_name}=${opt_value}"
            done <<< "${VARS}"
            IFS="$OLDIFS"
        done
    elif [ x"${varunset}" = x"1" ]; then
        conf_file_unset "${conffile}" "$1"
    elif [ $# -ge 2 ]; then
        conf_file_set "${conffile}" "$1" "$2"
    else
        echo $(conf_file_get "${conffile}" "$1")
    fi
}

cmd_scaffold() {
: <<HELP_CMD_SCAFFOLD
doh scaffold [-h] [-t TEMPLATE] name [dest]

Generates an Odoo module skeleton.

HELP_CMD_SCAFFOLD
    local conffile=$(doh_profile_find)
    doh_profile_load "${conffile}"

    # set stdout/stderr to terminal pty
    if [ x"${DOH_LOGFILE}" != x"" ]; then
        exec 1>&6 6>&-
        exec 2>&7 7>&-
    fi

    DOH_DOCKER_NO_PUBLISH=1 DOH_DOCKER_NO_OPTS=1 \
        doh_run_server -- scaffold "$@"
}

cmd_shell() {
: <<HELP_CMD_SHELL
doh shell

Get an Odoo shell promt.

HELP_CMD_SHELL
    local conffile=$(doh_profile_find)
    doh_profile_load "${conffile}"

    # set stdout/stderr to terminal pty
    if [ x"${DOH_LOGFILE}" != x"" ]; then
        exec 1>&6 6>&-
        exec 2>&7 7>&-
    fi

    DOH_DOCKER_NO_PUBLISH=1 \
        doh_run_server -- shell "$@"
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
#runas=
#deploy_key=

[main]
repo=${n_main_repo}
branch=${n_main_branch}
patchset=

# [extra]
# repo=
# url=
# patchset=

# [db]
# host=
# port=
# user=
# pass=
# init_modules_on_create=base
# init_extra_args=
#
# [server]
# xmlrpc_port=

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
    local local_database
    local autostart
    OPTIND=1
    while getopts "dat:p:" opt; do
        case $opt in
            d)
                # Install and use local database
                local_database=true
                ;;
            a)
                # Autostart profile on boot
                autostart=true
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

    # force local database setup in profile db.host is empty
    if db_get_server_is_local; then
        local_database=true
    fi

    doh_reconfigure "pre"

    elog "fetching odoo from remote git repository (this can take some time...)"
    for part in $DOH_PARTS; do
        doh_update_section -c "${part}"
    done

    if [ x"$local_database" = x"true" ]; then
        elog "installing postgresql server (sudo)"
        dpkg_check_packages_installed "postgresql"
        erunquiet sudo service postgresql start || die 'PostgreSQL server doesnt seems to be running'
    fi

    doh_reconfigure "post"

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

    ewarn "command 'upgrade' is deprecated"
    ewarn "please use command 'update', then followed by command 'upgrade-db'"

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

cmd_update() {
: <<HELP_CMD_UPDATE
doh update [--clean] [section1 ...]

options:
  --clean            cleanup section directory (erase local changes)
HELP_CMD_UPDATE

    section_clean=""
    if [ x"$1" = x"--clean" ]; then
        section_clean="-c"
        shift;
    fi

    doh_profile_load
    doh_profile_update
    doh_check_dirs

    local section_to_update="${DOH_PARTS}"
    if [ $# -gt 0 ]; then
        section_to_update=""
        for section_name in "$@"; do
            for part in ${DOH_PARTS}; do
                if [ x"${section_name}" = x"${part}" ]; then
                    section_to_update="${section_to_update} $section_name"
                fi
            done
        done
    fi

    for part in $section_to_update; do
        doh_update_section "${part}"
    done
}

cmd_reconfigure() {
: <<HELP_CMD_RECONFIGURE
doh reconfigure
HELP_CMD_RECONFIGURE

    doh_profile_load
    doh_reconfigure
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
    erunquiet ${createdb} -E unicode "${DB}" || die "Unable to create database ${DB}"
    elog "initializing database ${DB} for odoo"
    erun --show doh_run_server -d "${DB}" --stop-after-init -i "${CONF_DB_INIT_MODULES_ON_CREATE:-base}" ${CONF_DB_INIT_EXTRA_ARGS} || die "Failed to initialize database ${DB}"
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

    doh_profile_load --user-profile-only
    if [ x"${CONF_RUNTIME_DOCKER}" != x"0" ]; then
        export DOH_PROFILE_LOADED="1"
    else
        # Load infos from profile if not running in docker context
        doh_profile_load
        db_client_setup_env
        doh_svc_stop
    fi

    local dropdb=$(db_get_server_local_cmd "dropdb")
    local psql=$(db_get_server_local_cmd "psql")

    for DB in $@; do
        DB_COUNT=$(erun --show ${psql} "postgres" -A --tuples-only -c "SELECT 1 FROM pg_database WHERE datname = '${DB}'" | wc -l)
        if [ ${DB_COUNT} -gt 0 ]; then
            elog "droping database ${DB}"
            erunquiet ${dropdb} "${DB}" || die "Unable to drop database ${DB}"
        fi
    done
}

cmd_copy_db() {
: <<HELP_CMD_COPY_DB
doh copy-db TEMPLATE_NAME NAME

HELP_CMD_COPY_DB
    if [ $# -lt 2 ]; then
        echo "Usage: doh copy-db: missing arguments -- TEMPLATE_NAME NAME"
        cmd_help "copy_db"
    fi
    local create_db=$(db_get_server_local_cmd "createdb")
    TMPL_DB="$1"
    DB="$2"

    doh_profile_load
    db_client_setup_env
    doh_svc_stop
    elog "copying database ${TMPL_DB} to ${DB}"
    erunquiet ${create_db} "${DB}" -T "${TMPL_DB}" || die "Unable to copy database ${TMPL_DB} to ${DB}"
}

cmd_sql() {
: <<HELP_CMD_SQL
doh sql ARG...

HELP_CMD_SQL
    doh_profile_load --user-profile-only
    if [ x"${CONF_RUNTIME_DOCKER}" != x"0" ]; then
        export DOH_PROFILE_LOADED="1"
        if [ ! -t 0 ] || [ ! -t 1 ]; then
            export DOH_DOCKER_NO_TTY=1
        fi
    else
        # Load infos from profile if not running in docker context
        doh_profile_load
        db_client_setup_env
    fi

    local psql=$(db_get_server_local_cmd "psql")
    erun --show ${psql} "$@"
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


cmd_restore_db() {
: <<HELP_CMD_RESTORE_DB
doh restore-db DB_NAME DB_FILE

HELP_CMD_RESTORE_DB

    local db_name="$1"
    local db_file="$2"
    local db_restore_file="$2"

    doh_profile_load
    db_client_setup_env
    [ -f "${db_file}" ] || die "File ${db_file} does not exist."

    local drop_db=$(db_get_server_local_cmd "dropdb")
    local create_db=$(db_get_server_local_cmd "createdb")
    local restore_db=$(db_get_server_local_cmd "pg_restore")
    if [ x"${CONF_RUNTIME_DOCKER}" != x"0" ]; then
        db_file_abspath=$(readlink -f ${db_file})
        restore_db=$(DOH_DOCKER_CMD_EXTRA="-v ${db_file_abspath}:/tmp/database.dump" \
                     db_get_server_local_cmd "pg_restore")
        db_restore_file="/tmp/database.dump"
    fi

    elog "dropping database ${db_name}"
    erunquiet ${drop_db} --if-exists "${db_name}"

    elog "creating database ${db_name}"
    erunquiet ${create_db} "${db_name}" -T template0

    elog "restoring database ${db_name} from ${db_file}"
    erun --show ${restore_db} -Ox -j2 -d "${db_name}" "${db_restore_file}"
}


cmd_client() {
: <<HELP_CMD_CLIENT
doh client

HELP_CMD_CLIENT

    doh_profile_load
    doh_run_client_gtk "$@"
}

cmd_coverage() {
: <<HELP_CMD_COVERAGE
doh coverage DATABASE [all|module,...]

Run server with coverage (information are collected under directory "run/coverage")

HELP_CMD_COVERAGE

    doh_profile_load
    # dpkg_check_packages_installed "python-coverage"
    local run_in_foreground="0"
    if [ x"$1" = x"-f" ]; then
        run_in_foreground="1"
        shift;
    fi

    local COVERAGE_ARGS=""
    local DB="$1"
    local MODS="$2"
    local MODS_REGEXP=""
    local mpath=""

    if [ x"${MODS}" = x"" ]; then
        MODS=${CONF_COVERAGE_MODULES:-all}
        elog "No modules specified, using config default: ${MODS}"
    fi

    if [ x"$CONF_RUNTIME_DOCKER" != x"0" ]; then
        local docker_image="odoo:${v}"
        if [ -f ${DIR_EXTRA}/Dockerfile ]; then
            docker_image="$(basename `readlink -f ${DIR_ROOT}`):latest"
        fi
        if [ x"${CONF_RUNTIME_DOCKER_IMAGE}" != x"" ]; then
            docker_image=${CONF_RUNTIME_DOCKER_IMAGE}
        fi

        local docker_coverage_image="$(basename `readlink -f ${DIR_ROOT}`):coverage"
        if [ `docker image ls --format='{{.Repository}}:{{.Tag}}' | grep "${docker_coverage_image}:coverage" | wc -l` -lt 1 ]; then
            ewarn "Building docker image for coverage: ${docker_coverage_image}:coverage"
        fi
        docker build -t "${docker_coverage_image}" - 2>/dev/null <<EOF
FROM ${docker_image}
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc python-dev bzip2 \
    && easy_install coverage \
    && apt-get purge -y gcc python-dev \
    && apt-get autoremove -y
RUN set -x; \
    curl -sSL -o phantomjs.tar.bz2 https://bitbucket.org/ariya/phantomjs/downloads/phantomjs-2.1.1-linux-x86_64.tar.bz2 \
    && echo 'f8afc8a24eec34c2badccc93812879a3d6f2caf3 phantomjs.tar.bz2' | sha1sum -c - \
    && tar xjf phantomjs.tar.bz2 \
    && mv ./phantomjs-2.1.1-linux-x86_64/bin/phantomjs /usr/local/bin \
    && rm -Rf phantomjs.tar.bz2 ./phantomjs-2.1.1-linux-x86_64
USER odoo
EOF
    fi
    COVERAGE_ARGS="--branch"
    COVERAGE_REPORT_ARGS=""
    if [ x"${MODS}" != x"all" ]; then
        OLDIFS="${IFS}";
        IFS=","; for m in ${MODS}; do
            mpath=""
            for a in $DOH_ADDONS_PATH; do
                if [ -d "${a}/${m}" ]; then
                    mpath="${a}/${m}"
                    if [ "${CONF_RUNTIME_DOCKER}" != x"0" ]; then
                        mpath="/mnt/$(basename ${a,,})/${m}"
                    fi
                    break
                fi
            done
            if [ x"${mpath}" = x"" ]; then
                die "Unable to find location of module: $m"
            fi

            if [ x"${MODS_REGEXP}" != x"" ]; then
                MODS_REGEXP="${MODS_REGEXP},"
            fi
            MODS_REGEXP="${MODS_REGEXP}${mpath}/*"
        done
        IFS="${OLDIFS}"
        COVERAGE_REPORT_ARGS="${COVERAGE_REPORT_ARGS} --include=${MODS_REGEXP} --omit=*/migrations/*,*/__openerp__.py,*/__manifest__.py" #--omit=*/__init__.py,*/__openerp__.py,*/__manifest__.py,*/tests/*.py"
    fi

    # rm -Rf "${DIR_ROOT}/coverage"
    mkdir -p "${DIR_ROOT}/coverage"
    if [ "${CONF_RUNTIME_DOCKER}" != x"0" ]; then
        chmod o+rwx,g+ws "${DIR_ROOT}/coverage"
    fi
    local logfile="${DIR_ROOT}/coverage/odoo.log"
    local COVERAGE_FILE="${DIR_ROOT}/coverage/run.coverage"

    local v="${CONF_PROFILE_VERSION:-8.0}"
    if [[ x"${v}" =~ ^x(10.0|9.0|8.0|7.0|master)$ ]]; then
        edebug "Coverage server using: ${start} ${DIR_MAIN}/${CONF_SERVER_CMDDEV} -c ${DIR_CONF}/odoo-server.conf $@"
        if [ x"${DOH_LOGFILE}" != x"" ]; then
            if [ x"${run_in_foreground}" = x"1" ]; then
                exec 1>&6 6>&-
                exec 2>&7 7>&-
            else
                exec > >(tee "${logfile}")
                exec 2> >(tee "${logfile}" >&2)
            fi
        fi
        local SOURCES="${DOH_ADDONS_PATH}"
        if [ "${CONF_RUNTIME_DOCKER}" != x"0" ]; then
            SOURCES="${DOH_DOCKER_VOLUMES_PATH}"
            COVERAGE_FILE="/mnt/coverage/run.coverage"
            COVERAGE_CMD="coverage run"
            ODOO_SERVER_CMD="/usr/bin/${CONF_SERVER_CMD}"
            DOCKER_COVERAGE_ARGS="${COVERAGE_ARGS}"
            CONF_RUNTIME_DOCKER_IMAGE="${docker_coverage_image}" \
            DOH_DOCKER_VOLUMES="${DOH_DOCKER_VOLUMES} -v $(readlink -e ${DIR_ROOT})/coverage:/mnt/coverage -e COVERAGE_FILE=${COVERAGE_FILE}" \
            DOH_DOCKER_NO_PUBLISH="1"
            odoo_args="${COVERAGE_CMD} --source=${SOURCES} ${DOCKER_COVERAGE_ARGS} ${ODOO_SERVER_CMD}" \
                doh_run_server_docker \
                    --test-enable --log-level=test --stop-after-init \
                    -d "${DB}" -i "${MODS}"
            # echo coverage run --branch --source="${SOURCES}" \
            #     "${DIR_MAIN}/openerp-server" -c "${DIR_CONF}/odoo-server.conf" \
            #         --test-enable --log-level test --stop-after-init \
            #         -d "${DB}" -u "${MODS}"
        else
            echo coverage run --branch --source="${SOURCES}" \
                "${DIR_MAIN}/${CONF_SERVER_CMDDEV}" -c "${DIR_CONF}/odoo-server.conf" \
                    --test-enable --log-level test --stop-after-init \
                    -d "${DB}" -u "${MODS}"
        fi
        # restore initial config
        if [ x"${DOH_LOGFILE}" != x"" ]; then
            exec > >(tee -a "${DOH_LOGFILE}")
            exec 2> >(tee -a "${DOH_LOGFILE}" >&2)
        fi
    elif [[ x"${v}" =~ ^x(6.1|6.0)$ ]]; then
        die "Coverage is not active for 6.x odoo releases"
        # edebug "Coverage server using: ${start} ${DIR_MAIN}/bin/openerp-server.py -c ${DIR_CONF}/odoo-server.conf $@"
        # ${start} "${DIR_MAIN}/bin/openerp-server.py" -c "${DIR_CONF}/odoo-server.conf" "$@"
    else
        die "No known way to start server for version ${v}"
    fi

    if [ x"${run_in_foreground}" = x"1" ]; then
        elog "Not generating html report, coverage was run in foreground and thus not logfile available"
    else
        elog "Generating html report"
        if [ x"${DOH_LOGFILE}" != x"" ]; then
            exec 1>&6 6>&-
            exec 2>&7 7>&-
        fi
        if [ "${CONF_RUNTIME_DOCKER}" != x"0" ]; then
            COVERAGE_FILE="/mnt/coverage/run.coverage"
            local docker_interactive="-it"
            if [ ! -t 0 ]; then
                edebug "Running in non TTY-mode"
                docker_interactive="-i"
            fi
            erun --show docker run --rm ${docker_interactive} \
                ${DOH_DOCKER_VOLUMES} \
                -v "$(readlink -e ${DIR_ROOT})/coverage:/mnt/coverage" \
                -e COVERAGE_FILE=${COVERAGE_FILE} \
                ${docker_coverage_image} \
                coverage html ${COVERAGE_REPORT_ARGS} \
                    -d "/mnt/coverage/html"
        else
            coverage html ${COVERAGE_REPORT} -d "${DIR_RUN}/coverage"
        fi

        if [ -f ${DIR_RUN}/coverage/odoo.log ]; then
            grep -P "^(?:\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d{3} \d+ (?:ERROR|CRITICAL) )|(?:Traceback \(most recent call last\):)$" ${DIR_RUN}/coverage/odoo.log>/dev/null
            if [ $? -eq 0 ]; then
                elog "Some errors occurreds, see below"
                grep -P "^(?:\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d{3} \d+ (?:ERROR|CRITICAL) )|(?:Traceback \(most recent call last\):)$" ${DIR_RUN}/coverage/odoo.log
            fi
        fi
    fi
    # exec 1>&6 6>&-
    # exec 2>&7 7>&-
    # doh_run_server -d "$1" -u "$2"

}

cmd_run() {
: <<HELP_CMD_RUN
doh run [ODOO OPTION...]

Run odoo server in foreground with choosen options.

HELP_CMD_RUN
    doh_profile_load

    # set stdout/stderr to terminal pty
    if [ x"${DOH_LOGFILE}" != x"" ]; then
        exec 1>&6 6>&-
        exec 2>&7 7>&-
    fi
    doh_run_server "$@"
}

cmd_start() {
: <<HELP_CMD_START
doh start [-f] [ODOO OPTION...]

options:

 -f   start server in foreground (deprecated)
HELP_CMD_START

    if [ x"$1" = x"-f" ]; then
        ewarn "command 'start -f' is deprecated, please use 'run' command instead!"
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
if [ $? -ne 0 ] && [ x"${GIT_INTERNAL_GETTEXT_SH_SCHEME}" != x"" ]; then
    # reading exe link might fail when running in container, fallback to env identification
    ppid_exe=$(which git)
fi
ppid_name=$(basename "${ppid_exe}")
if [ x"${GIT_SSH}" = x"$0" ] && [ x"${ppid_name}" = x"git" ]; then
    doh_git_ssh_handler "$@";
    exit 0;
fi

if [ x"${USER}" = x"" ]; then
    # no user defined in env
    USER=$(getent passwd $UID | cut -d: -f1)
fi

# stage 0 dependencies
doh_check_stage0_depends


CMD="$1"; shift;
case $CMD in
    internal-self-upgrade|--self-upgrade|--install)
        doh_path="$0"
        if [ x"${CMD}" = x"--install" ] || [ x"${0}" = x"bash" ]; then
            doh_path="/usr/local/bin/doh"
        fi

        if [ -e "${doh_path}" ] && [ -t 0 ]; then
            # ask user about upgrading
            while true; do
                read -p "update doh (at ${doh_path}) with new version? [y/n] " yn;
                case $yn in
                    [yY]* ) break;;
                    [nN]* ) exit 2;;
                    * ) echo "please choose Y or N";;
                esac
            done
        fi

        tmp_doh=`mktemp`
        doh_branch="${1:-master}"
        (curl -s -f "https://raw.githubusercontent.com/xavieralt/doh/${doh_branch}/doh" >  "${tmp_doh}") || die 'Unable to fetch remote doh'
        (cat "${tmp_doh}" | sudo tee "${doh_path}" >/dev/null) || die 'Unable to update doh'
        sudo chmod 755 "${doh_path}"  # ensure script is executable

        # check bootstrap depends might fail, testing that as end
        doh_check_bootstrap_depends
        exit 0
        ;;
    --version)
        echo "doh v${DOH_VERSION}"
        ;;
    *)
        doh_setup_logging
        doh_check_bootstrap_depends
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
