#!/usr/bin/env python3
"""Copy VoidrauVPN platform overlays onto a flutter create scaffold and patch SDK floors."""
from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OVERLAYS = ROOT / "overlays"


def copy_tree(src: Path, dst: Path) -> None:
    if not src.exists():
        return
    for path in src.rglob("*"):
        if path.is_dir():
            continue
        rel = path.relative_to(src)
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        print("copied", rel)


def _ensure_kts_packaging(text: str) -> str:
    """Ensure Kotlin DSL has packaging.jniLibs.useLegacyPackaging = true"""
    if "useLegacyPackaging" in text:
        return text
    return _ensure_extra(
        text,
        "useLegacyPackaging",
        """    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }""",
    )


def _ensure_groovy_packaging(text: str) -> str:
    """Ensure Groovy DSL has packaging with useLegacyPackaging true"""
    if "useLegacyPackaging" in text:
        return text
    return _ensure_extra(
        text,
        "useLegacyPackaging",
        """    packaging {
        jniLibs {
            useLegacyPackaging true
        }
    }""",
    )


def _ensure_extra(ctx: str, needle: str, extra: str) -> str:
    """Insert `extra` right after the first `android {` if `needle` isn't present.

    Flutter scaffolds (3.27.4 Kotlin and Groovy alike) use a single android {}
    configuration block, so inserting after its opening brace puts the extra
    inside the block.
    """
    if needle in ctx:
        return ctx
    m = re.search(r"android\s*\{", ctx)
    if m is None:
        return ctx
    pos = m.end()
    return ctx[:pos] + "\n" + extra + ctx[pos:]


