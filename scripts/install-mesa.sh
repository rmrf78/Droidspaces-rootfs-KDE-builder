#!/usr/bin/env bash
set -euo pipefail

# Install the ARM64 Mesa build published by mesa-for-android-container.
# The archive format and package manager are selected from /etc/os-release.
readonly MESA_REPOSITORY="lfdevs/mesa-for-android-container"
readonly MESA_API_URL="https://api.github.com/repos/${MESA_REPOSITORY}/releases/latest"
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly GHPROXY_NET_RELEASE_URL="https://ghproxy.net/https://github.com"
readonly APT_HOLD_PREFERENCES="/etc/apt/preferences.d/hold-anland-package"
readonly DNF_CONFIG="/etc/dnf/dnf.conf"
readonly DNF_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly DNF_MANAGED_END="# END install-mesa package holds"
readonly PACMAN_CONFIG="/etc/pacman.conf"
readonly PACMAN_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly PACMAN_MANAGED_END="# END install-mesa package holds"
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"
readonly MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((2 * 1024 * 1024 * 1024))

UI_LANG="en"
TARGET=""
PACKAGE_MANAGER=""
ASSET_PATTERN=""
ARCHIVE_KIND=""
WORK_DIR=""
ARCHIVE_FILE=""
ARCHIVE_NAME=""
RELEASE_TAG=""
DOWNLOAD_URL=""
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
OFFICIAL_DOWNLOAD_URL=""
OFFICIAL_ARCHIVE_DIGEST=""
EXPECTED_ARCHIVE_SHA256=""
MESA_PACKAGE_NAMES=()

detect_language() {
    local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
    locale_name="${locale_name,,}"
    if [[ "$locale_name" == zh* ]]; then
        UI_LANG="zh"
    fi
}

