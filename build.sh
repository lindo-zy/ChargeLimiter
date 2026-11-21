#!/usr/bin/env bash
# ChargeLimiter 统一构建入口（Theos roothide 工程；参考 Metis build.sh 的双 SDK 模式）。
#
# 用法：
#   ./build.sh --help
#   ./build.sh                       # ios16 + ios17 双目标构建 + 包检查，输出到 packages/
#   ./build.sh --target ios16        # 单目标构建
#
# 规则：
#   - 只做 RootHide 包：THEOS_PACKAGE_SCHEME=roothide，Architecture iphoneos-arm64e。
#     不再产出 TrollStore tipa / rootful / rootless。
#   - 产物统一 packages/<label>/（ios16 / ios17，与 Metis 同款），命名
#     com.chargelimiter.mod_<ver>_<label>_iphoneos-arm64e.deb——版本在文件名里区分。
#   - 版本每次构建自动递增（PATCH+1，>10 进 MINOR；MINOR 不自动进位；--version 可覆盖），
#     全部目标成功后写回 control + Info.plist，失败保持原版本。
#   - 本地目录只保留最新一次构建：每次构建前清空对应 label 目录的旧 deb，
#     不保留历史版本（历史版本走 GitHub Releases）。
#   - 版本单一来源 = control；Info.plist 短版本必须与之一致，不一致直接报错。
#   - 构建进程级锁：同一时刻只允许一个 build.sh 写 packages/。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${THEOS:-}" || ! -d "${THEOS:-}" ]]; then
    THEOS="/Users/xiao/dev/theos-roothide"
fi
export THEOS

MAKE_BIN="$(command -v gmake || command -v make || true)"
if [[ -z "$MAKE_BIN" ]]; then
    echo "error: make or gmake is required" >&2
    exit 1
fi
if [[ ! -d "$THEOS" ]]; then
    echo "error: Theos not found at $THEOS" >&2
    exit 1
fi

PACKAGE_ID="com.chargelimiter.mod"
CONTROL_FILE="$ROOT_DIR/control"
INFO_PLIST="$ROOT_DIR/ChargeLimiter/Info.plist"
# 部署目标 14.0：arm64e 切片的工具链下限是 iOS 14（theos arm64e-deployment 约定），
# 且 roothide bootstrap 实际运行于 iOS 15+；旧的 13.0 是 rootful 时代遗留。
DEPLOYMENT_TARGET="14.0"
BANNED_ENT_REGEX='com\.apple\.private\.cs\.debugger|dynamic-codesigning|com\.apple\.private\.skip-library-validation'

CONTROL_VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' "$CONTROL_FILE")"
if [[ ! "$CONTROL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: control Version must use MAJOR.MINOR.PATCH: ${CONTROL_VERSION:-<missing>}" >&2
    exit 1
fi

# 版本自动递增（TypeX 的 PATCH 溢出规则）：PATCH +1，>10 进 MINOR。
# MINOR 不自动进位——本工程 MINOR 可能 ≥10（1.17.x），套用 MINOR 满 10 进 MAJOR
# 会每次构建都跳大版本；跨 MINOR/MAJOR 用 --version 显式指定。
bump_version() {
    local major="${1%%.*}" rest="${1#*.}"
    local minor="${rest%%.*}" patch="${rest##*.}"
    patch=$((10#$patch + 1))
    if (( patch > 10 )); then patch=0; minor=$((10#$minor + 1)); fi
    echo "${major}.${minor}.${patch}"
}

usage() {
    cat >&2 <<'EOF'
usage: ./build.sh [--target ios16|ios17|all] [--version MAJOR.MINOR.PATCH]
  --target   构建目标，默认 all（ios16 = iPhoneOS16.5.sdk，ios17 = iPhoneOS17.0.sdk）。
  --version  可选覆盖（MAJOR.MINOR.PATCH）。缺省自动递增：PATCH +1（>10 进 MINOR，
             MINOR 不自动进 MAJOR）；全部目标构建成功后才写回 control 与 Info.plist，
             失败不写（保持原版本）。
环境变量：
  THEOS=<dir>                 覆盖 Theos 路径（默认 /Users/xiao/dev/theos-roothide）。
EOF
    exit 2
}

BUILD_TARGET="all"
BUILD_VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) BUILD_TARGET="${2:-}"; shift 2 ;;
        --version) BUILD_VERSION="${2:-}"; shift 2 ;;
        --help|-h) usage ;;
        *) echo "error: unknown argument: $1" >&2; usage ;;
    esac
done
case "$BUILD_TARGET" in
    ios16|ios17|all) ;;
    *) echo "error: invalid --target: $BUILD_TARGET" >&2; usage ;;
esac
if [[ -n "$BUILD_VERSION" ]] && ! [[ "$BUILD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must be MAJOR.MINOR.PATCH: $BUILD_VERSION" >&2
    exit 1
fi
VERSION_TO_BUILD="${BUILD_VERSION:-$(bump_version "$CONTROL_VERSION")}"

sdk_for_label() {
    case "$1" in
        ios16) echo "16.5" ;;
        ios17) echo "17.0" ;;
    esac
}

