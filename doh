#!/bin/bash

DOH_VERSION="0.1"

# Setup output logging
DOH_LOGFILE=/tmp/doh.log
DOH_LOGLEVEL="${DOH_LOGLEVEL:-info}"
DOH_PROFILE_LOADED="0"

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
    "$@" 2>>${DOH_LOGFILE} | tee -a ${DOH_LOGFILE}
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
conf_get() {
    # $1: key, $2: default value
    r=$(key="${1^^}"; confkey="CONF_${key//./_}"; echo -n "${!confkey:-${2}}")
    echo -n "${r}"
    if [ x"${r}" = x"" ]; then
        return $FALSE
    else
        return $TRUE
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

install_odoo_depends() {
    DEPENDS=$(sed -ne '/^Depends:/, /^[^ ]/{/^Depends:/{n;n};/^[^ ]/{q;};s/,$//;p;}' \
        "$1/debian/control")
    erunquiet sudo apt-get -y --no-install-recommends install ${DEPENDS}
}

install_postgresql_server() {
    erunquiet sudo apt-get -y --no-install-recommends install postgresql
}

db_client_setup_env() {
    if [ x"$DB_HOST" != x"" ]; then
        if [ x"$DB_USER" = x"" ]; then
            die "Config parameter DB_USER is mandatory when using DB_HOST"
        fi
        if [ x"$DB_PASS" = x"" ]; then
            die "Config parameter DB_PASS is mandatory when using DB_HOST"
        fi
    fi
    for v in HOST PORT USER PASS; do
        db_var="DB_${v}"
        pg_var="PG${v}"
        if [ x"${!db_var}" != x"" ]; then
            export $pg_var=${!db_var}
        fi
    done
}

db_config_local_server() {
    db_client_setup_env

    ROLES=$(erun sudo -u postgres psql -Atc "SELECT rolname FROM pg_roles WHERE rolname = '$USER'" postgres)
    ROLES_COUNT=$(echo $ROLES | sed '/^$/d' | wc -l)
    if [ $ROLES_COUNT -eq 0 ]; then
        elog "Creating PostgreSQL role for user $USER"

        CREATE_USER_ARGS="NOSUPERUSER CREATEDB NOCREATEROLE INHERIT LOGIN;"
        if [ x"$DB_PASS" != x"" ]; then
            CREATE_USER_ARGS="ENCRYPTED PASSWORD '${DB_PASS}' $CREATE_USER_ARGS"
        fi
        erunquiet sudo -u postgres psql -Atc "CREATE ROLE $USER $CREATE_USER_ARGS" || die 'Unable to create database user'
    fi
}

doh_config_init() {
    doh_profile_load


    ODOO_ADDONS_PATH="${DIR_ADDONS},${DIR_EXTRA}"
    ODOO_CONF_FILE="${DIR_CONF}/odoo-server.conf"
    ODOO_LOG_FILE="${DIR_LOGS}/odoo-server.log"
    RUNAS="$USER"

    TMPL_INIT_FILE="${DIR_MAIN}/debian/init"
    if [ x"${CONF_PROFILE_VERSION:-8.0}" = x"6.0" ]; then
        TMPL_INIT_FILE="${DIR_MAIN}/debian/openerp-server.init"
    fi


    elog "Generating Odoo init script"
    sed \
        -e "s#^DAEMON=.*\$#DAEMON=${DIR_MAIN}/openerp-server#" \
        -e "s/^\\(NAME\\|DESC\\)=.*\$/\\1=${CONF_PROFILE_NAME}/" \
        -e "s#^CONFIG=.*\$#CONFIG=${ODOO_CONF_FILE}#" \
        -e "s#^LOGFILE=.*\$#LOGFILE=${ODOO_LOG_FILE}#" \
        -e "s/^USER=.*\$/USER=${RUNAS}/" \
        -e "s#--pidfile /var/run/#--pidfile ${DIR_RUN}/#" \
        ${TMPL_INIT_FILE} | erunquiet sudo tee "/etc/init.d/odoo-${CONF_PROFILE_NAME}"
    erunquiet sudo chmod 755 "/etc/init.d/odoo-${CONF_PROFILE_NAME}"

    elog "Generating Odoo config file"
    cat <<EOF | erunquiet tee "${ODOO_CONF_FILE}"
[addons]
[options]
; This is the password that allows database operations:
; admin_passwd = admin
db_host = ${DB_HOST:-False}
db_port = ${DB_PORT:-False}
db_user = ${DB_USER}
db_password = ${DB_PASS:-False}
addons_path = ${ODOO_ADDONS_PATH}
EOF
    elog "Fixing permissions for Odoo config file"
    erunquiet sudo chmod 640 "${ODOO_CONF_FILE}"
    erunquiet sudo chown "${RUNAS}:adm" "${ODOO_CONF_FILE}"


    elog "Fixing permissions for Odoo log file"
    erunquiet sudo mkdir -p $(dirname "${ODOO_LOG_FILE}")
    erunquiet sudo touch "${ODOO_LOG_FILE}"
    erunquiet sudo chmod 640 "${ODOO_LOG_FILE}"
    erunquiet sudo chown "${RUNAS}:adm" "${ODOO_LOG_FILE}"

    if [ x"${CONF_PROFILE_AUTOSTART}" = x"1" ]; then
        elog "Adding Odoo '${CONF_PROFILE_NAME}' to autostart"
        erunquiet sudo update-rc.d "odoo-${CONF_PROFILE_NAME}" defaults
    fi
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
    export DIR_CONF="${PWD}/conf"
    export DIR_LOGS="${PWD}/logs"
    export DIR_RUN="${PWD}/run"

    local profile="${1:-odoo.profile}"
    if [[ "${profile}" =~ ^(http|ftp)[s]?://.* ]]; then
        elog "loading remote profile from: ${profile}"
        # wget + load file
        rm -f /tmp/odoo.profile
        wget -q -O "${DIR_ROOT}/odoo.profile" "${profile}" || die 'Unable to fetch remote profile'
        profile="${DIR_ROOT}/odoo.profile"
    elif [ -f "${profile}" ]; then
        if [ ! "${profile}" -ef "${DIR_ROOT}/odoo.profile" ]; then
            cp "${profile}" "${DIR_ROOT}/odoo.profile"
        fi
        elog "loading local profile file: ${profile}"
    else
        die "unable to load profile: ${profile}"
    fi
    OLDIFS="${IFS}"
    SECTIONS=$(sed -n '/^\[\(.*\)\]/{s/\[//;s/\]//;p}' "${DIR_ROOT}/odoo.profile")
    for section in ${SECTIONS}; do
        export CONF_${section^^}="1"  # mark section as present
        VARS=$(sed -n "/\[${section}]/,/^\[/{/^\[/d;/^$/d;/^#/d;p}" "${profile}")
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
        export DIR_ADDONS="${ADDONS_PATH}"
    fi

    DOH_PROFILE_LOADED="1"
}

doh_check_dirs() {
    # check if required dirs exists
    doh_profile_load

    for dir in DIR_ROOT DIR_MAIN DIR_ADDONS DIR_EXTRA DIR_LOGS DIR_RUN DIR_CONF; do
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

    ([ x"${1,,}" != x"main" ] && [ x"${1,,}" != x"addons" ] && [ x"${1,,}" != x"extra" ]) && die 'Invalid section ${section}'
    [ x"$(conf_get "${1}")" != x"1" ] && return  # section is not defined

    local section="${1^^}"
    local section_dir=$(d="DIR_${section^^}"; echo -n "${!d}")
    local section_repo_url=$(conf_get "${section}.repo")
    local section_type=$(conf_get "${section}.type" "git")
    local section_branch=$(conf_get "${section}.branch")
    local section_patchset=$(conf_get "${section}.patchset")
    local section_sparsecheckout=$(conf_get "${section}.sparse_checkout")

    if [[ x"${section_type}" = x"git" ]]; then

        [ x"${section_repo_url}" = x"" ] && die "No repository url specified for section ${1}"
        [ x"${section_branch}" = x"" ] && die "No branch specified for section ${1}"

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
        erun git -C "${section_dir}" pull -f origin "${section_branch}"
        erun git -C "${section_dir}" checkout -f "${section_branch}"

    elif [ x"${section_type}" = x"archive" ]; then
        elog "fetching odoo extra modules"
        local extra_tmp=`mktemp`
        local extra_tmpdir=`mktemp -d`
        erunquiet wget -q -O "${extra_tmp}" "${CONF_EXTRA_URL}"
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

    local v="${CONF_PROFILE_VERSION:-8.0}"
    if [ x"${v}" = x"8.0" ] || [ x"${v}" = "7.0" ]; then
        "${DIR_MAIN}/openerp-server" -c "${DIR_CONF}/odoo-server.conf" "$@"
    elif [ x"${v}" = "6.1" ] || [ x"${v}" = x"6.0" ]; then
        "${DIR_MAIN}/bin/openerp-server.py" -c "${DIR_CONF}/odoo-server.conf" "$@"
    else
        die "No known way to start server for version ${v}"
    fi
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
        elog "Starting service: odoo-${CONF_PROFILE_NAME}"
        erunquiet sudo service "odoo-${CONF_PROFILE_NAME}" start
    fi
}

doh_svc_stop() {
    if doh_svc_is_running; then
        elog "Stopping service: odoo-${CONF_PROFILE_NAME}"
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
Usage: doh CMD [OPTS...]

Available commands
  install    install and setup a new odoo instance
  upgrade    upgrade odoo and extra modules
  create-db  create a new database using current profile
  drop-db    drop an existing database
  upgrade-db upgrade a specific database
  start      start odoo service
  stop       stop odoo service
  help       show this help message

Use "odoo-helper help CMD" for detail about a specific command
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

[extra]
repo=
url=

[db]
host=
port=
user=
pass=
init_modules_on_create=base
init_extra_args=

TMPL_ODOO_PROFILE
}

cmd_install() {
: <<HELP_CMD_INSTALL
doh install [-d] [-a] [-p URL INSTALL_DIR]

options:

 -d                  install PostgreSQL database server
 -a                  automated startup, start on system boot
 -p URL INSTALL_DIR  load profile from a remote url
HELP_CMD_INSTALL

    local profdir=""
    local profname=""
    OPTIND=1
    while getopts "dap::" opt; do
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
                if [ $# -lt ${OPTIND} ]; then
                    echo "doh: missing parameter for option -- p"
                    cmd_help "install"
                fi
                profdir=${!OPTIND}
                profname="${OPTARG}"
                OPTIND=$(($OPTIND + 1))
                ;;
            \?)
                cmd_help "install"
                ;;
        esac
    done
    shift $(($OPTIND - 1))

    if [ x"$profdir" != x"" ]; then
        if [ ! -d "$profdir" ]; then
            mkdir -p "$profdir"
        fi
        cd "$profdir"
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
    doh_update_section "main"
    doh_update_section "addons"
    doh_update_section "extra"

    elog "installing odoo dependencies (sudo)"
    install_odoo_depends "${DIR_MAIN}"

    if [ x"$local_database" = x"true" ]; then
        elog "installing postgresql server (sudo)"
        install_postgresql_server
        erunquiet sudo service postgresql start || die 'PostgreSQL server doesnt seems to be running'
        db_config_local_server
    fi

    doh_config_init

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

    doh_update_section "main"
    doh_update_section "addons"
    doh_update_section "extra"

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
    DB="$1"

    doh_profile_load
    db_client_setup_env
    elog "creating database ${DB}"
    erunquiet createdb -E unicode "${DB}" || die "Unable to create database ${DB}"
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
    DB="$1"

    doh_profile_load
    db_client_setup_env
    doh_svc_stop
    elog "droping database ${DB}"
    erunquiet dropdb "${DB}" || die "Unable to drop database ${DB}"
}

cmd_copy_db() {
: <<HELP_CMD_COPY_DB
doh copy-db TEMPLATE_NAME NAME

HELP_CMD_COPY_DB
    if [ $# -lt 2 ]; then
        echo "Usage: doh copy-db: missing arguments -- TEMPLATE_NAME NAME"
        cmd_help "copy_db"
    fi
    TMPL_DB="$1"
    DB="$2"

    doh_profile_load
    db_client_setup_env
    doh_svc_stop
    elog "copying database ${TMPL_DB} to ${DB}"
    erunquiet psql postgres -c "CREATE DATABASE ${DB} ENCODING 'unicode' TEMPLATE ${TMPL_DB}" || die "Unable to copy database ${TMPL_DB} to ${DB}"
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


CMD="$1"; shift;
case $CMD in
    internal-self-upgrade)
        # TOOD: add self-upgrading function
        elog "Going to upgrade doh (path: $0) with remote version, press ENTER to continue or Ctrl-C to cancel"
        read ok
        tmp_doh=`mktemp`
        wget -q -O "${tmp_doh}" "https://raw.githubusercontent.com/xavieralt/doh/master/doh" || die 'Unable to fetch remote doh'
        (cat "${tmp_doh}" | sudo tee "$0" >/dev/null) || die 'Unable to update doh'
        sudo chmod 755 "$0"  # ensure script is executable
        exit 0
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
