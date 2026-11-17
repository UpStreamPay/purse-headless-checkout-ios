#!/bin/sh
# Builds signed-ready XCFrameworks for the binary products into xcframeworks/. Run from the repo
# root; Package.swift is restored on exit. Used by .github/workflows/release.yml, runnable locally.
#
# Two stages, because a plugin archived next to the core *source* target would statically embed
# its own copy of the core: 1. the core, from the source manifest made dynamic; 2. the plugins,
# from a manifest where the core is the stage-1 binary (scripts/binary-manifest.py).
#
# `-alias-module-names-in-module-interface`: the module and its main class are both named
# `PurseHeadlessCheckout`, so an unaliased .swiftinterface reads `PurseHeadlessCheckout.JSONValue` as
# a member of the class and does not compile for any consumer.
#
# `SWIFT_PACKAGE_NAME=`: an interface that records a package name can only be loaded by a module of
# the same package from its package interface — and in the released manifest the PayPal plugin *is*
# a source target of the same package. The SDK uses no `package` access, so nothing is lost.
set -eu

OUT=xcframeworks
WORK=.build/xcf
rm -rf "$OUT" "$WORK"
mkdir -p "$OUT"
cp Package.swift "$WORK.Package.swift.orig" 2>/dev/null || { mkdir -p .build; cp Package.swift "$WORK.Package.swift.orig"; }
restore() {
    cp "$WORK.Package.swift.orig" Package.swift
    rm -rf Sources/*Deps
}
trap restore EXIT

# <module>: archive both slices, put back what an SPM archive leaves out, assemble.
build() {
    module=$1
    frameworks=""
    for platform in iphoneos iphonesimulator; do
        case $platform in
            iphoneos) destination="generic/platform=iOS" ;;
            *) destination="generic/platform=iOS Simulator" ;;
        esac
        archive="$WORK/$module-$platform.xcarchive"
        derived="$WORK/dd-$module-$platform"
        xcodebuild archive -quiet \
            -scheme "$module" \
            -destination "$destination" \
            -archivePath "$archive" \
            -derivedDataPath "$derived" \
            SKIP_INSTALL=NO \
            BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
            OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -alias-module-names-in-module-interface' \
            SWIFT_PACKAGE_NAME= \
            CODE_SIGNING_ALLOWED=NO \
            INSTALL_PATH=/Library/Frameworks

        # Same repackaging as purse-securefields-ios: an SPM archive leaves the .swiftmodule in
        # the intermediates and the resource bundle beside the framework, and Apple wants the
        # privacy manifest at the framework root.
        fw="$archive/Products/Library/Frameworks/$module.framework"
        mkdir -p "$fw/Modules"
        cp -R "$derived/Build/Intermediates.noindex/ArchiveIntermediates/$module/BuildProductsPath/Release-$platform/$module.swiftmodule" "$fw/Modules/"
        bundle="$archive/Products/Library/Frameworks/${module}_${module}.bundle"
        if [ -d "$bundle" ]; then
            cp -R "$bundle" "$fw/"
            [ -f "$bundle/PrivacyInfo.xcprivacy" ] && cp "$bundle/PrivacyInfo.xcprivacy" "$fw/"
        fi
        frameworks="$frameworks -framework $fw"
    done
    # shellcheck disable=SC2086
    xcodebuild -create-xcframework $frameworks -output "$OUT/$module.xcframework"
}

sed -E -i '' 's/\.library\(name: "PurseHeadlessCheckout", targets/.library(name: "PurseHeadlessCheckout", type: .dynamic, targets/' Package.swift
build PurseHeadlessCheckout

python3 scripts/binary-manifest.py path "$OUT" PurseHeadlessCheckout
build PurseCheckoutApplePay
build PurseCheckoutKlarna
