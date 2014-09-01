#!/bin/bash

DOH_VERSION="0.1"

# Setup output logging
DOH_LOGFILE=/tmp/doh.log
DOH_LOGLEVEL="info"

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
    ODOO_ADDONS_PATH="${DIR_MAIN}/addons,${DIR_EXTRA}"
    ODOO_CONF_FILE="${DIR_CONF}/odoo-server.conf"
    ODOO_LOG_FILE="${DIR_LOGS}/odoo-server.log"
    RUNAS="$USER"

    elog "Generating Odoo init script"
    sed \
        -e "s#^DAEMON=.*\$#DAEMON=${DIR_MAIN}/openerp-server#" \
        -e "s/^\\(NAME\\|DESC\\)=.*\$/\\1=${PROFILE_NAME}/" \
        -e "s#^CONFIG=.*\$#CONFIG=${ODOO_CONF_FILE}#" \
        -e "s#^LOGFILE=.*\$#LOGFILE=${ODOO_LOG_FILE}#" \
        -e "s/^USER=.*\$/USER=${RUNAS}/" \
        -e "s#--pidfile /var/run/#--pidfile ${DIR_RUN}/#" \
        "${DIR_MAIN}/debian/openerp.init" | erunquiet sudo tee "/etc/init.d/odoo-${PROFILE_NAME}"
    erunquiet sudo chmod 755 "/etc/init.d/odoo-${PROFILE_NAME}"

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

    if [ x"${PROFILE_AUTOSTART}" != x"" ]; then
        elog "Adding Odoo '${PROFILE_NAME}' to autostart"
        erunquiet sudo update-rc.d "odoo-${PROFILE_NAME}" defaults
    fi
}

doh_profile_load() {
    # $1: odoo.profile
    export DIR_ROOT="${PWD}"
    export DIR_MAIN="${PWD}/main"
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
        VARS=$(sed -n "/\[${section}]/,/^\[/{/^\[/d;/^$/d;/^#/d;p}" "${profile}")
        IFS=$'\n'; while read -r var; do
            var_name="${var%%=*}"
            var_value="${var#*=}"
            export ${section^^}_${var_name^^}="${var_value}"
        done <<< "${VARS}"
        IFS="$OLDIFS"
    done
}

doh_profile_update() {
    if [ x"${PROFILE_URL}" != x"" ]; then
        elog "updating odoo profile"
        tmp_profile=`mktemp`
        erunquiet wget -q -O "${tmp_profile}" "$PROFILE_URL" || die 'Unable to update odoo profile'
        mv "${tmp_profile}" "${DIR_ROOT}/odoo.profile"
    fi
}

doh_upgrade_main() {
    elog "updating odoo source code"
    erunquiet git -C "${DIR_MAIN}" checkout .
    erunquiet git -C "${DIR_MAIN}" pull
    doh_patch_main
}

doh_patch_main() {
    if [ x"${PROFILE_PATCHSET}" != x"" ]; then
        elog "fetching odoo patch"
        local patchset_tmp=`mktemp`
        erunquiet wget -q -O "${patchset_tmp}" "${PROFILE_PATCHSET}"
        elog "apply odoo patch locally"
        erunquiet git -C "${DIR_MAIN}" apply "${patchset_tmp}"
        eremove "${patchset_tmp}"
    fi
}

doh_install_extra() {
    if [ x"${EXTRA_URL}" != x"" ]; then
        elog "fetching odoo extra modules"
        local extra_tmp=`mktemp`
        local extra_tmpdir=`mktemp -d`
        erunquiet wget -q -O "${extra_tmp}" "${EXTRA_URL}"
        elog "extracting odoo extra modules"
        erunquiet 7z x -y "-o${extra_tmpdir}" "${extra_tmp}"
        rm -Rf extra
        mkdir extra
        local module_parent_dirs=""
        for module_path in $(find "${extra_tmpdir}" -name __openerp__.py -exec dirname {} \;); do
            module_parent_path=$(dirname "${module_path}")
            module_parent_dirs="${module_parent_dir}\n${module_parent_path}"
            local module_name=$(basename "${module_path}")
            elog "extracting module -- ${module_name}"
            mv "${module_path}" "${DIR_EXTRA}"
        done
        module_parent_dir_unique=$(echo -e "${module_parent_dirs}" | sed '/^$/d' | sort -u | wc -l)
        if [ $module_parent_dir_unique -eq 1 ]; then
            module_parent_dir=$(echo -e "${module_parent_dirs}" | sed '/^$/d' | sort -u)
            if [ -d "${module_parent_dir}/.git" ]; then
                elog "extracting extra git repository"
                mv "${module_parent_dir}/.git" "${DIR_EXTRA}"
            fi
        fi
        eremove "${extra_tmp}"
        eremove "${extra_tmpdir}"
    fi
}

