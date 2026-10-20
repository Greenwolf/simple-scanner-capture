#!/usr/bin/env bash

usage() {
cat <<EOF
Usage:
  $0 [options] <target> [target ...]
  $0 [options] -l targets.txt
  $0 --install [-n] [--no-testssl]   install the tools this needs (detects the OS)

Options:
  -l <file>     file with one target per line (# comments allowed)
  -o <dir>      output directory (default: capture-<timestamp>)
  -p <port>     HTTPS port (default: 443)
  -t <seconds>  per-connection timeout (default: 10)
  -H, --header "<Name: value>"   session header for the HTTPS requests (repeatable)
  --header-file <file>           one "Name: value" header per line
  --no-testssl  don't run testssl even if it is installed
  -n, --dry-run print the commands instead of running them (to run by hand);
                with --install, print the install commands for this OS
  --install     install curl, openssl, dig, timeout and testssl with the OS's
                package manager (sudo if not root), then show what was found
  -h, --help    show this help

Env: OPENSSL=<path> to use another openssl, TESTSSL=<path> for testssl.
Targets may be:  host | host:port | https://host[:port]/path | IP
Then copy <dir> back and run:  ./simple-scanner.sh --import <dir>
EOF
exit "${1:-0}"
}

OUT=""; PORT=443; TIMEOUT=10; LIST=""; DRY=0; USE_TESTSSL=1; INSTALL=0
# macOS /usr/bin/openssl is LibreSSL: prefer Homebrew's OpenSSL 3 when present
if [ -z "${OPENSSL:-}" ] && [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then
    o="$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"; [ -x "$o" ] && OPENSSL="$o"
fi
OPENSSL="${OPENSSL:-openssl}"
TS_GIT="$HOME/.simple-scanner/testssl.sh"   # where --install clones testssl (same as simple-scanner)
HDRS=(); HNAMES=""; TARGETS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -l)            LIST="$2"; shift ;;
        -o)            OUT="$2"; shift ;;
        -p)            PORT="$2"; shift ;;
        -t)            TIMEOUT="$2"; shift ;;
        -H|--header)   HDRS+=(-H "$2"); HNAMES="$HNAMES ${2%%:*}"; shift ;;
        --header-file)
            [ -r "$2" ] || { echo "error: cannot read $2" >&2; exit 1; }
            while IFS= read -r l || [ -n "$l" ]; do
                l="${l%$'\r'}"
                [[ "$l" =~ ^[[:space:]]*(#|$) ]] && continue
                HDRS+=(-H "$l"); HNAMES="$HNAMES ${l%%:*}"
            done < "$2"; shift ;;
        --no-testssl)  USE_TESTSSL=0 ;;
        -n|--dry-run)  DRY=1 ;;
        --install)     INSTALL=1 ;;
        -h|--help)     usage 0 ;;
        -*)            echo "error: unknown option $1" >&2; usage 1 ;;
        *)             TARGETS+=("$1") ;;
    esac
    shift
done
if [ -n "$LIST" ]; then
    [ -r "$LIST" ] || { echo "error: cannot read $LIST" >&2; exit 1; }
    while IFS= read -r l || [ -n "$l" ]; do
        l="${l%%#*}"; l="${l//[[:space:]]/}"
        [ -n "$l" ] && TARGETS+=("$l")
    done < "$LIST"
