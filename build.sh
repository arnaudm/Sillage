#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build.sh — compile Sillage en ligne de commande (sans Xcode.app) et
# assemble un bundle .app signé, prêt à recevoir les permissions TCC.
# ---------------------------------------------------------------------------

APP_NAME="Sillage"
BUNDLE_ID="com.cletetour.sillage"
CONFIG="release"
BUILD_DIR=".build/${CONFIG}"
APP_BUNDLE="build/${APP_NAME}.app"

# Identité de signature stable → TCC mémorise les permissions entre rebuilds.
# Priorité : (1) variable SILLAGE_SIGN_ID si définie ;
#            (2) sinon, 1re identité de signature VALIDE du trousseau
#                (ex. "Apple Development: ...") ;
#            (3) sinon, repli ad-hoc (permissions redemandées à chaque build).
SIGN_ID="${SILLAGE_SIGN_ID:-}"
if [ -z "${SIGN_ID}" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
                | awk -F'"' '/"/{print $2; exit}')"
fi

echo "==> Compilation (swift build -c ${CONFIG})"
swift build -c "${CONFIG}"

echo "==> Assemblage du bundle ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> Signature"
if [ -n "${SIGN_ID}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "${SIGN_ID}"; then
    echo "    Identité stable trouvée : ${SIGN_ID} (TCC persistera entre les builds)"
    codesign --force --deep \
        --sign "${SIGN_ID}" \
        --identifier "${BUNDLE_ID}" \
        --entitlements "Resources/Sillage.entitlements" \
        "${APP_BUNDLE}"
else
    echo "    ⚠️  Identité '${SIGN_ID}' absente — signature ad-hoc."
    echo "        Les permissions micro/écran seront redemandées après chaque rebuild."
    echo "        Pour les rendre persistantes : créer un certificat de signature de code"
    echo "        nommé '${SIGN_ID}' dans Trousseau d'accès."
    codesign --force --deep \
        --sign - \
        --identifier "${BUNDLE_ID}" \
        --entitlements "Resources/Sillage.entitlements" \
        "${APP_BUNDLE}"
fi

echo "==> OK : ${APP_BUNDLE}"
echo "    Lancer avec : open \"${APP_BUNDLE}\""