doh_run_server() {
    local v="${PROFILE_VERSION:-8.0}"
    if [ x"${v}" = x"8.0" ] || [ x"${v}" = "7.0" ]; then
        "${DIR_MAIN}/openerp-server" -c "${DIR_CONF}/odoo-server.conf" "$@"
    elif [ x"${v}" = "6.1" ] || [ x"${v}" = x"6.0" ]; then
        "${DIR_MAIN}/bin/openerp-server.py" -c "${DIR_CONF}/odoo-server.conf" "$@"
    else
        die "No known way to start server for version ${v}"
    fi
}

doh_svc_is_running() {
    PIDFILE="${DIR_RUN}/${PROFILE_NAME}.pid"
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
        elog "Starting service: odoo-${PROFILE_NAME}"
        erunquiet sudo service "odoo-${PROFILE_NAME}" start
    fi
}

doh_svc_stop() {
    if doh_svc_is_running; then
        elog "Stopping service: odoo-${PROFILE_NAME}"
        erunquiet sudo service "odoo-${PROFILE_NAME}" stop
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
        PROFILE_AUTOSTART=true
    fi

    # ensure all directories exists
    for dir in DIR_ROOT DIR_MAIN DIR_EXTRA DIR_LOGS DIR_RUN DIR_CONF; do
        if [ ! -d "${!dir}" ]; then
            elog "creating directory ${!dir}"
            mkdir -p "${!dir}"
        fi
    done

    elog 'installing prerequisite dependencies (sudo)'
    install_bootstrap_depends

    elog "fetching odoo from remote git repository (this can take some time...)"
    rm -Rf "${DIR_MAIN}"
    erun git clone "${PROFILE_REPO}" -b "${PROFILE_BRANCH}" --single-branch "${DIR_MAIN}"

    doh_patch_main
    doh_install_extra

    elog "installing odoo dependencies (sudo)"
    install_odoo_depends "${DIR_MAIN}"

    if [ x"$local_database" = x"true" ]; then
        elog "installing postgresql server (sudo)"
        install_postgresql_server
        erunquiet sudo service postgresql start || die 'PostgreSQL server doesnt seems to be running'
        db_config_local_server
    fi

    doh_config_init

    elog "starting odoo (sudo)"
    erun sudo service odoo-${PROFILE_NAME} start

    elog "installation sucessfull, you can now access odoo using http://localhost:8069/"
}

cmd_upgrade() {
: <<HELP_CMD_UPGRADE
doh upgrade [DATABASE ...]
HELP_CMD_UPGRADE

    doh_profile_load
    doh_profile_update

    doh_upgrade_main
    doh_install_extra

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
    erunquiet doh_run_server -d "${DB}" --stop-after-init -i "${DB_INIT_MODULES_ON_CREATE:-base}" ${DB_INIT_EXTRA_ARGS} || die "Failed to initialize database ${DB}"
    elog "database ${DB} created successfully"
}

cmd_drop_db() {
: <<HELP_CMD_DROP_DB
doh drop-db NAME

HELP_CMD_DROP_DB
    if [ $# -lt 1 ]; then
        echo "Usage: doh drop-db: missing arguemnt -- NAME"
        cmd_help "drop_db"
    fi
    DB="$1"

    doh_profile_load
    db_client_setup_env
    doh_svc_stop
    elog "droping database ${DB}"
    erunquiet dropdb "${DB}" || die "Unable to drop database ${DB}"
}

cmd_upgrade_db() {
: <<HELP_CMD_UPGRADE_DB
doh upgrade-db NAME

HELP_CMD_UPGRADE_DB
    if [ $# -lt 1 ]; then
        echo "Usage: doh upgrade-db: missing argument -- NAME"
        cmd_help "upgrade_db"
    fi
    DB="$1"

    doh_profile_load
    elog "upgrading ${DB}... (will take some time)"
    erunquiet doh_run_server -d "${DB}" --stop-after-init -u all || die 'Unable to upgrade database'
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