# Info.plist 短版本必须与 control 一致（版本单一来源）。
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$PLIST_VERSION" != "$CONTROL_VERSION" ]]; then
    echo "error: Info.plist CFBundleShortVersionString (${PLIST_VERSION:-<missing>}) != control Version ($CONTROL_VERSION)" >&2
    exit 1
fi

# ---- 进程级锁 + 版本写回（Metis 同款：全部目标构建成功才写，失败保持原版本） ----
mkdir -p "$ROOT_DIR/packages"
LOCK_DIR="$ROOT_DIR/packages/.build-lock"
if [[ -e "$LOCK_DIR" ]] || ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "error: another build is in progress (lock: $LOCK_DIR)" >&2
    exit 1
fi

persist_version() {
    [[ "$CONTROL_VERSION" == "$VERSION_TO_BUILD" ]] && return 0
    local control_tmp
    control_tmp="$(mktemp "$ROOT_DIR/control.tmp.XXXXXX")" || return 1
    awk -v next_version="$VERSION_TO_BUILD" '
        BEGIN { updated = 0 }
        /^Version:/ { print "Version: " next_version; updated = 1; next }
        { print }
        END { if (!updated) exit 1 }
    ' "$CONTROL_FILE" > "$control_tmp" || { rm -f "$control_tmp"; return 1; }
    mv "$control_tmp" "$CONTROL_FILE" || return 1
    /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString '"$VERSION_TO_BUILD" "$INFO_PLIST" || return 1
    echo "==> version: ${CONTROL_VERSION} -> ${VERSION_TO_BUILD} (control + Info.plist)"
}

finalize() {
    local rc=$?
    trap - EXIT
    if [[ $rc -eq 0 ]]; then
        # 构建链全部成功才落版本号；任何失败保持 control/Info.plist 原值。
        if ! persist_version; then
            echo "error: failed to persist version" >&2
            rc=1
        fi
    fi
    rm -rf "$LOCK_DIR"
    exit "$rc"
}
trap finalize EXIT

check_deb() {
    local deb="$1"
    local extract_dir
    extract_dir="$(mktemp -d /tmp/chargelimiter-pkgcheck.XXXXXX)"
    (
        set -euo pipefail
        trap 'rm -rf "$extract_dir"' EXIT

        # deb 元数据
        local field expected actual
        for field in Package Version Architecture; do
            case "$field" in
                Package) expected="$PACKAGE_ID" ;;
                Version) expected="$VERSION_TO_BUILD" ;;
                Architecture) expected="iphoneos-arm64e" ;;
            esac
            actual="$(dpkg-deb -f "$deb" "$field")"
            if [[ "$actual" != "$expected" ]]; then
                echo "error: unexpected $field in $deb: expected $expected, got $actual" >&2
                exit 1
            fi
        done

        # raw 解包（含 DEBIAN 控制脚本；dpkg-deb -x 只解数据档）
        dpkg-deb -R "$deb" "$extract_dir"

        local app="$extract_dir/Applications/ChargeLimiter.app"
        local daemon_bin="$app/ChargeLimiterDaemon"
        local app_bin="$app/ChargeLimiter"
        local tweak_dylib="$extract_dir/Library/MobileSubstrate/DynamicLibraries/CLThermalSim.dylib"
        local tweak_plist="$extract_dir/Library/MobileSubstrate/DynamicLibraries/CLThermalSim.plist"
        local saver_dylib="$extract_dir/Library/MobileSubstrate/DynamicLibraries/CLChargingSaver.dylib"
        local saver_plist="$extract_dir/Library/MobileSubstrate/DynamicLibraries/CLChargingSaver.plist"
        local launchd_plist="$extract_dir/Library/LaunchDaemons/com.chargelimiter.mod.plist"

        for path in "$app_bin" "$daemon_bin" "$app/Info.plist" "$tweak_dylib" "$tweak_plist" \
            "$saver_dylib" "$saver_plist" \
            "$extract_dir/DEBIAN/postinst" "$extract_dir/DEBIAN/prerm" "$extract_dir/DEBIAN/postrm" \
            "$launchd_plist"; do
            if [[ ! -f "$path" ]]; then
                echo "error: missing in package: $path" >&2
                exit 1
            fi
        done

        if [[ -e "$extract_dir/var/jb" ]]; then
            echo "error: package contains rootless install root var/jb" >&2
            exit 1
        fi

        # 二进制架构：arm64 + arm64e 双切片（RootHide 真机与用户态都需覆盖）
        local bin
        for bin in "$app_bin" "$daemon_bin" "$tweak_dylib" "$saver_dylib"; do
            local archs
            archs="$(lipo -archs "$bin")"
            if [[ " $archs " != *" arm64 "* || " $archs " != *" arm64e "* ]]; then
                echo "error: missing arm64/arm64e slice: $bin ($archs)" >&2
                exit 1
            fi
        done

        # entitlements：application-identifier 必须匹配 bundle id；禁用项不得出现
        local ent
        for bin in "$app_bin" "$daemon_bin"; do
            if ! ent="$(ldid -e "$bin" 2>/dev/null)"; then
                echo "error: failed to extract entitlements: $bin" >&2
                exit 1
            fi
            echo "$ent" | grep -F -q "<string>com.chargelimiter.mod</string>" || {
                echo "error: application-identifier mismatch in $bin" >&2
                exit 1
            }
            echo "$ent" | grep -E -q "$BANNED_ENT_REGEX" && {
                echo "error: banned entitlement found in $bin" >&2
                exit 1
            }
        done

        # 链接路径守卫：任何 load command / rpath 残留 /var/jb 都不是合法 roothide 包
        for bin in "$app_bin" "$daemon_bin" "$tweak_dylib" "$saver_dylib"; do
            if otool -L "$bin" 2>/dev/null | grep -F -q "/var/jb"; then
                echo "error: residual /var/jb load path in $bin" >&2
                exit 1
            fi
            if otool -l "$bin" 2>/dev/null | awk '
                /^[^ ]/ { in_rpath = 0 }
                $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
                in_rpath && $1 == "path" { print $2; in_rpath = 0 }
            ' | grep -F -q "/var/jb"; then
                echo "error: residual /var/jb rpath in $bin" >&2
                exit 1
            fi
        done

        # App Info 与 control 版本/bundle id 一致
        local bundle_id bundle_version
        bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
        bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")"
        if [[ "$bundle_id" != "$PACKAGE_ID" || "$bundle_version" != "$CONTROL_VERSION" ]]; then
            echo "error: app Info.plist mismatch: id=$bundle_id ver=$bundle_version" >&2
            exit 1
        fi

        # launchd plist / DEBIAN 脚本与 roothide 安装约定一致
        local program
        program="$(/usr/libexec/PlistBuddy -c 'Print :Program' "$launchd_plist")"
        if [[ "$program" != "/Applications/ChargeLimiter.app/ChargeLimiterDaemon" ]]; then
            echo "error: unexpected launchd Program path: $program" >&2
            exit 1
        fi
        grep -F -q 'APP_DIR="/Applications/ChargeLimiter.app"' "$extract_dir/DEBIAN/postinst" || {
            echo "error: postinst APP_DIR marker missing" >&2
            exit 1
        }
        grep -F -q 'DAEMON_PLIST="/Library/LaunchDaemons/com.chargelimiter.mod.plist"' "$extract_dir/DEBIAN/postinst" || {
            echo "error: postinst DAEMON_PLIST marker missing" >&2
            exit 1
        }
        grep -F -q 'APP_DIR="/Applications/ChargeLimiter.app"' "$extract_dir/DEBIAN/prerm" || {
            echo "error: prerm APP_DIR marker missing" >&2
            exit 1
        }

        # 宿主元数据不得混入
        if find "$extract_dir" \( -name .DS_Store -o -name __MACOSX -o -name '._*' \) | grep -q .; then
            echo "error: host metadata found in $deb" >&2
            exit 1
        fi

        echo "==> package check OK: $(basename "$deb")"
    )
}