msg() {
    if [[ "$UI_LANG" == "zh" ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

log() {
    printf '[install-mesa] %s\n' "$(msg "$1" "$2")"
}

die() {
    printf '[install-mesa] %s: %s\n' \
        "$(msg '错误' 'Error')" "$(msg "$1" "$2")" >&2
    exit 1
}

usage() {
    cat <<EOF
$(msg '用法' 'Usage'): $0

  -1, --1       $(msg '使用 GitHub 并跳过测速。' 'Use GitHub and skip latency checks.')
  -2, --2       $(msg '使用 gh-proxy.com 并跳过测速。' 'Use gh-proxy.com and skip latency checks.')
  -3, --3       $(msg '使用 ghproxy.net 并跳过测速。' 'Use ghproxy.net and skip latency checks.')
  -h, --help    $(msg '显示此帮助。' 'Show this help.')

$(msg '未指定下载源时，将测试三个源并提示选择。' 'Without a source option, all three sources are probed before prompting.')
EOF
}

set_download_source_argument() {
    local source="$1"

    if [[ -n "$DOWNLOAD_SOURCE" && "$DOWNLOAD_SOURCE" != "$source" ]]; then
        die "不能同时指定多个下载源。" "Conflicting download-source options were provided."
    fi
    DOWNLOAD_SOURCE="$source"
    SKIP_SOURCE_PROBE=true
}

parse_arguments() {
    local argument

    for argument in "$@"; do
        case "$argument" in
            -1|--1)
                set_download_source_argument "1"
                ;;
            -2|--2)
                set_download_source_argument "2"
                ;;
            -3|--3)
                set_download_source_argument "3"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "不支持的参数：${argument}。可用参数为 -1/--1、-2/--2、-3/--3。" \
                    "Unsupported argument: ${argument}. Valid arguments are -1/--1, -2/--2, and -3/--3."
                ;;
        esac
    done
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_root() {
    if (( EUID == 0 )); then
        return
    fi

    command -v sudo >/dev/null 2>&1 || die \
        "请使用 root 账户运行此脚本。" "Please run this script as root."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."

    local script_path="${BASH_SOURCE[0]}"
    if [[ "$script_path" != /* ]]; then
        script_path="$PWD/$script_path"
    fi
    exec sudo --preserve-env=LANG,LC_ALL,LC_MESSAGES -- bash "$script_path" "$@"
}

detect_target() {
    [[ -r /etc/os-release ]] || die \
        "无法读取 /etc/os-release。" "Unable to read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || die \
        "/etc/os-release 缺少 ID。" "/etc/os-release does not contain ID."

    local distro_id="${ID,,}"
    local version_id="${VERSION_ID:-}"
    local system_name="${PRETTY_NAME:-$distro_id${version_id:+ $version_id}}"

    TARGET=""
    PACKAGE_MANAGER=""
    ASSET_PATTERN=""
    ARCHIVE_KIND=""

    case "$distro_id" in
        arch|archarm|archlinux)
            TARGET="Arch Linux"
            PACKAGE_MANAGER="pacman"
            ARCHIVE_KIND="tar"
            ASSET_PATTERN='^mesa-for-android-container_[^/]+_archlinux_arm64\.tar$'
            ;;
        debian)
            case "$version_id" in
                13*)
                    TARGET="Debian 13"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_debian_trixie_arm64\.tar\.gz$'
                    ;;
                *)
                    die "不支持当前系统 ${system_name}。仅支持 Debian 13。" \
                        "Unsupported system: ${system_name}. Only Debian 13 is supported."
                    ;;
            esac
            ;;
        ubuntu)
            case "$version_id" in
                24.04*)
                    TARGET="Ubuntu 24.04"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_ubuntu_noble_arm64\.tar\.gz$'
                    ;;
                25.10*)
                    TARGET="Ubuntu 25.10"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_ubuntu_questing_arm64\.tar\.gz$'
                    ;;
                26.04*)
                    TARGET="Ubuntu 26.04"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_ubuntu_resolute_arm64\.tar\.gz$'
                    ;;
                *)
                    die "不支持当前系统 ${system_name}。仅支持 Ubuntu 24.04、25.10、26.04。" \
                        "Unsupported system: ${system_name}. Only Ubuntu 24.04, 25.10, and 26.04 are supported."
                    ;;
            esac
            ;;
        fedora)
            case "$version_id" in
                43*)
                    TARGET="Fedora 43"
                    PACKAGE_MANAGER="dnf"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_fedora_43_arm64\.tar\.gz$'
                    ;;
                44*)
                    TARGET="Fedora 44"
                    PACKAGE_MANAGER="dnf"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_fedora_44_arm64\.tar\.gz$'
                    ;;
                *)
                    die "不支持当前系统 ${system_name}。仅支持 Fedora 43/44。" \
                        "Unsupported system: ${system_name}. Only Fedora 43/44 are supported."
                    ;;
            esac
            ;;
        *)
            die "不支持当前系统 ${system_name}。" "Unsupported system: ${system_name}."
            ;;
    esac

    log "已识别系统: ${system_name} -> ${TARGET}" \
        "Detected system: ${system_name} -> ${TARGET}"
}

check_architecture() {
    local architecture

    architecture="$(uname -m)"
    case "$architecture" in
        aarch64|arm64) ;;
        *)
            die "预编译 Mesa 包仅支持 ARM64/aarch64，当前架构为 ${architecture}。" \
                "The prebuilt Mesa packages support ARM64/aarch64 only; current architecture is ${architecture}."
            ;;
    esac
}

require_commands() {
    local command_name

    for command_name in awk cat chmod cp dirname grep install mktemp rm sed sort stat tar uname; do
        command -v "$command_name" >/dev/null 2>&1 || die \
            "缺少运行安装器所需的命令：${command_name}。" \
            "The installer requires the missing command: ${command_name}."
    done
    command -v jq >/dev/null 2>&1 || die \
        "未找到 jq，无法解析 Mesa Release。" "jq was not found; the Mesa Release cannot be parsed."

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        die "未找到 curl 或 wget，无法下载 Mesa。" \
            "Neither curl nor wget was found; Mesa cannot be downloaded."
    fi

    case "$PACKAGE_MANAGER" in
        apt)
            command -v ldconfig >/dev/null 2>&1 || die \
                "未找到 ldconfig。" "ldconfig was not found."
            ;;
        dnf)
            command -v ldconfig >/dev/null 2>&1 || die \
                "未找到 ldconfig。" "ldconfig was not found."
            ;;
        pacman)
            command -v pacman >/dev/null 2>&1 || die \
                "未找到 pacman。" "pacman was not found."
            [[ -r "$PACMAN_CONFIG" ]] || die \
                "无法读取 ${PACMAN_CONFIG}。" "Unable to read ${PACMAN_CONFIG}."
            ;;
    esac
}

download_stdout() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 120 "$url"
    else
        wget -q --tries=5 --timeout=20 --waitretry=3 --retry-connrefused -O - "$url"
    fi
}

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 300 \
            --continue-at - "$url" -o "$destination"
    else
        wget --continue --tries=5 --timeout=20 --waitretry=3 --retry-connrefused \
            -O "$destination" "$url"
    fi
}

resolve_release_asset() {
    local metadata asset_json expected_download_url

    log "正在读取 Mesa 最新 Release..." "Reading the latest Mesa Release..."
    metadata="$(download_stdout "$MESA_API_URL")" || die \
        "无法获取 Mesa Release 信息，可能触发了 GitHub API 限制。" \
        "Unable to fetch Mesa Release metadata; the GitHub API may be rate-limited."

    asset_json="$(jq -ce --arg pattern "$ASSET_PATTERN" '
        if (.draft // false) or (.prerelease // false) then
            error("latest release is not a stable release")
        else
            [.assets[]? | select((.name // "") | test($pattern))]
            | if length == 1 then .[0] else error("asset match is not unique") end
        end
    ' <<< "$metadata" 2>/dev/null || true)"
    [[ -n "$asset_json" && "$asset_json" != "null" ]] || die \
        "最新 Release 没有 ${TARGET} 对应的 ARM64 Mesa 包。" \
        "The latest Release has no matching ARM64 Mesa package for ${TARGET}."

    RELEASE_TAG="$(jq -er '.tag_name | select(type == "string" and length > 0)' \
        <<< "$metadata" 2>/dev/null)" || die \
        "Release 返回了无效的标签。" "The Release returned an invalid tag."
    [[ "$RELEASE_TAG" =~ ^[A-Za-z0-9._+~-]+$ && \
        "$RELEASE_TAG" != "." && "$RELEASE_TAG" != *..* ]] || die \
        "Release 返回了无效的标签。" "The Release returned an invalid tag."
    ARCHIVE_NAME="$(jq -er '.name // empty' <<< "$asset_json" 2>/dev/null)" || die \
        "Release 返回了无效的包名。" "The Release returned an invalid asset name."
    OFFICIAL_DOWNLOAD_URL="$(jq -er '.browser_download_url // empty' \
        <<< "$asset_json" 2>/dev/null)" || die \
        "Release 返回了无效的下载地址。" "The Release returned an invalid download URL."
    OFFICIAL_ARCHIVE_DIGEST="$(jq -r '.digest // empty' \
        <<< "$asset_json" 2>/dev/null)" || die \
        "Release 返回了无效的 SHA-256 校验值。" \
        "The Release returned an invalid SHA-256 digest."

    expected_download_url="${GITHUB_RELEASE_URL}/${MESA_REPOSITORY}/releases/download/${RELEASE_TAG}/${ARCHIVE_NAME}"
    [[ "$OFFICIAL_DOWNLOAD_URL" == "$expected_download_url" ]] || die \
        "Release 返回了无效的下载地址。" "The Release returned an invalid download URL."
    [[ "$ARCHIVE_NAME" =~ $ASSET_PATTERN ]] || die \
        "Release 包名与目标发行版不匹配。" "The Release asset name does not match the target distribution."
    log "已选择 Mesa 包: ${ARCHIVE_NAME}" "Selected Mesa asset: ${ARCHIVE_NAME}"
}

download_source_name() {
    case "$1" in
        1) printf 'GitHub' ;;
        2) printf 'gh-proxy.com' ;;
        3) printf 'ghproxy.net' ;;
        *) return 1 ;;
    esac
}

download_url_for_source() {
    local source="$1"
    local source_url official_path

    case "$source" in
        1) source_url="$GITHUB_RELEASE_URL" ;;
        2) source_url="$GH_PROXY_RELEASE_URL" ;;
        3) source_url="$GHPROXY_NET_RELEASE_URL" ;;
        *) return 1 ;;
    esac

    official_path="${OFFICIAL_DOWNLOAD_URL#"$GITHUB_RELEASE_URL"}"
    [[ "$official_path" == "/${MESA_REPOSITORY}/releases/download/"* ]] || return 1
    printf '%s%s' "$source_url" "$official_path"
}

format_latency() {
    local seconds="$1"

    awk -v seconds="$seconds" 'BEGIN { printf "%d ms", (seconds * 1000) + 0.5 }'
}

probe_download_source() {
    local source="$1"
    local probe_url latency started finished probe_status=0
    local -a probe_command

    probe_url="$(download_url_for_source "$source")" || return 1
    # Probe only the first byte because Mesa assets are much larger than the
    # manifest used by install-anland-kde.sh for the same latency check.
    if command -v curl >/dev/null 2>&1; then
        if latency="$(curl -fsSL --range 0-0 \
            --connect-timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" \
            --max-time "$SOURCE_PROBE_TIMEOUT_SECONDS" --output /dev/null \
            --write-out '%{time_total}' "$probe_url" 2>/dev/null)"; then
            if awk -v seconds="$latency" -v limit="$SOURCE_PROBE_TIMEOUT_SECONDS" \
                'BEGIN { exit (seconds < limit ? 0 : 1) }'; then
                format_latency "$latency"
                return
            fi
            printf '%s' "$(msg '超时' 'timeout')"
            return
        else
            probe_status=$?
        fi
    elif command -v wget >/dev/null 2>&1; then
        command -v timeout >/dev/null 2>&1 || \
            die "wget 测试下载源需要 timeout 命令以限制为 ${SOURCE_PROBE_TIMEOUT_SECONDS} 秒。" \
                "Testing download sources with wget requires timeout to enforce the ${SOURCE_PROBE_TIMEOUT_SECONDS}-second limit."
        started="$(date +%s%3N 2>/dev/null || true)"
        probe_command=(wget -q --header='Range: bytes=0-0' --tries=1 \
            --timeout="$SOURCE_PROBE_TIMEOUT_SECONDS" -O /dev/null "$probe_url")
        probe_command=(timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" "${probe_command[@]}")
        if "${probe_command[@]}"; then
            finished="$(date +%s%3N 2>/dev/null || true)"
            if [[ "$started" =~ ^[0-9]+$ && "$finished" =~ ^[0-9]+$ ]]; then
                if (( finished - started < SOURCE_PROBE_TIMEOUT_SECONDS * 1000 )); then
                    printf '%d ms' "$((finished - started))"
                else
                    printf '%s' "$(msg '超时' 'timeout')"
                fi
            else
                printf '%s' "$(msg '可用' 'available')"
            fi
            return
        else
            probe_status=$?
        fi
    else
        die "未找到 curl 或 wget，无法测试下载源。" \
            "Neither curl nor wget was found; download sources cannot be tested."
    fi

    if (( probe_status == 28 || probe_status == 124 )); then
        printf '%s' "$(msg '超时' 'timeout')"
    else
        printf '%s' "$(msg '不可用' 'unavailable')"
    fi
}

select_download_source() {
    local source latency choice

    if [[ "$SKIP_SOURCE_PROBE" == true ]]; then
        log "已按参数选择 $(download_source_name "$DOWNLOAD_SOURCE")，跳过延迟测试。" \
            "Selected $(download_source_name "$DOWNLOAD_SOURCE") from the command line; skipping latency checks."
        return
    fi

    log "正在测试下载源延迟（达到 ${SOURCE_PROBE_TIMEOUT_SECONDS} 秒视为超时）..." \
        "Testing download-source latency (timeouts at ${SOURCE_PROBE_TIMEOUT_SECONDS} seconds)..."
    for source in 1 2 3; do
        latency="$(probe_download_source "$source")"
        printf '%s. %s %s: %s\n' "$source" "$(download_source_name "$source")" \
            "$(msg '延迟' 'latency')" "$latency"
    done

    while :; do
        printf '%s' "$(msg '请输入下载源编号 [1-3]: ' 'Choose a download source [1-3]: ')"
        if ! IFS= read -r choice; then
            die "无法读取下载源选择。请使用 -1/--1、-2/--2 或 -3/--3 指定下载源。" \
                "Unable to read a download-source choice. Specify -1/--1, -2/--2, or -3/--3."
        fi
        case "$choice" in
            1|2|3)
                DOWNLOAD_SOURCE="$choice"
                return
                ;;
            *)
                log "请输入 1、2 或 3。" "Enter 1, 2, or 3."
                ;;
        esac
    done
}

resolve_expected_archive_sha256() {
    EXPECTED_ARCHIVE_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "1" ]]; then
        return
    fi

    command -v sha256sum >/dev/null 2>&1 || die \
        "选择第三方镜像需要 sha256sum 来校验下载文件。" \
        "Selecting a third-party mirror requires sha256sum to verify the downloaded file."
    if [[ ! "$OFFICIAL_ARCHIVE_DIGEST" =~ ^sha256:([0-9A-Fa-f]{64})$ ]]; then
        die "GitHub Release 未提供 ${ARCHIVE_NAME} 的有效 SHA-256 校验值，拒绝使用第三方镜像包。" \
            "GitHub Release did not provide a valid SHA-256 digest for ${ARCHIVE_NAME}; refusing the third-party mirror package."
    fi
    EXPECTED_ARCHIVE_SHA256="${BASH_REMATCH[1],,}"
}

validate_release_asset_checksum() {
    local asset_file="$1"
    local actual_checksum

    if ! actual_checksum="$(sha256sum "$asset_file" | awk '{print $1}')" || \
        ! [[ "$actual_checksum" =~ ^[0-9a-f]{64}$ ]] || \
        [[ "$actual_checksum" != "$EXPECTED_ARCHIVE_SHA256" ]]; then
        return 1
    fi
}

validate_archive_size() {
    local archive_size="$1"

    [[ -f "$archive_size" ]] || die \
        "下载文件不存在。" "The downloaded file does not exist."
    local size
    size="$(stat -c '%s' "$archive_size")" || die \
        "无法读取下载文件大小。" "Unable to read the downloaded file size."
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || die \
        "下载文件为空。" "The downloaded file is empty."
    (( size <= MAX_ARCHIVE_BYTES )) || die \
        "下载包超过允许的大小。" "The downloaded archive exceeds the allowed size."
}

validate_archive_paths() {
    local archive_file="$1"
    local entry
    local total_size=0
    local entry_size
    local listing_file="$WORK_DIR/archive.list"
    local verbose_listing_file="$WORK_DIR/archive.verbose"
    local entry_sizes_file="$WORK_DIR/archive.sizes"

    if [[ "$ARCHIVE_KIND" == "tar.gz" ]]; then
        if ! tar -tzf "$archive_file" > "$listing_file"; then
            die "无法读取下载包内容。" "Unable to read the downloaded archive contents."
        fi
        [[ -s "$listing_file" ]] || die \
            "下载包中没有文件。" "The downloaded archive contains no files."
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            case "$entry" in
                /*|.|..|../*|*/../*|*/..)
                    die "下载包包含不安全路径：${entry}" \
                        "The downloaded archive contains an unsafe path: ${entry}"
                    ;;
            esac
        done < "$listing_file"

        if ! LC_ALL=C tar -tvzf "$archive_file" > "$verbose_listing_file"; then
            die "无法读取下载包条目大小。" "Unable to read the downloaded archive entry sizes."
        fi
        awk '$3 ~ /^[0-9]+$/ { print $3 }' \
            "$verbose_listing_file" > "$entry_sizes_file"
        [[ -s "$entry_sizes_file" ]] || die \
            "下载包中没有可校验的条目。" "The downloaded archive has no verifiable entries."
        while IFS= read -r entry_size; do
            [[ "$entry_size" =~ ^[0-9]+$ ]] || die \
                "无法读取下载包条目大小。" "Unable to read an archive entry size."
            total_size=$((total_size + entry_size))
            (( total_size <= MAX_EXTRACTED_BYTES )) || die \
                "下载包解压后超过允许的大小。" \
                "The downloaded archive exceeds the allowed extracted size."
        done < "$entry_sizes_file"
    else
        if ! tar -tf "$archive_file" > "$listing_file"; then
            die "无法读取 Arch 下载包内容。" "Unable to read the Arch archive contents."
        fi
        [[ -s "$listing_file" ]] || die \
            "Arch 下载包中没有文件。" "The Arch archive contains no files."
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            entry="${entry#./}"
            case "$entry" in
                /*|.|..|../*|*/../*|*/..)
                    die "Arch 下载包包含不安全路径：${entry}" \
                        "The Arch archive contains an unsafe path: ${entry}"
                    ;;
                ""|*/)
                    ;;
                *.pkg.tar.*|*.sig)
                    [[ "$entry" != */* ]] || die \
                        "Arch 下载包包含不安全路径：${entry}" \
                        "The Arch archive contains an unsafe path: ${entry}"
                    ;;
                *)
                    die "Arch 下载包包含未知文件：${entry}" \
                        "The Arch archive contains an unexpected file: ${entry}"
                    ;;
            esac
        done < "$listing_file"

        if ! LC_ALL=C tar -tvf "$archive_file" > "$verbose_listing_file"; then
            die "无法读取 Arch 下载包条目大小。" \
                "Unable to read the Arch archive entry sizes."
        fi
        awk '$3 ~ /^[0-9]+$/ { print $3 }' \
            "$verbose_listing_file" > "$entry_sizes_file"
        [[ -s "$entry_sizes_file" ]] || die \
            "Arch 下载包中没有可校验的条目。" \
            "The Arch archive has no verifiable entries."
        while IFS= read -r entry_size; do
            [[ "$entry_size" =~ ^[0-9]+$ ]] || die \
                "无法读取 Arch 下载包条目大小。" "Unable to read an Arch archive entry size."
            total_size=$((total_size + entry_size))
            (( total_size <= MAX_EXTRACTED_BYTES )) || die \
                "Arch 下载包解压后超过允许的大小。" \
                "The Arch archive exceeds the allowed extracted size."
        done < "$entry_sizes_file"
    fi
}

configure_apt_holds() {
    local preferences_file="$APT_HOLD_PREFERENCES"

    install -d -m 0755 "$(dirname "$preferences_file")"
    cat > "$preferences_file" <<'EOF'
# /etc/apt/preferences.d/hold-anland-package

Package: xwayland libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers kwin-common kwin-data kwin-wayland libkwin6
Pin: release *
Pin-Priority: -1
EOF
    [[ -s "$preferences_file" ]] || die \
        "无法写入 APT 版本锁定配置。" "Unable to write the APT version hold configuration."
    log "已写入 APT 软件包锁定: ${preferences_file}" \
        "Wrote the APT package hold configuration: ${preferences_file}"
}

rewrite_without_managed_block() {
    local input_file="$1"
    local output_file="$2"
    local begin_marker="$3"
    local end_marker="$4"

    awk -v begin="$begin_marker" -v end="$end_marker" '
        $0 == begin {
            if (inside) {
                invalid = 1
            }
            begins++
            inside = 1
            next
        }
        $0 == end {
            if (!inside) {
                invalid = 1
            }
            ends++
            inside = 0
            next
        }
        !inside { print }
        END {
            if (invalid || inside || begins != ends || begins > 1) {
                exit 1
            }
        }
    ' "$input_file" > "$output_file"
}

write_dnf_config_with_managed_block() {
    local input_file="$1"
    local output_file="$2"
    local stripped_file="$WORK_DIR/dnf.conf.stripped"
    local excluded_packages="mesa*,kwin*,xorg-x11-server-Xwayland*"

    if [[ -e "$SYSTEMD257_STATE" ]]; then
        excluded_packages+=",systemd*"
    fi

    rewrite_without_managed_block \
        "$input_file" "$stripped_file" "$DNF_MANAGED_BEGIN" "$DNF_MANAGED_END" || return 1

    # DNF binds the yum-compatible exclude alias and excludepkgs to the same
    # append-list. Keeping different keys avoids duplicate-key replacement by
    # the INI parser while composing with Anland's excludepkgs rule.
    awk -v begin="$DNF_MANAGED_BEGIN" -v end="$DNF_MANAGED_END" \
        -v excludes="$excluded_packages" '
        function contains(value, wanted, normalized, count, tokens, i) {
            normalized = value
            gsub(/,/, " ", normalized)
            count = split(normalized, tokens, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                if (tokens[i] == wanted) {
                    return 1
                }
            }
            return 0
        }
        function merge_excludes(line, equals, value, trimmed, separator, count, wanted, i) {
            equals = index(line, "=")
            value = substr(line, equals + 1)
            trimmed = value
            sub(/[[:space:]]+$/, "", trimmed)
            separator = (trimmed == "" || trimmed ~ /,$/) ? "" : ","
            count = split(excludes, wanted, ",")
            for (i = 1; i <= count; i++) {
                if (!contains(value, wanted[i])) {
                    value = value separator wanted[i]
                    separator = ","
                }
            }
            return substr(line, 1, equals) value
        }
        function write_block() {
            print begin
            print "exclude=" excludes
            print end
        }
        /^\[main\][[:space:]]*$/ {
            in_main = 1
            saw_main = 1
            print
            next
        }
        /^\[[^]]+\][[:space:]]*$/ {
            if (in_main && !saw_exclude) {
                write_block()
            }
            in_main = 0
            print
            next
        }
        {
            if (in_main && $0 ~ /^[[:space:]]*exclude[[:space:]]*=/) {
                print merge_excludes($0)
                saw_exclude = 1
                next
            }
            print
        }
        END {
            if (in_main && !saw_exclude) {
                write_block()
            }
            if (!saw_main) {
                print "[main]"
                write_block()
            }
        }
    ' "$stripped_file" > "$output_file"
}

configure_dnf_holds() {
    local temporary_config="$WORK_DIR/dnf.conf.locked"

    install -d -m 0755 "$(dirname "$DNF_CONFIG")"
    if [[ ! -e "$DNF_CONFIG" ]]; then
        install -m 0644 /dev/null "$DNF_CONFIG"
    fi
    [[ -f "$DNF_CONFIG" ]] || die \
        "DNF 配置不是普通文件：${DNF_CONFIG}。" \
        "The DNF configuration is not a regular file: ${DNF_CONFIG}."

    if ! write_dnf_config_with_managed_block "$DNF_CONFIG" "$temporary_config"; then
        die "DNF 锁定配置中的托管标记无效。" \
            "The managed markers in the DNF hold configuration are invalid."
    fi
    install -m 0644 "$temporary_config" "$DNF_CONFIG" || die \
        "无法写入 DNF 软件包锁定配置。" "Unable to write the DNF package hold configuration."
    log "已写入 DNF 软件包锁定: ${DNF_CONFIG}" \
        "Wrote the DNF package hold configuration: ${DNF_CONFIG}"
}

write_pacman_config_with_managed_block() {
    local input_file="$1"
    local output_file="$2"
    local packages_line="$3"
    local stripped_file="$WORK_DIR/pacman.conf.stripped"

    rewrite_without_managed_block \
        "$input_file" "$stripped_file" "$PACMAN_MANAGED_BEGIN" "$PACMAN_MANAGED_END" || return 1

    awk -v begin="$PACMAN_MANAGED_BEGIN" -v end="$PACMAN_MANAGED_END" \
        -v packages="$packages_line" '
        function write_block() {
            print begin
            print "IgnorePkg = " packages
            print end
        }
        /^\[options\][[:space:]]*$/ {
            in_options = 1
            saw_options = 1
            print
            next
        }
        /^\[[^]]+\][[:space:]]*$/ {
            if (in_options && !wrote_block) {
                write_block()
                wrote_block = 1
            }
            in_options = 0
            print
            next
        }
        { print }
        END {
            if (in_options && !wrote_block) {
                write_block()
            }
            if (!saw_options) {
                exit 2
            }
        }
    ' "$stripped_file" > "$output_file"
}

configure_pacman_holds() {
    local package packages_line
    local temporary_config="$WORK_DIR/pacman.conf.locked"
    local sorted_packages_file="$WORK_DIR/pacman-holds.list"
    local -a packages=("$@" 'kwin*' xorg-xwayland)
    local -a unique_packages=()

    if [[ -e "$SYSTEMD257_STATE" ]]; then
        packages+=(systemd systemd-libs systemd-sysvcompat)
    fi
    if ! printf '%s\n' "${packages[@]}" | sort -u > "$sorted_packages_file"; then
        die "无法整理 Arch 软件包锁定列表。" "Unable to prepare the Arch package hold list."
    fi
    mapfile -t unique_packages < "$sorted_packages_file"
    ((${#unique_packages[@]} > 0)) || die \
        "没有可锁定的 Arch 软件包。" "There are no Arch packages to hold."
    for package in "${unique_packages[@]}"; do
        [[ "$package" =~ ^[[:alnum:]@._+*-]+$ ]] || die \
            "Arch 软件包名无效：${package}。" "Invalid Arch package name: ${package}."
    done
    printf -v packages_line '%s ' "${unique_packages[@]}"
    packages_line="${packages_line% }"

    if ! write_pacman_config_with_managed_block \
        "$PACMAN_CONFIG" "$temporary_config" "$packages_line"; then
        die "pacman.conf 缺少 [options] 段，或锁定配置中的托管标记无效。" \
            "pacman.conf has no [options] section, or its managed hold markers are invalid."
    fi
    install -m 0644 "$temporary_config" "$PACMAN_CONFIG" || die \
        "无法写入 Pacman 软件包锁定配置。" \
        "Unable to write the Pacman package hold configuration."
    log "已写入 Pacman 软件包锁定: ${PACMAN_CONFIG}" \
        "Wrote the Pacman package hold configuration: ${PACMAN_CONFIG}"
}

configure_package_holds() {
    case "$PACKAGE_MANAGER" in
        apt)
            configure_apt_holds
            ;;
        dnf)
            configure_dnf_holds
            ;;
        pacman)
            configure_pacman_holds "${MESA_PACKAGE_NAMES[@]}"
            ;;
        *)
            die "内部错误：无法为 ${PACKAGE_MANAGER} 配置软件包锁定。" \
                "Internal error: cannot configure package holds for ${PACKAGE_MANAGER}."
            ;;
    esac
}

install_arch_packages() {
    local pacman_config
    local entry
    local package_listing_file="$WORK_DIR/arch-package-files.list"
    local package_names_file="$WORK_DIR/arch-package-names.list"
    local -a package_files=()

    pacman_config="$WORK_DIR/pacman.conf"
    cp -p "$PACMAN_CONFIG" "$pacman_config"

    # The Mesa Release packages are intentionally unsigned. Restrict the
    # relaxed signature policy to this temporary pacman configuration.
    if grep -Eq '^[[:space:]]*#?[[:space:]]*SigLevel[[:space:]]*=' "$pacman_config"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*SigLevel[[:space:]]*=.*/SigLevel = Never/' "$pacman_config"
    elif grep -qE '^\[options\][[:space:]]*$' "$pacman_config"; then
        sed -i '/^\[options\][[:space:]]*$/a SigLevel = Never' "$pacman_config"
    else
        die "pacman.conf 缺少 [options] 段。" "pacman.conf has no [options] section."
    fi

    if ! tar -tf "$ARCHIVE_FILE" > "$package_listing_file"; then
        die "无法读取 Arch 下载包内容。" "Unable to read the Arch archive contents."
    fi
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        entry="${entry#./}"
        case "$entry" in
            *.pkg.tar.*)
                package_files+=("$WORK_DIR/$entry")
                ;;
        esac
    done < "$package_listing_file"
    ((${#package_files[@]} > 0)) || die \
        "Arch 下载包中没有可安装的软件包。" "The Arch archive has no installable packages."
    if ! pacman -Qq -p "${package_files[@]}" | sort -u > "$package_names_file"; then
        die "无法读取 Arch Mesa 包名。" "Could not determine the Arch Mesa package names."
    fi
    [[ -s "$package_names_file" ]] || die \
        "无法读取 Arch Mesa 包名。" "Could not determine the Arch Mesa package names."
    mapfile -t MESA_PACKAGE_NAMES < "$package_names_file"
    ((${#MESA_PACKAGE_NAMES[@]} > 0)) || die \
        "无法读取 Arch Mesa 包名。" "Could not determine the Arch Mesa package names."

    log "正在安装 ${#package_files[@]} 个 Arch Mesa 包..." \
        "Installing ${#package_files[@]} Arch Mesa packages..."
    pacman --config "$pacman_config" -U --noconfirm "${package_files[@]}"
}

install_tar_gz() {
    log "正在解压 ${TARGET} Mesa 驱动..." "Extracting the ${TARGET} Mesa driver..."
    tar --extract --gzip --file "$ARCHIVE_FILE" --directory / \
        --no-same-owner --keep-directory-symlink
    ldconfig
}

install_mesa() {
    log "正在下载并安装最新版 Mesa 驱动..." \
        "Downloading and installing the latest Mesa driver..."
    resolve_release_asset
    select_download_source
    resolve_expected_archive_sha256
    DOWNLOAD_URL="$(download_url_for_source "$DOWNLOAD_SOURCE")" || die \
        "无法构造所选下载源的地址。" "Could not build the selected download-source URL."
    WORK_DIR="$(mktemp -d -t install-mesa.XXXXXXXX)" || die \
        "无法创建临时目录。" "Unable to create a temporary directory."
    chmod 0700 "$WORK_DIR" || die \
        "无法保护临时目录。" "Unable to secure the temporary directory."
    ARCHIVE_FILE="$WORK_DIR/$ARCHIVE_NAME"

    log "正在从 $(download_source_name "$DOWNLOAD_SOURCE") 下载 ${ARCHIVE_NAME}..." \
        "Downloading ${ARCHIVE_NAME} from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$DOWNLOAD_URL" "$ARCHIVE_FILE" || die \
        "Mesa 驱动下载失败。" "The Mesa driver download failed."
    validate_archive_size "$ARCHIVE_FILE"
    if [[ -n "$EXPECTED_ARCHIVE_SHA256" ]] && \
        ! validate_release_asset_checksum "$ARCHIVE_FILE"; then
        die "下载的 ${ARCHIVE_NAME} 未通过 SHA-256 校验。" \
            "Downloaded ${ARCHIVE_NAME} failed SHA-256 verification."
    fi
    validate_archive_paths "$ARCHIVE_FILE"

    case "$PACKAGE_MANAGER" in
        pacman)
            tar --extract --file "$ARCHIVE_FILE" --directory "$WORK_DIR" \
                --no-same-owner
            install_arch_packages
            ;;
        apt|dnf)
            install_tar_gz
            ;;
        *)
            die "内部错误：未知的软件包管理器 ${PACKAGE_MANAGER}。" \
                "Internal error: unknown package manager ${PACKAGE_MANAGER}."
            ;;
    esac
    configure_package_holds
}

main() {
    detect_language
    parse_arguments "$@"
    detect_target
    check_architecture
    require_root "$@"
    require_commands
    install_mesa
    log "Mesa 驱动安装完成，相关软件包已锁定。" \
        "Mesa driver installation completed; related packages are now held."
}

main "$@"
