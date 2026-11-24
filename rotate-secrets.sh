#!/bin/bash
# Shanoir NG - Import, manage and share neuroimaging data
# Copyright (C) 2009-2019 Inria - https://www.inria.fr/
# Contact us on https://project.inria.fr/shanoir/
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see https://www.gnu.org/licenses/gpl-3.0.html

# Changes the passwords of the data stores of an EXISTING install to the values of .env, and
# reduces the database accounts to the rights of their own schema, so that an install created
# before the secrets moved to .env ends up like a new one.
#
# Why it is needed: MariaDB, Postgres and the LDAP server only read their passwords when they
# create their volume. On an existing install, new values in .env change nothing in the stores,
# and the microservices are then refused. The old database accounts also have all rights on every
# schema (GRANT ALL ON *.*).
#
# Stores handled (a store whose container is not running is skipped):
#   mariadb      Shanoir database : root, and the account of each microservice (and its rights)
#   keycloak-db  Keycloak database: root, and the Keycloak account (and its rights)
#   pacs-db      PACS Postgres    : the account of the PACS database
#   ldap         PACS LDAP        : the root account and the configuration account
# Not handled: RabbitMQ (one rabbitmqctl command, see .env.example) and the Keycloak admin account
# (put in .env the password it already has).
#
# Without --apply it only checks and prints what it would change. It can be run again: a password
# already changed is recognised.
#
# Run it from this directory, with the new values in .env (see .env.example and check-env.sh).
# Stop the services that use the stores first, take a backup, then start them again afterwards
# (docker compose up -d) so that they get the new values.

set -eu -o pipefail

cd "$(dirname "$0")"

usage()
{
	cat <<EOF
usage: ./rotate-secrets.sh [--apply] [--only STORE[,STORE...]]

  --apply   change the passwords and the rights (without it, only check and print the plan)
  --only    mariadb, keycloak-db, pacs-db, ldap (default: all of them)

The new values are read from .env (ENV_FILE=other-file to use another one). Letters, digits and
. _ @ + = : , - only, so that this script reads exactly what docker compose passes to the containers.
The stores must still accept their current root password: the old release defaults, or the values
you give in:
  OLD_SHANOIR_DB_ROOT_PASSWORD            (default: password)
  OLD_SHANOIR_KEYCLOAK_DB_ROOT_PASSWORD   (default: password)
  OLD_SHANOIR_PACS_LDAP_CONFIG_PASSWORD   (default: secret)
EOF
}

die()
{
	echo "error: $*" >&2
	exit 1
}

APPLY=0
ONLY="mariadb,keycloak-db,pacs-db,ldap"
while [ $# -gt 0 ] ; do
	case "$1" in
		--apply) APPLY=1 ;;
		--only) shift; ONLY="${1:-}" ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "unknown option: $1" ;;
	esac
	shift
done
for store in $(echo "$ONLY" | tr ',' ' ') ; do
	case "$store" in
		mariadb|keycloak-db|pacs-db|ldap) ;;
		*) die "unknown store: $store (mariadb, keycloak-db, pacs-db, ldap)" ;;
	esac
done
[ -n "$ONLY" ] || die "--only needs a list of stores"

ENV_FILE="${ENV_FILE:-.env}"
OLD_DB_ROOT_PASSWORD="${OLD_SHANOIR_DB_ROOT_PASSWORD:-password}"
OLD_KEYCLOAK_DB_ROOT_PASSWORD="${OLD_SHANOIR_KEYCLOAK_DB_ROOT_PASSWORD:-password}"
OLD_LDAP_CONFIG_PASSWORD="${OLD_SHANOIR_PACS_LDAP_CONFIG_PASSWORD:-secret}"

# schemas of the Shanoir database, one per microservice (as in docker-compose/database/2_add_users.sh)
SERVICES="studies users import datasets preclinical migrations"
KEYCLOAK_DB_SCHEMA=keycloak
LDAP_BASE_DN="dc=dcm4che,dc=org"

# the microservices and others that hold connections to the stores
CLIENTS="users studies import datasets preclinical database-migrations keycloak dcm4chee-arc"