fi
[ ${#TARGETS[@]} -gt 0 ] || [ "$INSTALL" = 1 ] || { echo "error: no targets given" >&2; usage 1; }
[ -n "$OUT" ] || OUT="capture-$(date +%Y%m%d-%H%M%S)"

# q <arg>: quote an argument for the printed command line
q() {
    case "$1" in
        *[!A-Za-z0-9_./:=@,+%-]*|'') printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}

# ---------------------------------------------------------------- --install
# os_detect: OS_ID / OS_LIKE / OS_NAME from /etc/os-release (or macOS), PM = the
# package manager to use, WSL=1 under Windows Subsystem for Linux
os_detect() {
    OS_ID=""; OS_LIKE=""; OS_NAME=""; PM=""; WSL=0
    if [ "$(uname -s)" = Darwin ]; then
        OS_ID=macos; OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null)"
    elif [ -r /etc/os-release ]; then
        OS_ID="$(. /etc/os-release; echo "${ID:-}")"
        OS_LIKE="$(. /etc/os-release; echo "${ID_LIKE:-}")"
        OS_NAME="$(. /etc/os-release; echo "${PRETTY_NAME:-${NAME:-$ID}}")"
    fi
    grep -qi microsoft /proc/version 2>/dev/null && WSL=1
    case " $OS_ID $OS_LIKE " in
        *" macos "*) PM=brew ;;
        *" debian "*|*" ubuntu "*|*" kali "*|*" linuxmint "*|*" pop "*|*" raspbian "*|*" parrot "*) PM=apt ;;
        *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*|*" amzn "*|*" ol "*) PM=dnf ;;
        *" opensuse"*|*" suse "*|*" sles "*) PM=zypper ;;
        *" arch "*|*" manjaro "*|*" endeavouros "*|*" blackarch "*) PM=pacman ;;
        *" alpine "*) PM=apk ;;
    esac
    # unknown distro: use whichever package manager is there
    if [ -z "$PM" ]; then
        for p in apt-get:apt dnf:dnf yum:yum zypper:zypper pacman:pacman apk:apk brew:brew; do
            command -v "${p%%:*}" >/dev/null 2>&1 && { PM="${p#*:}"; break; }
        done
    fi
    # older RHEL / CentOS / Amazon Linux 2 have yum only
    [ "$PM" = dnf ] && ! command -v dnf >/dev/null 2>&1 && command -v yum >/dev/null 2>&1 && PM=yum
    return 0
}
# sh_run <command...>: run it (or print it with -n)
sh_run() {
    local a line=""
    for a in "$@"; do line="$line${line:+ }$(q "$a")"; done
    if [ "$DRY" = 1 ]; then printf '%s\n' "$line"; return 0; fi
    printf '[*] %s\n' "$line" >&2
    "$@"
}
# pkg_install <pkg|alt-pkg> ...: install them all; if that fails, one at a time (so
# one missing package doesn't stop the rest), trying each "|" alternative in turn
pkg_install() {
    local first="" p a ok
    for p in "$@"; do first="$first ${p%%|*}"; done
    # shellcheck disable=SC2086
    pm_add $first && return 0
    [ "$DRY" = 1 ] && return 0
    for p in "$@"; do
        ok=0
        for a in $(printf '%s' "$p" | tr '|' ' '); do pm_add "$a" && { ok=1; break; }; done
        [ "$ok" = 1 ] || printf '[!] could not install %s\n' "$p" >&2
    done
    return 0
}
pm_add() {
    case "$PM" in
        apt)    sh_run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" ;;
        dnf)    sh_run $SUDO dnf install -y "$@" ;;
        yum)    sh_run $SUDO yum install -y "$@" ;;
        zypper) sh_run $SUDO zypper --non-interactive install "$@" ;;
        pacman) sh_run $SUDO pacman -S --needed --noconfirm "$@" ;;
        apk)    sh_run $SUDO apk add "$@" ;;
        brew)   sh_run brew install "$@" ;;
    esac
}
do_install() {
    os_detect
    printf '[*] detected: %s%s (package manager: %s)\n' "${OS_NAME:-unknown OS}" \
        "$([ "$WSL" = 1 ] && echo ', under WSL')" "${PM:-none found}" >&2
    [ -n "$PM" ] || { echo "error: no supported package manager (apt, dnf, yum, zypper, pacman, apk, brew); install curl, openssl and dig by hand" >&2; exit 1; }
    SUDO=""
    if [ "$PM" != brew ] && [ "$(id -u)" != 0 ]; then
        if   command -v sudo >/dev/null 2>&1; then SUDO=sudo
        elif command -v doas >/dev/null 2>&1; then SUDO=doas
        elif [ "$DRY" = 0 ]; then echo "error: not root and no sudo/doas: run --install as root" >&2; exit 1
        else SUDO=sudo; fi
    fi
    [ "$DRY" = 1 ] && printf '# install commands for %s (%s)\n' "${OS_NAME:-this OS}" "$PM"
    # base tools: curl, openssl, dig, GNU timeout (coreutils), git (testssl fallback);
    # testssl also needs hexdump (bsdextrautils / util-linux)
    case "$PM" in
        apt)    sh_run $SUDO apt-get update -q
                pkg_install bash curl openssl 'bind9-dnsutils|dnsutils' coreutils ca-certificates git
                [ "$USE_TESTSSL" = 1 ] && pkg_install testssl.sh 'bsdextrautils|bsdmainutils' ;;
        dnf|yum) pkg_install bash curl openssl bind-utils coreutils ca-certificates git
                [ "$USE_TESTSSL" = 1 ] && pkg_install testssl util-linux ;;
        zypper) pkg_install bash curl openssl bind-utils coreutils ca-certificates git
                [ "$USE_TESTSSL" = 1 ] && pkg_install util-linux ;;
        pacman) pkg_install bash curl openssl 'bind|bind-tools' coreutils ca-certificates git
                [ "$USE_TESTSSL" = 1 ] && pkg_install testssl.sh util-linux ;;
        apk)    pkg_install bash curl openssl bind-tools coreutils ca-certificates git
                [ "$USE_TESTSSL" = 1 ] && pkg_install testssl.sh util-linux procps ;;
        brew)   pkg_install curl openssl@3 bind coreutils git
                [ "$USE_TESTSSL" = 1 ] && pkg_install testssl ;;
    esac
    # testssl isn't packaged everywhere (openSUSE, RHEL without EPEL ...): clone it
    if [ "$USE_TESTSSL" = 1 ]; then
        if [ "$DRY" = 1 ]; then
            printf '# if testssl is still missing:\n'
            sh_run git clone --depth 1 --branch 3.2 https://github.com/testssl/testssl.sh "$TS_GIT"
        elif ! command -v testssl >/dev/null 2>&1 && ! command -v testssl.sh >/dev/null 2>&1 && [ ! -x "$TS_GIT/testssl.sh" ]; then
            mkdir -p "$(dirname "$TS_GIT")" && \
                sh_run git clone -q --depth 1 --branch 3.2 https://github.com/testssl/testssl.sh "$TS_GIT" \
                || echo "[!] could not fetch testssl; cipher suites won't be captured" >&2
        fi
    fi
    [ "$DRY" = 1 ] && exit 0
    # what the capture will use
    printf '\n[*] tools found:\n' >&2
    check_tool() { if command -v "$2" >/dev/null 2>&1; then printf '    %-8s %s\n' "$1" "$(command -v "$2")" >&2; return 0; fi; return 1; }
    check_tool curl curl || echo "    curl     MISSING (required)" >&2
    check_tool openssl "$OPENSSL" || echo "    openssl  MISSING (required)" >&2
    "$OPENSSL" version 2>/dev/null | grep -qi libressl && echo "    (openssl is LibreSSL; set OPENSSL= to a real OpenSSL)" >&2
    check_tool dig dig || check_tool host host || echo "    dig      missing: DNS checks won't be captured" >&2
    check_tool timeout timeout || check_tool timeout gtimeout || echo "    timeout  missing: probes run without a time limit" >&2
    if [ "$USE_TESTSSL" = 1 ]; then
        check_tool testssl testssl || check_tool testssl testssl.sh || check_tool testssl "$TS_GIT/testssl.sh" \
            || echo "    testssl  missing: cipher suites won't be captured" >&2
        command -v hexdump >/dev/null 2>&1 || echo "    hexdump  missing (testssl needs it)" >&2
    fi
    exit 0
}
[ "$INSTALL" = 1 ] && do_install