build_one() {
    local label="$1"
    local sdk_version
    sdk_version="$(sdk_for_label "$label")"
    local sdk_path="$THEOS/sdks/iPhoneOS${sdk_version}.sdk"
    if [[ ! -d "$sdk_path" ]]; then
        echo "error: required SDK not found: $sdk_path" >&2
        exit 1
    fi

    echo "==> Building $label (v$VERSION_TO_BUILD) with iPhoneOS${sdk_version}.sdk (deployment ${DEPLOYMENT_TARGET})"

    mkdir -p "$ROOT_DIR/packages"
    find "$ROOT_DIR/packages" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true
    "$MAKE_BIN" -C "$ROOT_DIR" clean >/dev/null

    (
        cd "$ROOT_DIR"
        THEOS_PACKAGE_SCHEME=roothide \
            TARGET="iphone:clang:${sdk_version}:${DEPLOYMENT_TARGET}" \
            "$MAKE_BIN" package FINALPACKAGE=1 PACKAGE_VERSION="$VERSION_TO_BUILD"
    )

    local package_path
    package_path="$(find "$ROOT_DIR/packages" -maxdepth 1 -type f -name "${PACKAGE_ID}_*.deb" -print -quit)"
    if [[ -z "$package_path" ]]; then
        echo "error: package was not produced for $label" >&2
        exit 1
    fi

    # 产物落 packages/<label>/（Metis 同款）：版本在文件名里区分；
    # 先清空该 label 目录旧 deb——本地只保留最新一次构建
    local output_dir="$ROOT_DIR/packages/$label"
    local output_path="$output_dir/${PACKAGE_ID}_${VERSION_TO_BUILD}_${label}_iphoneos-arm64e.deb"
    mkdir -p "$output_dir"
    find "$output_dir" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true
    mv "$package_path" "$output_path"
    check_deb "$output_path"
    echo "==> Output: $output_path"
}

case "$BUILD_TARGET" in
    ios16) build_one ios16 ;;
    ios17) build_one ios17 ;;
    all) build_one ios16; build_one ios17 ;;
esac

echo "==> build complete: ${VERSION_TO_BUILD}"