want()
{
	case ",$ONLY," in *",$1,"*) return 0 ;; esac
	return 1
}

is_running()
{
	local id
	id="$(docker compose ps -q "$1" 2>/dev/null | head -n 1 || true)"
	[ -n "$id" ] && [ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" = true ]
}

# ---------------------------------------------------------------------------------------------
# reading .env
# ---------------------------------------------------------------------------------------------

# value of NAME in the env file (the last assignment wins; surrounding quotes removed, no expansion)
env_value()
{
	sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=\(.*\)$/\2/p" "$ENV_FILE" \
		| tail -n 1 | sed -e 's/\r$//' -e "s/^'\(.*\)'$/\1/" -e 's/^"\(.*\)"$/\1/'
}

check_chars()
{
	case "$2" in
		*[!A-Za-z0-9._@+=:,-]*)
			die "$1 in $ENV_FILE has a character other than letters, digits and . _ @ + = : , - : use only those" ;;
	esac
}

# a setting that may be empty (names)
setting()
{
	local v
	v="$(env_value "$1")"
	check_chars "$1" "$v"
	printf '%s' "$v"
}

# a required secret
secret()
{
	local v
	v="$(env_value "$1")"
	[ -n "$v" ] || die "$1 is not set in $ENV_FILE (see .env.example)"
	check_chars "$1" "$v"
	printf '%s' "$v"
}

# refuse to "rotate" to the default of the old releases
not_default()
{
	[ "$2" != "$3" ] || die "$1 in $ENV_FILE is still the default of the old releases: choose another password"
}