# tools (a dry run prints the stock names, for running on another machine)
TO=""; DIG=dig; TS=""
if [ "$DRY" = 1 ]; then
    TO="timeout $TIMEOUT"; [ "$USE_TESTSSL" = 1 ] && TS="${TESTSSL:-testssl}"
else
    if   command -v timeout  >/dev/null 2>&1; then TO="timeout $TIMEOUT"
    elif command -v gtimeout >/dev/null 2>&1; then TO="gtimeout $TIMEOUT"; fi
    if   command -v dig  >/dev/null 2>&1; then DIG=dig
    elif command -v host >/dev/null 2>&1; then DIG=host
    else DIG=""; echo "[!] no dig/host: DNS checks not captured" >&2; fi
    if [ "$USE_TESTSSL" = 1 ]; then
        for t in "${TESTSSL:-}" testssl testssl.sh "$TS_GIT/testssl.sh"; do
            [ -n "$t" ] && command -v "$t" >/dev/null 2>&1 && { TS="$t"; break; }
        done
        [ -n "$TS" ] || echo "[!] no testssl: cipher suites not captured (the openssl probes are)" >&2
    fi
    command -v curl >/dev/null 2>&1 || { echo "error: curl not found" >&2; exit 1; }
    command -v "$OPENSSL" >/dev/null 2>&1 || { echo "error: openssl not found" >&2; exit 1; }
