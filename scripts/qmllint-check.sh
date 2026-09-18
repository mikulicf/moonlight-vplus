#!/usr/bin/env bash
# QML type-resolution check.
#
# Catch unresolved types, which are fatal at runtime but can pass qmlcachegen.
# For example, importing QtQuick 2.9 while using the 2.15 HoverHandler prevented
# AppView from loading even though platform builds passed (issue #153).
#
# Existing style/deprecation/unqualified-access warnings are outside this focused check.
#
# Usage: scripts/qmllint-check.sh

set -euo pipefail

cd "$(dirname "$0")/.."

# install-qt-action supplies QT_ROOT_DIR in CI; otherwise search PATH.
if [ -n "${QT_ROOT_DIR:-}" ] && [ -x "$QT_ROOT_DIR/bin/qmllint" ]; then
    QMLLINT="$QT_ROOT_DIR/bin/qmllint"
elif command -v qmllint > /dev/null 2>&1; then
    QMLLINT="$(command -v qmllint)"
else
    echo "qmllint not found; set QT_ROOT_DIR or add it to PATH" >&2
    exit 1
fi

echo "qmllint: $QMLLINT"

# Avoid mapfile because macOS ships Bash 3.2.
QML_FILES=()
while IFS= read -r f; do
    QML_FILES+=("$f")
done < <(git ls-files 'app/gui/*.qml' 'app/gui/**/*.qml')
if [ "${#QML_FILES[@]}" -eq 0 ]; then
    echo "No QML files found" >&2
    exit 1
fi
echo "Checking ${#QML_FILES[@]} QML files"

# qmllint cannot see C++-registered types. Derive allowed types, module URIs,
# and major versions from registration code instead of maintaining a static list.
# Each row is: <QML type> <module URI> <major version>.
cpp_types=$(grep -rhoE "qmlRegister(Singleton|Uncreatable)?Type<[A-Za-z_]+>\(\"[A-Za-z_.]+\", *[0-9]+, *[0-9]+" app \
            | sed -E 's/^qmlRegister(Singleton|Uncreatable)?Type<([A-Za-z_]+)>\("([A-Za-z_.]+)", *([0-9]+).*/\2 \3 \4/' \
            | sort -u)
if [ -z "$cpp_types" ]; then
    echo "Could not derive registered QML types; check the registration-search pattern" >&2
    exit 1
fi
echo "C++-registered type exceptions:"
echo "$cpp_types" | sed 's/^/  /'

# Add app/gui to the import path so local components resolve; otherwise
# their warnings obscure real missing types.
raw=$("$QMLLINT" -I app/gui "${QML_FILES[@]}" 2>&1 || true)

resolution_failures=$(echo "$raw" | grep -E "was not found|is not a type" || true)

# Exempt a registered type only when this file imports its module. Otherwise
# missing imports such as AppModel 1.0 could pass despite failing at runtime.
remaining=""
while IFS= read -r line; do
    [ -z "$line" ] && continue

    file=$(echo "$line" | sed -E 's/^[A-Za-z]+: ([^:]+):[0-9]+:[0-9]+:.*/\1/')
    type=$(echo "$line" | sed -E 's/.*: ([A-Za-z_]+) (was not found|is not a type).*/\1/')

    exempt=0
    if [ -f "$file" ]; then
        reg=$(echo "$cpp_types" | awk -v t="$type" '$1 == t {print; exit}')
        if [ -n "$reg" ]; then
            uri=$(echo "$reg" | awk '{print $2}')
            major=$(echo "$reg" | awk '{print $3}')
            # Accept both versioned and unversioned module imports.
            if grep -qE "^import ${uri}( ${major}\.[0-9]+)?[[:space:]]*$" "$file"; then
                exempt=1
            fi
        fi
    fi

    if [ "$exempt" -eq 0 ]; then
        remaining="${remaining}${line}
"
    fi
done <<< "$resolution_failures"
remaining=$(echo "$remaining" | sed '/^$/d')

if [ -n "$remaining" ]; then
    echo
    echo "Unresolved types would prevent these QML files from loading:"
    echo
    echo "$remaining"
    echo
    echo "A common cause is using a type newer than the imported module version."
    echo "For example, HoverHandler needs QtQuick 2.15, not 2.9. An unversioned import usually resolves this."
    exit 1
fi

echo "Type-resolution check passed."