def patch_android_gradle() -> None:
    gradle = ROOT / "android" / "app" / "build.gradle.kts"
    groovy = ROOT / "android" / "app" / "build.gradle"
    path = gradle if gradle.exists() else groovy
    if not path.exists():
        print("android gradle missing")
        return
    text = path.read_text(encoding="utf-8")

    # Patch min/target SDK
    text = re.sub(r"minSdk\s*=\s*.+", "minSdk = 24", text)
    text = re.sub(r"minSdkVersion\s+.+", "minSdkVersion 24", text)
    text = re.sub(r"targetSdk\s*=\s*.+", "targetSdk = 35", text)
    text = re.sub(r"targetSdkVersion\s+.+", "targetSdkVersion 35", text)

    # The Android identity is intentionally frozen at the id the app shipped
    # with: a rebranded APK with a new applicationId would install *next to*
    # the old app instead of upgrading it, and the in-app updater (which
    # verifies the signing certificate of the installed app) would break.
    # The namespace stays on the overlay's Kotlin package so the manifest can
    # keep using relative component names.
    legacy_application_id = "pm.dnschanger.nimbus"
    legacy_namespace = "pm.dnschanger.nimbus"
    text = re.sub(r"applicationId\s*=?\s*\"[^\"]*\"",
                  f'applicationId = "{legacy_application_id}"', text)
    text = re.sub(r"applicationId\s+\"[^\"]*\"",
                  f'applicationId = "{legacy_application_id}"', text)
    if "applicationId" not in text:
        if path.suffix == ".kts":
            text = _ensure_extra(
                text,
                "applicationId",
                f'    applicationId = "{legacy_application_id}"',
            )
        else:
            text = _ensure_extra(
                text, "applicationId", f'    applicationId "{legacy_application_id}"')
    text = re.sub(r"namespace\s*=?\s*\"[^\"]*\"",
                  f'namespace = "{legacy_namespace}"', text)

    # `flutter create` scaffolds its own MainActivity in the project-name
    # package; the overlay below installs the real one (with the engine plugin)
    # in the frozen package, so drop the scaffold's copy.
    scaffold_pkg = ROOT / "android" / "app" / "src" / "main" / "kotlin" / "pm" / "dnschanger" / "voidrauvpn"
    if scaffold_pkg.exists():
        for stale in scaffold_pkg.glob("*.kt"):
            stale.unlink()
            print("removed scaffold", stale.relative_to(ROOT))

    # Ensure NDK abiFilters (inside defaultConfig, the documented location).
    # `flutter build apk --split-per-abi` passes -Psplit-per-abi=true, which makes
    # Flutter's Gradle plugin configure splits.abi itself. AGP then fails the
    # build when ndk.abiFilters is also set:
    #   "Conflicting configuration : ... in ndk abiFilters cannot be present
    #    when splits abi filters are set"
    # So the filters must only be applied for non-split (universal) builds.
    if "abiFilters" not in text:
        groovy_filters = (
            "defaultConfig {\n"
            "        ndk {\n"
            "            // ndk.abiFilters cannot coexist with APK splits\n"
            "            // (flutter build apk --split-per-abi => -Psplit-per-abi=true).\n"
            '            if (!(project.hasProperty("split-per-abi") && project.property("split-per-abi").toBoolean())) {\n'
            '                abiFilters "armeabi-v7a", "arm64-v8a", "x86_64"\n'
            "            }\n"
            "        }"
        )
        kts_filters = (
            "defaultConfig {\n"
            "        ndk {\n"
            "            // ndk.abiFilters cannot coexist with APK splits\n"
            "            // (flutter build apk --split-per-abi => -Psplit-per-abi=true).\n"
            '            if (project.findProperty("split-per-abi")?.toString()?.toBoolean() != true) {\n'
            '                abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")\n'
            "            }\n"
            "        }"
        )
        if path.suffix == ".kts":
            text = text.replace("defaultConfig {", kts_filters, 1)
        else:
            text = text.replace("defaultConfig {", groovy_filters, 1)

    # Ensure packaging legacy for extractNativeLibs=true compatibility
    # AGP 8.1+ removed android.bundle.enableUncompressedNativeLibs
    # Replacement is packaging.jniLibs.useLegacyPackaging
    if path.suffix == ".kts":
        text = _ensure_kts_packaging(text)
    else:
        text = _ensure_groovy_packaging(text)

    # Signing config for KTS
    # NOTE: the keystore alias default ("nimbus") is deliberately unchanged —
    # renaming it would change the release signature and break in-place updates.
    signing_kts = '''
    val store = System.getenv("ANDROID_KEYSTORE_PATH")
    if (!store.isNullOrBlank()) {
        signingConfigs {
            create("release") {
                storeFile = file(store)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: ""
                // Historical default alias: an alias rename would invalidate
                // the release signature and break in-place updates.
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "nimbus"
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: ""
            }
        }
    }
'''
    signing_groovy = '''
    def keystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
    if (keystorePath) {
        signingConfigs {
            release {
                storeFile file(keystorePath)
                storePassword System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: ""
                keyAlias System.getenv("ANDROID_KEY_ALIAS") ?: "nimbus"
                keyPassword System.getenv("ANDROID_KEY_PASSWORD") ?: ""
            }
        }
    }
'''

    if "ANDROID_KEYSTORE_PATH" not in text:
        if path.suffix == ".kts":
            # Insert the env-driven signingConfigs right before buildTypes.
            text = text.replace("buildTypes {", signing_kts.strip("\n") + "\n\n    buildTypes {", 1)
            # Point the release build type at the env-driven config, falling back
            # to debug when ANDROID_KEYSTORE_PATH isn't set.
            text = text.replace(
                "signingConfig = signingConfigs.debug",
                """signingConfig = if (signingConfigs.findByName("release") != null)
                signingConfigs.getByName("release") else signingConfigs.getByName("debug")""",
                1,
            )
        else:
            text = text.replace("buildTypes {", signing_groovy.strip("\n") + "\n\n    buildTypes {", 1)
            # Use the release config when the keystore env is set, else debug.
            # Flutter 3.27 Groovy templates write "signingConfig = signingConfigs.debug"
            # (with an '='); older templates omit it. Handle both forms.
            replaced = text.replace(
                "signingConfig = signingConfigs.debug",
                'signingConfig = signingConfigs.findByName("release") ?: signingConfigs.debug',
                1,
            )
            if replaced == text:
                replaced = text.replace(
                    "signingConfig signingConfigs.debug",
                    'signingConfig signingConfigs.findByName("release") ?: signingConfigs.debug',
                    1,
                )
            text = replaced

    path.write_text(text, encoding="utf-8")
    print("patched", path.relative_to(ROOT))

    # Fix gradle.properties - REMOVE deprecated property (removed in AGP 8.1)
    props = ROOT / "android" / "gradle.properties"
    if props.exists():
        p = props.read_text(encoding="utf-8")
        original = p
        # Remove any line containing android.bundle.enableUncompressedNativeLibs
        lines = []
        for line in p.splitlines():
            if "android.bundle.enableUncompressedNativeLibs" in line:
                print(f"removing deprecated property: {line.strip()}")
                continue
            # Also remove old packaging legacy flag if mistakenly added as property
            lines.append(line)
        new_p = "\n".join(lines)
        # Ensure file ends with newline
        if new_p and not new_p.endswith("\n"):
            new_p += "\n"
        if new_p != original:
            props.write_text(new_p, encoding="utf-8")
            print("patched gradle.properties - removed deprecated enableUncompressedNativeLibs")

    # Also check if settings.gradle.kts or gradle.properties elsewhere has the flag
    for extra_props in [
        ROOT / "android" / "app" / "gradle.properties",
        ROOT / "android" / "local.properties",
    ]:
        if extra_props.exists():
            ep = extra_props.read_text(encoding="utf-8")
            if "android.bundle.enableUncompressedNativeLibs" in ep:
                cleaned = "\n".join(
                    l for l in ep.splitlines() if "android.bundle.enableUncompressedNativeLibs" not in l
                )
                extra_props.write_text(cleaned + "\n", encoding="utf-8")
                print(f"cleaned deprecated property from {extra_props.relative_to(ROOT)}")