fi

# run <file> <keep|drop stderr> <command...>: save the command's output to $OUT/<file>
run() {
    local f="$1" e="$2" a line=""; shift 2
    if [ "$DRY" = 1 ]; then
        for a in "$@"; do line="$line${line:+ }$(q "$a")"; done
        if [ "$e" = keep ]; then e=" 2>&1"; else e=" 2>/dev/null"; fi
        printf '%s < /dev/null > %s%s\n' "$line" "$(q "$OUT/$f")" "$e"
        return 0
    fi
    if [ "$e" = keep ]; then "$@" < /dev/null > "$OUT/$f" 2>&1
    else "$@" < /dev/null > "$OUT/$f" 2>/dev/null; fi
    return 0
}
say() { if [ "$DRY" = 1 ]; then printf '\n# %s\n' "$*"; else printf '[*] %s\n' "$*" >&2; fi; }
is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$1" == *:*:* ]]; }

if [ "$DRY" = 1 ]; then
    printf '# simple-scanner capture commands: run these on the test machine, then copy\n'
    printf '# the %s folder back and run:  ./simple-scanner.sh --import %s\n' "$OUT" "$OUT"
    printf 'mkdir -p %s\n' "$(q "$OUT")"
else
    mkdir -p "$OUT" || { echo "error: cannot create $OUT" >&2; exit 1; }
    : > "$OUT/targets.txt"
