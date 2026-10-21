#!/bin/sh
# Install (or remove) linequality and luci-app-linequality from this checkout on
# a router over ssh, without building packages. Usage:
#   ./install.sh [root@host]
#   ./install.sh [root@host] --uninstall
# The host defaults to $LINEQUALITY_HOST, then root@192.168.1.1.
# An existing /etc/config/linequality is never overwritten.

set -eu

HOST=${LINEQUALITY_HOST:-root@192.168.1.1}
UNINSTALL=0
for arg in "$@"; do
	case "$arg" in
	--uninstall) UNINSTALL=1 ;;
	-h|--help) sed -n '2,7p' "$0"; exit 0 ;;
	*) HOST=$arg ;;
	esac
done

TOP=$(cd "$(dirname "$0")" && pwd)
BACKEND=$TOP/linequality/files
LUCI=$TOP/luci-app-linequality

remote() {
	ssh "$HOST" "$@"
}

# put LOCAL REMOTE MODE: copy one file through ssh, creating the directory
put() {
	echo "  $2"
	remote "mkdir -p '${2%/*}' && cat > '$2' && chmod $3 '$2'" < "$1"
}

# put_glob LOCAL_DIR PATTERN REMOTE_DIR MODE
put_glob() {
	for f in "$1"/$2; do
		[ -f "$f" ] || continue
		put "$f" "$3/${f##*/}" "$4"
	done
}

# list_glob LOCAL_DIR PATTERN REMOTE_DIR: remote paths matching the local files
list_glob() {
	for f in "$1"/$2; do
		[ -f "$f" ] && echo "$3/${f##*/}"
	done
}

if [ "$UNINSTALL" = 1 ]; then
	echo "Removing linequality from $HOST (config and data are kept)"
	remote '[ -x /etc/init.d/linequality ] && { /etc/init.d/linequality stop; /etc/init.d/linequality disable; }; true'
	files="/usr/share/linequality/linequalityd.uc /etc/init.d/linequality /lib/upgrade/keep.d/linequality"
	files="$files $(list_glob "$LUCI/htdocs/luci-static/resources/view/linequality" '*.js' /www/luci-static/resources/view/linequality)"
	files="$files $(list_glob "$LUCI/root/usr/share/luci/menu.d" '*.json' /usr/share/luci/menu.d)"
	files="$files $(list_glob "$LUCI/root/usr/share/rpcd/acl.d" '*.json' /usr/share/rpcd/acl.d)"
	remote "rm -f $files /usr/lib/lua/luci/i18n/linequality.*.lmo; rmdir /usr/share/linequality /www/luci-static/resources/view/linequality 2>/dev/null; true"
else
	echo "Installing on $HOST"
	put "$BACKEND/linequalityd.uc" /usr/share/linequality/linequalityd.uc 0755
	put "$BACKEND/linequality.init" /etc/init.d/linequality 0755
	put "$BACKEND/linequality.keep" /lib/upgrade/keep.d/linequality 0644
	if remote '[ -e /etc/config/linequality ]'; then
		echo "  /etc/config/linequality exists, left untouched"
	else
		put "$BACKEND/linequality.config" /etc/config/linequality 0644
	fi
	put_glob "$LUCI/htdocs/luci-static/resources/view/linequality" '*.js' /www/luci-static/resources/view/linequality 0644
	put_glob "$LUCI/root/usr/share/luci/menu.d" '*.json' /usr/share/luci/menu.d 0644
	put_glob "$LUCI/root/usr/share/rpcd/acl.d" '*.json' /usr/share/rpcd/acl.d 0644
	# translations: LuCI's po2lmo if installed, otherwise the Python port
	PO2LMO=${PO2LMO:-$(command -v po2lmo || true)}
	if [ -z "$PO2LMO" ] && command -v python3 >/dev/null; then
		PO2LMO=$TOP/scripts/po2lmo.py
	fi
	if [ -n "$PO2LMO" ]; then
		for po in "$LUCI"/po/*/linequality.po; do
			lang=${po%/*}
			lang=${lang##*/}
			lmo=$(mktemp)
			"$PO2LMO" "$po" "$lmo"
			put "$lmo" "/usr/lib/lua/luci/i18n/linequality.$lang.lmo" 0644
			rm -f "$lmo"
		done
	fi
	remote '/etc/init.d/linequality enable; /etc/init.d/linequality restart'
fi

remote '/etc/init.d/rpcd reload; rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache'
echo "Done"