def patch_windows() -> None:
    main_cpp = ROOT / "windows" / "runner" / "main.cpp"
    if main_cpp.exists():
        t = main_cpp.read_text(encoding="utf-8")
        t = t.replace("Win32Window::Size size(1280, 720);", "Win32Window::Size size(420, 780);")
        t = t.replace("Win32Window::Size size(1280, 720)", "Win32Window::Size size(420, 780)")
        # The scaffold titles the window after the project name; the product
        # name is what belongs in the title bar and the taskbar.
        t = re.sub(r'window\.Create\(L"[^"]*"', 'window.Create(L"VoidrauVPN"', t)
        main_cpp.write_text(t, encoding="utf-8")
        print("patched window size and title")

    manifest = ROOT / "windows" / "runner" / "runner.exe.manifest"
    if manifest.exists():
        t = manifest.read_text(encoding="utf-8")
        if "1f676c76-80e1-4239-95bb-83d0f6d0da78" not in t:
            t = t.replace(
                "</application>",
                """  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
      <supportedOS Id="{35138b9a-5d96-4fbd-8e2d-a2440225f93a}"/>
    </application>
  </compatibility>
</application>""",
                1,
            )
        manifest.write_text(t, encoding="utf-8")

    cmake = ROOT / "windows" / "CMakeLists.txt"
    if cmake.exists():
        t = cmake.read_text(encoding="utf-8")
        # Ensure WINVER is defined for Win8.1+ support
        if "WINVER=0x0603" not in t:
            t = t.replace(
                "cmake_minimum_required",
                "add_definitions(-DWINVER=0x0603 -D_WIN32_WINNT=0x0603)\ncmake_minimum_required",
                1,
            )
        # Fix for VS2019 vs VS2022: ensure we don't force old generator
        # Remove any hardcoded Visual Studio 16 2019 generator if present
        t = re.sub(r'Visual Studio 16 2019', 'Visual Studio 17 2022', t)
        # Ensure CMake minimum is not too old for VS2022
        # Flutter 3.27 uses 3.14, which is okay for VS2022 but we can bump to 3.20 for safety
        # Keep original minimum to avoid breaking

        extra = """
file(GLOB VOIDRAU_SIDECARS "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/windows/*")
if(VOIDRAU_SIDECARS)
  install(FILES ${VOIDRAU_SIDECARS} DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
endif()
"""
        if "VOIDRAU_SIDECARS" not in t:
            t += "\n" + extra
        cmake.write_text(t, encoding="utf-8")
        print("patched windows CMakeLists")

    # Also patch windows/flutter/CMakeLists.txt if it exists to avoid generator issues
    flutter_cmake = ROOT / "windows" / "flutter" / "CMakeLists.txt"
    if flutter_cmake.exists():
        ft = flutter_cmake.read_text(encoding="utf-8")
        # No specific fix needed, but ensure no VS2019 hardcoded
        ft_new = re.sub(r'Visual Studio 16 2019', 'Visual Studio 17 2022', ft)
        if ft_new != ft:
            flutter_cmake.write_text(ft_new, encoding="utf-8")
            print("patched windows/flutter CMakeLists")

    ico_src = ROOT / "assets" / "branding" / "icon.ico"
    ico_dst = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    if ico_src.exists() and ico_dst.parent.exists():
        shutil.copy2(ico_src, ico_dst)
        print("copied app_icon.ico")


def main() -> None:
    copy_tree(OVERLAYS / "android", ROOT / "android")
    copy_tree(OVERLAYS / "windows", ROOT / "windows")
    patch_android_gradle()
    patch_windows()
    print("overlays applied")


if __name__ == "__main__":
    main()