fi
DONE_DNS=" "
for raw in "${TARGETS[@]}"; do
    # same target parsing as simple-scanner
    t="${raw#http://}"; t="${t#https://}"
    path="/"; [[ "$t" == */* ]] && path="/${t#*/}"
    t="${t%%/*}"
    if [[ "$t" == *:* && "$t" != *:*:* ]]; then host="${t%%:*}"; port="${t##*:}"
    else host="$t"; port="$PORT"; fi
    hp="$host:$port"; f="${host}_$port"; url="https://$hp$path"
    if [ "$DRY" = 1 ]; then
        say "$hp$path"
        printf 'echo %s >> %s\n' "$(q "$hp$path")" "$(q "$OUT/targets.txt")"
    else
        say "capturing $hp$path"
        printf '%s\n' "$hp$path" >> "$OUT/targets.txt"
    fi

    # HTTP checks (session headers go on the HTTPS requests only)
    run "$f.https.txt"   keep curl -sS -v -k --http1.1 --max-time "$TIMEOUT" "${HDRS[@]}" -o /dev/null "$url"
    if [ "$DRY" = 1 ]; then
        printf '# if %s has no "< HTTP/" line, run it again without --http1.1\n' "$f.https.txt"
    elif ! grep -q '^< HTTP/' "$OUT/$f.https.txt"; then
        run "$f.https.txt" keep curl -sS -v -k --max-time "$TIMEOUT" "${HDRS[@]}" -o /dev/null "$url"
    fi
    run "$f.trace.txt"   keep curl -sS -v -k -X TRACE --max-time "$TIMEOUT" "${HDRS[@]}" "$url"
    run "$f.options.txt" keep curl -sS -v -k -X OPTIONS --max-time "$TIMEOUT" "${HDRS[@]}" -o /dev/null "$url"
    run "${host}_80.http.txt" keep curl -sS -v --max-time "$TIMEOUT" -o /dev/null "http://$host:80/"

    # TLS: testssl when available, plus the openssl probes the scanner falls back to
    if [ -n "$TS" ]; then
        [ "$DRY" = 1 ] && printf '# optional, needs testssl (cipher suite findings come only from this):\n'
        run "$f.testssl.txt" keep ${TO:+${TO%% *} 900} "$TS" --quiet --color 0 --warnings off -p -e -f -S -C "$hp"
    fi
    for p in ssl3 tls1 tls1_1; do
        run "$f.$p.txt" keep $TO "$OPENSSL" s_client -connect "$hp" -servername "$host" "-$p" -cipher 'ALL:@SECLEVEL=0'
        # OpenSSL 1.0.x has no @SECLEVEL
        if [ "$DRY" = 0 ] && grep -qiE 'error with command|no cipher match|error in cipher list' "$OUT/$f.$p.txt"; then
            run "$f.$p.txt" keep $TO "$OPENSSL" s_client -connect "$hp" -servername "$host" "-$p" -cipher 'ALL'
        fi
    done
    run "$f.tls1_3.txt"  keep $TO "$OPENSSL" s_client -tls1_3 -connect "$hp" -servername "$host"
    run "$f.cert.txt"    drop $TO "$OPENSSL" s_client -connect "$hp" -servername "$host"
    is_ip "$host" || \
    run "$f.verify.txt"  drop $TO "$OPENSSL" s_client -connect "$hp" -servername "$host" -verify_hostname "$host"
    run "$f.ocsp.txt"    drop $TO "$OPENSSL" s_client -status -connect "$hp" -servername "$host"

    # DNS: CAA on the host and every parent domain; SPF / DMARC on the apex
    is_ip "$host" && continue
    [ -n "$DIG" ] || continue
    name="${host%.}"
    while [ -n "$name" ]; do
        if [[ "$DONE_DNS" != *" $name.caa "* ]]; then
            DONE_DNS="$DONE_DNS$name.caa "
            if [ "$DIG" = dig ]; then run "$name.caa.txt" keep dig "$name" CAA +time="$TIMEOUT" +tries=2
            else run "$name.caa.txt" keep host -W "$TIMEOUT" -t CAA "$name"; fi
        fi
        [[ "$name" == *.* ]] || break
        name="${name#*.}"
    done
    apex="$host"
    [ "$(awk -F. '{print NF}' <<<"$host")" -gt 2 ] && apex="$(awk -F. '{print $(NF-1)"."$NF}' <<<"$host")"
    if [[ "$DONE_DNS" != *" $apex.spf "* ]]; then
        DONE_DNS="$DONE_DNS$apex.spf "
        if [ "$DIG" = dig ]; then
            run "$apex.spf.txt"   drop dig +short TXT "$apex"
            run "$apex.dmarc.txt" drop dig +short TXT "_dmarc.$apex"
        else
            run "$apex.spf.txt"   drop host -t TXT "$apex"
            run "$apex.dmarc.txt" drop host -t TXT "_dmarc.$apex"
        fi
    fi
done

if [ "$DRY" = 1 ]; then
    printf '\n# optional: record when and with what the capture was made\n'
    printf '{ echo "captured: $(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)"; echo "timeout: %s"; echo "curl: $(curl --version | head -1)"; echo "openssl: $(openssl version)"; } > %s\n' \
        "$TIMEOUT" "$(q "$OUT/capture-info.txt")"
else
    {
        echo "captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "timeout: $TIMEOUT"
        echo "curl: $(curl --version 2>/dev/null | head -1)"
        echo "openssl: $("$OPENSSL" version 2>/dev/null)"
        echo "dns: ${DIG:-none}"
        echo "testssl: ${TS:-none}"
        echo "session headers:${HNAMES:- none} (values not stored here)"
    } > "$OUT/capture-info.txt"
    printf '[+] done: %s\n    copy it back and run:  ./simple-scanner.sh --import %s\n' "$OUT" "$OUT" >&2
fi
