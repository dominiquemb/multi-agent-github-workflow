#!/bin/bash

set -euo pipefail

SEARCH_ROOT="${1:-/workspace}"

find_candidate_dumps() {
    find "$SEARCH_ROOT" \
        \( -path "*/node_modules/*" -o -path "*/.git/*" -o -path "*/dist/*" -o -path "*/build/*" \) -prune -o \
        -type f \
        \( -iname "*.sql" -o -iname "*.dump" -o -iname "*.bak" -o -iname "*.backup" -o -iname "*.sqlite" -o -iname "*.sqlite3" -o -iname "*.db" \) \
        -print 2>/dev/null | sort
}

classify_file() {
    local file="$1"
    local header
    header="$(head -c 65536 "$file" 2>/dev/null || true)"

    if printf '%s' "$header" | grep -qi 'SQLite format 3'; then
        printf 'sqlite|binary sqlite header'
        return 0
    fi

    if printf '%s' "$header" | grep -Eqi 'PostgreSQL database dump|pg_dump|SET search_path|::regclass|COPY .+ FROM stdin'; then
        printf 'postgres|postgres dump markers'
        return 0
    fi

    if printf '%s' "$header" | grep -Eqi 'MariaDB dump|Server version.*MariaDB'; then
        printf 'mariadb|mariadb dump markers'
        return 0
    fi

    if printf '%s' "$header" | grep -Eqi 'MySQL dump|ENGINE=InnoDB|UNLOCK TABLES|LOCK TABLES|/\*![0-9]{5}|AUTO_INCREMENT='; then
        printf 'mysql-compatible|mysql dump markers'
        return 0
    fi

    case "$file" in
        *.sqlite|*.sqlite3)
            printf 'sqlite|sqlite extension'
            return 0
            ;;
        *.db)
            printf 'sqlite|db extension'
            return 0
            ;;
    esac

    printf 'unknown|no strong markers'
}

install_hint() {
    case "$1" in
        postgres)
            printf 'apt-get update && apt-get install -y postgresql postgresql-client'
            ;;
        mariadb)
            printf 'apt-get update && apt-get install -y mariadb-server mariadb-client'
            ;;
        mysql-compatible)
            printf 'apt-get update && apt-get install -y mariadb-server mariadb-client'
            ;;
        sqlite)
            printf 'apt-get update && apt-get install -y sqlite3'
            ;;
        *)
            printf 'inspect the dump manually before installing database tooling'
            ;;
    esac
}

found=0
while IFS= read -r file; do
    found=1
    result="$(classify_file "$file")"
    engine="${result%%|*}"
    evidence="${result#*|}"
    printf 'FILE=%s\n' "$file"
    printf 'DB_ENGINE=%s\n' "$engine"
    printf 'EVIDENCE=%s\n' "$evidence"
    printf 'INSTALL_HINT=%s\n' "$(install_hint "$engine")"
    printf '\n'
done < <(find_candidate_dumps)

if [ "$found" -eq 0 ]; then
    echo "DB_ENGINE=unknown"
    echo "EVIDENCE=no dump or seed files detected"
    echo "INSTALL_HINT=inspect repository docs and runtime config before installing database tooling"
fi