# escape a value for a single-quoted SQL string / a backquoted SQL identifier
sql_string()
{
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

sql_identifier()
{
	# shellcheck disable=SC2016 # literal backquotes
	printf '%s' "$1" | sed -e 's/`/``/g'
}

# ---------------------------------------------------------------------------------------------
# talking to the containers. Passwords travel on stdin, never on a command line.
# ---------------------------------------------------------------------------------------------

# SQL on stdin, as root, in the MariaDB container of service $1 (password $2)
sql_root()
{
	local svc=$1 pw=$2
	{ printf '%s\n' "$pw"; cat; } | docker compose exec -T "$svc" \
		sh -c 'IFS= read -r MYSQL_PWD && export MYSQL_PWD && exec mariadb -uroot -N -B'
}

# SQL on stdin, as user $2 (password $3) over TCP, in the MariaDB container of service $1
sql_as()
{
	local svc=$1 user=$2 pw=$3
	{ printf '%s\n' "$pw"; cat; } | docker compose exec -T "$svc" \
		sh -c 'IFS= read -r MYSQL_PWD && export MYSQL_PWD && exec mariadb -h127.0.0.1 -u"$0" -N -B' "$user"
}

# ---------------------------------------------------------------------------------------------
# MariaDB: Shanoir database and Keycloak database
# ---------------------------------------------------------------------------------------------

# rotate_mariadb SERVICE LABEL ROOT_NEW ROOT_OLD ACCOUNTS
# ACCOUNTS: one per line, "user|schema schema ...|new password"
rotate_mariadb()
{
	local svc=$1 label=$2 root_new=$3 root_old=$4 accounts=$5
	local pw how user schemas upw hosts host u s sql="" rhosts n

	if echo 'select 1' | sql_root "$svc" "$root_new" >/dev/null 2>&1 ; then
		pw=$root_new; how="root already has the password of $ENV_FILE"
	elif echo 'select 1' | sql_root "$svc" "$root_old" >/dev/null 2>&1 ; then
		pw=$root_old; how="root still has its old password"
	else
		die "$label: cannot log in as root, neither with the password of $ENV_FILE nor with the old one (see --help for OLD_*)"
	fi
	echo "[$label] $how"

	while IFS='|' read -r user schemas upw ; do
		[ -n "$user" ] || continue
		hosts="$(printf "SELECT Host FROM mysql.user WHERE User='%s';" "$(sql_string "$user")" | sql_root "$svc" "$pw")"
		[ -n "$hosts" ] || hosts='%'
		for host in $hosts ; do
			u="'$(sql_string "$user")'@'$(sql_string "$host")'"
			echo "[$label] $user@$host: new password, rights reduced to: $schemas"
			sql+="CREATE USER IF NOT EXISTS $u IDENTIFIED BY '$(sql_string "$upw")';"$'\n'
			sql+="ALTER USER $u IDENTIFIED BY '$(sql_string "$upw")';"$'\n'
			sql+="REVOKE ALL PRIVILEGES, GRANT OPTION FROM $u;"$'\n'
			for s in $schemas ; do
				sql+="GRANT ALL ON \`$(sql_identifier "$s")\`.* TO $u;"$'\n'
			done
		done
	done <<< "$accounts"

	# root last: if something fails before, it still has the password the script knows
	rhosts="$(printf "SELECT Host FROM mysql.user WHERE User='root';" | sql_root "$svc" "$pw")"
	for host in $rhosts ; do
		echo "[$label] root@$host: new password"
		sql+="ALTER USER 'root'@'$(sql_string "$host")' IDENTIFIED BY '$(sql_string "$root_new")';"$'\n'
	done
	sql+="FLUSH PRIVILEGES;"$'\n'

	[ "$APPLY" = 1 ] || return 0

	printf '%s' "$sql" | sql_root "$svc" "$pw" \
		|| die "$label: the SQL failed (see above). The script can be run again once the cause is fixed."

	# check: every account logs in with its new password and has no global privilege
	while IFS='|' read -r user schemas upw ; do
		[ -n "$user" ] || continue
		echo 'select 1' | sql_as "$svc" "$user" "$upw" >/dev/null 2>&1 \
			|| die "$label: $user cannot log in with the new password"
		n="$(printf 'SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES WHERE GRANTEE LIKE "%s" AND PRIVILEGE_TYPE <> "USAGE";' \
			"'$(sql_string "$user")'@%" | sql_root "$svc" "$root_new")"
		[ "$n" = 0 ] || die "$label: $user still has $n global privileges"
	done <<< "$accounts"
	echo 'select 1' | sql_root "$svc" "$root_new" >/dev/null 2>&1 || die "$label: root cannot log in with the new password"
	echo "[$label] done: every account logs in with its new password, none has a global privilege"
}

rotate_shanoir_db()
{
	local accounts="" s S schema
	for s in $SERVICES ; do
		S="$(echo "$s" | tr '[:lower:]' '[:upper:]')"
		schema="$(setting "SHANOIR_${S}_DB_NAME")"
		: "${schema:=$s}"
		if [ "$s" = migrations ] ; then
			# the migrations account creates the schemas of all the services (and the procedures
			# that run with its rights)
			local all="" t T tschema
			for t in $SERVICES ; do
				T="$(echo "$t" | tr '[:lower:]' '[:upper:]')"
				tschema="$(setting "SHANOIR_${T}_DB_NAME")"
				all="$all ${tschema:-$t}"
			done
			schema="${all# }"
		fi
		accounts+="$(setting "SHANOIR_${S}_DB_USER")|$schema|$(secret "SHANOIR_${S}_DB_PASSWORD")"$'\n'
	done
	rotate_mariadb database "mariadb" "$DB_ROOT_PASSWORD" "$OLD_DB_ROOT_PASSWORD" "$accounts"
}

rotate_keycloak_db()
{
	local user
	user="$(setting SHANOIR_KEYCLOAK_DB_USER)"
	rotate_mariadb keycloak-database "keycloak-db" "$KEYCLOAK_DB_ROOT_PASSWORD" "$OLD_KEYCLOAK_DB_ROOT_PASSWORD" \
		"${user:-keycloak}|$KEYCLOAK_DB_SCHEMA|$KEYCLOAK_DB_PASSWORD"$'\n'
}

# ---------------------------------------------------------------------------------------------
# PACS Postgres
# ---------------------------------------------------------------------------------------------

rotate_pacs_db()
{
	local user db who pw=$PACS_DB_PASSWORD
	user="$(setting SHANOIR_PACS_DATABASE_USER)"; user="${user:-pacs}"
	db="$(setting SHANOIR_PACS_DATABASE_NAME)"; db="${db:-pacsdb}"
	echo "[pacs-db] $user: new password"
	[ "$APPLY" = 1 ] || return 0
	# the image trusts the connections of the container itself, so the old password is not needed
	printf 'ALTER ROLE "%s" WITH PASSWORD '"'"'%s'"'"';\n' "$(printf '%s' "$user" | sed 's/"/""/g')" "$(printf '%s' "$pw" | sed "s/'/''/g")" \
		| docker compose exec -T dcm4chee-database psql -v ON_ERROR_STOP=1 -q -U "$user" -d "$db" \
		|| die "pacs-db: could not change the password of $user"
	# check with a real password authentication (over the network, not the trusted local socket)
	who="$(echo 'select current_user' | { printf '%s\n' "$pw"; cat; } | docker compose exec -T dcm4chee-database \
		sh -c 'IFS= read -r PGPASSWORD && export PGPASSWORD && exec psql -h "$(hostname -i | cut -d" " -f1)" -At -v ON_ERROR_STOP=1 -U "$0" -d "$1"' "$user" "$db" \
		2>/dev/null || true)"
	[ "$who" = "$user" ] || die "pacs-db: $user cannot log in with the new password"
	echo "[pacs-db] done: $user logs in with the new password"
}

# ---------------------------------------------------------------------------------------------
# PACS LDAP (OpenLDAP): root account cn=admin,<base> and configuration account cn=admin,cn=config
# ---------------------------------------------------------------------------------------------

# runs in the ldap container; stdin: new config password, old config password, new root password
# shellcheck disable=SC2016 # this script is meant for the container's shell: no expansion here
LDAP_SCRIPT='
umask 077
IFS= read -r newcfg; IFS= read -r oldcfg; IFS= read -r newroot
tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
printf "%s" "$newcfg" > "$tmp/newcfg"; printf "%s" "$oldcfg" > "$tmp/oldcfg"; printf "%s" "$newroot" > "$tmp/newroot"
H=ldap://localhost
CFG="cn=admin,cn=config"
ROOT="cn=admin,'"$LDAP_BASE_DN"'"
if ldapwhoami -x -H $H -D "$CFG" -y "$tmp/newcfg" >/dev/null 2>&1; then cur="$tmp/newcfg"; echo "config account already has the new password"
elif ldapwhoami -x -H $H -D "$CFG" -y "$tmp/oldcfg" >/dev/null 2>&1; then cur="$tmp/oldcfg"; echo "config account still has its old password"
else echo "cannot bind as $CFG with the new or the old password" >&2; exit 3; fi
if [ "$APPLY" != 1 ]; then exit 0; fi
dn_of() { ldapsearch -x -H $H -D "$CFG" -y "$cur" -b cn=config -LLL "(olcRootDN=$1)" dn | sed -n "s/^dn: //p" | head -n 1; }
rootdb="$(dn_of "$ROOT")"; cfgdb="$(dn_of "$CFG")"
[ -n "$rootdb" ] && [ -n "$cfgdb" ] || { echo "cannot find the LDAP databases in cn=config" >&2; exit 4; }
hroot="$(slappasswd -T "$tmp/newroot")"; hcfg="$(slappasswd -T "$tmp/newcfg")"
# root database first, the configuration database (the account we are bound as) last
printf "dn: %s\nchangetype: modify\nreplace: olcRootPW\nolcRootPW: %s\n" "$rootdb" "$hroot" | ldapmodify -x -H $H -D "$CFG" -y "$cur" >/dev/null
printf "dn: %s\nchangetype: modify\nreplace: olcRootPW\nolcRootPW: %s\n" "$cfgdb" "$hcfg" | ldapmodify -x -H $H -D "$CFG" -y "$cur" >/dev/null
ldapwhoami -x -H $H -D "$ROOT" -y "$tmp/newroot" >/dev/null 2>&1 || { echo "root account cannot bind with the new password" >&2; exit 5; }
ldapwhoami -x -H $H -D "$CFG" -y "$tmp/newcfg" >/dev/null 2>&1 || { echo "config account cannot bind with the new password" >&2; exit 5; }
echo "root and config accounts bind with the new passwords"
'

rotate_ldap()
{
	{ printf '%s\n' "$LDAP_CONFIG_PASSWORD"; printf '%s\n' "$OLD_LDAP_CONFIG_PASSWORD"; printf '%s\n' "$LDAP_ROOT_PASSWORD"; } \
		| docker compose exec -T -e APPLY="$APPLY" ldap sh -c "$LDAP_SCRIPT" | sed 's/^/[ldap] /' \
		|| die "ldap: failed (see above). The script can be run again once the cause is fixed."
}

# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------

[ -f "$ENV_FILE" ] || die "no $ENV_FILE in $(pwd) (see .env.example)"
if [ "$ENV_FILE" = .env ] ; then
	./check-env.sh || die "fix the configuration first (see above)"
fi

# read and check every new value before touching anything
if want mariadb ; then
	DB_ROOT_PASSWORD="$(secret SHANOIR_DB_ROOT_PASSWORD)"
	not_default SHANOIR_DB_ROOT_PASSWORD "$DB_ROOT_PASSWORD" password
	for s in $SERVICES ; do
		S="$(echo "$s" | tr '[:lower:]' '[:upper:]')"
		not_default "SHANOIR_${S}_DB_PASSWORD" "$(secret "SHANOIR_${S}_DB_PASSWORD")" password
	done
fi
if want keycloak-db ; then
	KEYCLOAK_DB_ROOT_PASSWORD="$(secret SHANOIR_KEYCLOAK_DB_ROOT_PASSWORD)"
	KEYCLOAK_DB_PASSWORD="$(secret SHANOIR_KEYCLOAK_DB_PASSWORD)"
	not_default SHANOIR_KEYCLOAK_DB_ROOT_PASSWORD "$KEYCLOAK_DB_ROOT_PASSWORD" password
	not_default SHANOIR_KEYCLOAK_DB_PASSWORD "$KEYCLOAK_DB_PASSWORD" password
fi
if want pacs-db ; then
	PACS_DB_PASSWORD="$(secret SHANOIR_PACS_DATABASE_PASSWORD)"
	not_default SHANOIR_PACS_DATABASE_PASSWORD "$PACS_DB_PASSWORD" pacs
fi
if want ldap ; then
	LDAP_ROOT_PASSWORD="$(secret SHANOIR_PACS_LDAP_ROOT_PASSWORD)"
	LDAP_CONFIG_PASSWORD="$(secret SHANOIR_PACS_LDAP_CONFIG_PASSWORD)"
	not_default SHANOIR_PACS_LDAP_ROOT_PASSWORD "$LDAP_ROOT_PASSWORD" secret
	not_default SHANOIR_PACS_LDAP_CONFIG_PASSWORD "$LDAP_CONFIG_PASSWORD" secret
fi

if [ "$APPLY" = 1 ] ; then
	echo "Changing the secrets of the install in $(pwd)"
else
	echo "Checking only (nothing changes without --apply) the install in $(pwd)"
fi

busy=""
for c in $CLIENTS ; do
	if is_running "$c" ; then busy="$busy $c"; fi
done
if [ -n "$busy" ] ; then
	echo "warning: still running:$busy"
	echo "         They hold connections with the old passwords. Stop them before --apply" \
		"(docker compose stop$busy) and start them again afterwards."
fi

done_any=0
if want mariadb ; then
	if is_running database ; then rotate_shanoir_db; done_any=1; else die "the 'database' container is not running (docker compose up -d database)"; fi
fi
if want keycloak-db ; then
	if is_running keycloak-database ; then rotate_keycloak_db; done_any=1; else echo "[keycloak-db] not running: skipped"; fi
fi
if want pacs-db ; then
	if is_running dcm4chee-database ; then rotate_pacs_db; done_any=1; else echo "[pacs-db] not running: skipped"; fi
fi
if want ldap ; then
	if is_running ldap ; then rotate_ldap; done_any=1; else echo "[ldap] not running: skipped"; fi
fi
[ "$done_any" = 1 ] || die "nothing to do: none of the stores is running"

if [ "$APPLY" = 1 ] ; then
	echo "Now start the install again so that every service gets the new values: docker compose up -d"
else
	echo "Nothing was changed. Run again with --apply to change the passwords and the rights."
fi
