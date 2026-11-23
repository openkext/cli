#!/bin/zsh
# SPDX-License-Identifier: MIT
# openkext: find the drivers in the OpenKext catalog (https://openkext.org) that match this
# hackintosh, then download, verify and install them into the OpenCore EFI.
#
#   zsh -c "$(curl -fsSL https://openkext.org/install)"
#   zsh -c "$(curl -fsSL https://openkext.org/install)" openkext --dry-run
#
# Uses only what ships with macOS 12 and later: zsh, curl, shasum, ditto, plutil,
# PlistBuddy, ioreg, diskutil, nvram and osascript (for JSON). Nothing is installed on the system;
# the only files it keeps are backups and a log in ~/Library/Application Support/OpenKext.

emulate -R zsh
setopt extended_glob null_glob pipefail typeset_silent
[[ ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} == *UTF-8* ]] || export LC_CTYPE=en_US.UTF-8

typeset -g VERSION="0.1.0"
typeset -g API=${OPENKEXT_API:-https://openkext.org}
typeset -g STATE=${OPENKEXT_STATE:-$HOME/Library/Application Support/OpenKext}
typeset -g OC_GUID=4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102
typeset -g PB=/usr/libexec/PlistBuddy
typeset -g US=$'\x1f' TAB=$'\t' E=$'\e['

# options
typeset -gi O_DRY=0 O_YES=0 O_LIST=0 O_RESTORE=0 O_ALL=0
typeset -g O_EFI=""

# detected system
typeset -g MACOS="" ARCH="" OCVER="" MODEL=""
typeset -g ESP_DEV="" ESP_MNT="" OC="" EFI_LABEL="not found"
typeset -gi NEED_SUDO=0 MOUNTED_BY_US=0
typeset -g WORK="" CFG=""

# catalog rows (parallel arrays, 1-based)
typeset -ga K_ID K_NAME K_STATUS K_VER K_STATE K_REC K_WHY K_IVER K_SRC K_TAG K_ASSETS K_SUMMARY \
  K_LIC K_MAINT K_AI K_RANGE K_INRANGE K_NOTES K_GROUP K_BUNDLES SEL ASEL

# colors
typeset -g C_B="" C_D="" C_R="" C_G="" C_Y="" C_C="" C_RED="" C_INV=""
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_B="${E}1m" C_D="${E}2m" C_R="${E}0m" C_G="${E}32m" C_Y="${E}33m" C_C="${E}36m" C_RED="${E}31m" C_INV="${E}7m"
fi

# --------------------------------------------------------------------------------------------
# small helpers

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$STATE/openkext.log" 2>/dev/null }
say() { print -r -- "$*"; log "$*" }
ok() { print -r -- "  ${C_G}✓${C_R} $*"; log "ok: $*" }
warn() { print -r -- "  ${C_Y}!${C_R} $*"; log "warn: $*" }
die() { tui_close; print -r -- "${C_RED}openkext:${C_R} $*" >&2; log "error: $*"; exit 1 }

usage() {
  cat <<EOF
openkext $VERSION: install hackintosh drivers from the OpenKext catalog

  openkext              interactive: detect hardware, pick drivers, install
  openkext --dry-run    do everything except change the EFI
  openkext --list       print what matches this machine and exit
  openkext --yes        install the recommended drivers without asking
  openkext --all        list every driver in the catalog, not only matches
  openkext --efi PATH   use this EFI volume (the folder that holds EFI/OC)
  openkext --restore    put back an EFI/OC backup made by an earlier run
  openkext --state DIR  keep backups and the log in DIR

One-liner:  zsh -c "\$(curl -fsSL https://openkext.org/install)"
With flags: zsh -c "\$(curl -fsSL https://openkext.org/install)" openkext --dry-run

Backups and the log: $STATE
EOF
}

parse_args() {
  while (( $# )); do
    case $1 in
      --dry-run|-n) O_DRY=1 ;;
      --yes|-y) O_YES=1 ;;
      --list|-l) O_LIST=1 ;;
      --all|-a) O_ALL=1 ;;
      --restore) O_RESTORE=1 ;;
      --efi) (( $# >= 2 )) || die "--efi needs a path"; O_EFI=$2; shift ;;
      --efi=*) O_EFI=${1#--efi=} ;;
      --state) (( $# >= 2 )) || die "--state needs a path"; STATE=$2; shift ;;
      --version|-V) print -r -- "openkext $VERSION"; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
}

# 1.2.3 compare: returns 0 when $1 >= $2
ver_ge() {
  local -a a b; a=(${(s:.:)1}) b=(${(s:.:)2})
  local i x y
  for (( i = 1; i <= ${#a} || i <= ${#b}; i++ )); do
    x=${a[i]:-0} y=${b[i]:-0}; x=${x%%[^0-9]*} y=${y%%[^0-9]*}
    (( ${x:-0} > ${y:-0} )) && return 0
    (( ${x:-0} < ${y:-0} )) && return 1
  done
  return 0
}

# run a command that writes to the EFI, with sudo when the volume is not writable for us
w() { if (( NEED_SUDO )); then sudo "$@"; else "$@"; fi }

plist_get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null }

cleanup() {
  tui_close
  (( ${DIRTY:-0} )) && rollback
  [[ -n $WORK && -d $WORK ]] && rm -rf "$WORK"
  if (( MOUNTED_BY_US )) && [[ -n $ESP_DEV ]]; then
    diskutil unmount "$ESP_DEV" >/dev/null 2>&1 || sudo -n diskutil unmount "$ESP_DEV" >/dev/null 2>&1
  fi
}

# --------------------------------------------------------------------------------------------
# detection

detect_system() {
  MACOS=${OPENKEXT_MACOS:-$(sw_vers -productVersion 2>/dev/null)}
  ARCH=${OPENKEXT_ARCH:-$(uname -m)}
  MODEL=${OPENKEXT_MODEL:-$(sysctl -n hw.model 2>/dev/null)}
  if [[ -n ${OPENKEXT_OCVER+x} ]]; then OCVER=$OPENKEXT_OCVER
  else OCVER=$(nvram "${OC_GUID}:opencore-version" 2>/dev/null | awk '{print $2}'); fi
  [[ -n $MACOS ]] || die "could not read the macOS version"
  ver_ge "$MACOS" 12 || die "macOS $MACOS is too old for this tool (needs 12 or later)"
  if [[ $ARCH == arm64 ]]; then
    die "this is an Apple Silicon Mac. Hackintosh kexts only apply to Intel and AMD PCs running OpenCore."
  fi
}

# "<86800000>" -> "8086"
le16() { local h=${${1#<}%>}; h=${h:l}; print -r -- "${h[3,4]}${h[1,2]}" }

detect_hw() {
  local out=$WORK/hw.tsv line name="" ven="" dev=""
  : >"$out"
  local pci usb
  if [[ -n ${OPENKEXT_IOREG_PCI:-} ]]; then pci=$(<"$OPENKEXT_IOREG_PCI"); else pci=$(ioreg -r -c IOPCIDevice -d 1 2>/dev/null); fi
  for line in "${(@f)pci}" "+-o end  <class IOPCIDevice"; do
    if [[ $line == *'+-o '*'<class '* ]]; then
      [[ -n $ven && -n $dev ]] && print -r -- "pci${TAB}${ven}:${dev}${TAB}${name}" >>"$out"
      name=${${line#*+-o }%%  <class*}; name=${name%%@*}; ven="" dev=""
    elif [[ $line == *'"vendor-id" = <'* ]]; then ven=$(le16 "${line##*= }")
    elif [[ $line == *'"device-id" = <'* ]]; then dev=$(le16 "${line##*= }")
    fi
  done
  if [[ -n ${OPENKEXT_IOREG_USB:-} ]]; then usb=$(<"$OPENKEXT_IOREG_USB"); else usb=$(ioreg -r -c IOUSBHostDevice -d 1 2>/dev/null); fi
  name="" ven="" dev=""
  for line in "${(@f)usb}" "+-o end  <class IOUSBHostDevice"; do
    if [[ $line == *'+-o '*'<class '* ]]; then
      [[ -n $ven && -n $dev ]] && print -r -- "usb${TAB}$(printf '%04x:%04x' $ven $dev)${TAB}${name}" >>"$out"
      name=${${line#*+-o }%%  <class*}; name=${name%%@*}; ven="" dev=""
    elif [[ $line == *'"idVendor" = '<->* ]]; then ven=${line##*= }
    elif [[ $line == *'"idProduct" = '<->* ]]; then dev=${line##*= }
    fi
  done
  sort -u -o "$out" "$out"
}

# --------------------------------------------------------------------------------------------
# EFI

use_efi_root() {
  local root=${1%/}
  if [[ -f $root/config.plist && -d $root/Kexts ]]; then OC=$root
  elif [[ -f $root/EFI/OC/config.plist ]]; then OC=$root/EFI/OC
  else return 1; fi
  [[ -d $OC/Kexts ]] || return 1
  EFI_LABEL=${ESP_DEV:-$root}
  if [[ -n ${OPENKEXT_NO_SUDO:-} ]]; then NEED_SUDO=0
  elif touch "$OC/Kexts/.openkext-w" 2>/dev/null; then rm -f "$OC/Kexts/.openkext-w"; NEED_SUDO=0
  else NEED_SUDO=1; fi
  return 0
}

esp_list() { diskutil list 2>/dev/null | awk '$2 == "EFI" || $3 == "EFI" {print $NF}' | grep -E '^disk[0-9]+s[0-9]+$' }
esp_mountpoint() { diskutil info "$1" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}' }

# Finds the EFI that OpenCore booted from (boot-path in NVRAM), mounting it when needed.
# $1 = 1 to allow mounting (asks for the password).
locate_efi() {
  local may_mount=$1
  if [[ -n $O_EFI ]]; then
    use_efi_root "$O_EFI" || die "$O_EFI does not contain EFI/OC/config.plist"
    return 0
  fi
  local bp uuid dev puuid
  local -a esps cands
  bp=$(nvram "${OC_GUID}:boot-path" 2>/dev/null)
  [[ $bp =~ 'GPT,([0-9A-Fa-f-]{36})' ]] && uuid=${match[1]:u}
  esps=($(esp_list))
  local matched=0
  for dev in $esps; do
    puuid=$(diskutil info "$dev" 2>/dev/null | awk -F': *' '/Partition UUID/ {print toupper($2)}')
    if [[ -n $uuid && $puuid == $uuid ]]; then cands=($dev); matched=1; break; fi
    cands+=($dev)
  done
  (( ${#cands} )) || return 1
  if [[ -n $uuid ]] && (( ! matched )); then
    # OpenCore booted from a partition we can't see (an installer USB, for example): never guess
    warn "OpenCore booted from partition $uuid, which is not an EFI partition on a disk here."
    return 1
  fi
  if (( ! matched )); then
    # several disks with an EFI partition and no boot-path match: prefer mounted ones with OpenCore
    local -a withoc
    for dev in $cands; do
      local m=$(esp_mountpoint $dev)
      [[ -n $m && -f $m/EFI/OC/config.plist ]] && withoc+=($dev)
    done
    (( ${#withoc} )) && cands=($withoc)
    (( O_YES || O_LIST )) && return 1
    tui_menu "Which EFI partition holds the OpenCore you boot?" \
      "OpenCore did not report its boot partition, so pick one." $cands || return 1
    tui_close
    cands=(${cands[REPLY_IDX]})
  fi
  ESP_DEV=${cands[1]}
  ESP_MNT=$(esp_mountpoint $ESP_DEV)
  if [[ -z $ESP_MNT ]]; then
    (( may_mount )) || return 1
    say "Mounting the EFI partition $ESP_DEV (macOS asks for your password)."
    sudo diskutil mount "$ESP_DEV" >/dev/null || return 1
    MOUNTED_BY_US=1
    ESP_MNT=$(esp_mountpoint $ESP_DEV)
  fi
  use_efi_root "$ESP_MNT" || return 1
  EFI_LABEL="$ESP_DEV ($ESP_MNT)"
}

# installed kexts: from the EFI (preferred) and from the running kernel
detect_installed() {
  local out=$WORK/installed.tsv k id v
  : >"$out"
  if [[ -n $OC ]]; then
    for k in "$OC"/Kexts/*.kext; do
      id=$(plist_get "$k/Contents/Info.plist" CFBundleIdentifier) || continue
      v=$(plist_get "$k/Contents/Info.plist" CFBundleShortVersionString) || v=$(plist_get "$k/Contents/Info.plist" CFBundleVersion)
      print -r -- "${id}${TAB}${v:-?}${TAB}efi${TAB}${k:t}" >>"$out"
    done
  fi
  local loaded
  if [[ -n ${OPENKEXT_KMUTIL:-} ]]; then loaded=$(<"$OPENKEXT_KMUTIL")
  else loaded=$(kmutil showloaded --list-only 2>/dev/null || kextstat -l 2>/dev/null); fi
  print -r -- "$loaded" | awk -v T="$TAB" '{for(i=2;i<=NF;i++) if($i ~ /^\(.*\)$/){print $(i-1) T substr($i,2,length($i)-2) T "loaded"; break}}' \
    | grep -v '^com\.apple\.' >>"$out"
}

# The OpenCore Kernel>Add list as "index<TAB>BundlePath<TAB>Enabled" lines
cfg_entries() {
  local f=$1
  $PB -c "Print :Kernel:Add" "$f" 2>/dev/null | awk -v T="$TAB" '
    /^    Dict \{/ { if (n++) print i T bp T en; bp=""; en=""; i=n-1 }
    /^        BundlePath = / { sub(/^        BundlePath = /, ""); bp=$0 }
    /^        Enabled = / { sub(/^        Enabled = /, ""); en=$0 }
    END { if (n) print i T bp T en }'
}

# --------------------------------------------------------------------------------------------
# catalog

write_engine() {
  cat >"$WORK/engine.js" <<'JS'
ObjC.import('Foundation');
const US = '\x1f';
function read(p) { const s = $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null); return (s && !s.isNil()) ? s.js : ''; }
// catalog text is community input: no control or bidi characters reach the terminal
function clean(s, max) {
  s = String(s == null ? '' : s).replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]/g, ' ').replace(/\s+/g, ' ').trim();
  if (max && s.length > max) s = s.slice(0, max - 1) + '…';
  return s;
}
function vcmp(a, b) {
  const A = String(a).split('.').map(x => parseInt(x, 10) || 0), B = String(b).split('.').map(x => parseInt(x, 10) || 0);
  for (let i = 0; i < Math.max(A.length, B.length); i++) { const d = (A[i] || 0) - (B[i] || 0); if (d) return d < 0 ? -1 : 1; }
  return 0;
}
const ID = /^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$/, SAFE = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$/, SHA = /^[0-9a-f]{64}$/,
  SRC = /^https:\/\/github\.com\/[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/, BID = /^[A-Za-z0-9][A-Za-z0-9._-]{2,119}$/;
const map = o => Object.assign(Object.create(null), o);
const RANK = map({ 'community-verified': 0, 'author-tested': 1, 'submitted': 2, 'reported-broken': 3 });
const GROUP = map({ match: 0, installed: 1, other: 2 });
function run(argv) {
  const [catPath, hwPath, instPath, macos] = argv;
  let cat;
  try { cat = JSON.parse(read(catPath)); } catch (e) { return 'ERROR' + US + 'the catalog is not valid JSON'; }
  if (!cat || !Array.isArray(cat.kexts)) return 'ERROR' + US + 'the catalog has no kexts list';
  const hw = map({});
  read(hwPath).split('\n').forEach(l => { const f = l.split('\t'); if (f.length >= 2) hw[f[0] + ' ' + f[1]] = f[2] || ''; });
  const inst = map({});
  read(instPath).split('\n').forEach(l => { const f = l.split('\t'); if (f[0] && !(f[0] in inst)) inst[f[0]] = f[1] || '?'; });
  const rows = [];
  for (const k of cat.kexts) { try {
    if (!k || k.kind !== 'kext' || !ID.test(k.id || '') || !SRC.test(k.source || '')) continue;
    const st = (k.status && typeof k.status.status === 'string' && RANK[k.status.status] !== undefined) ? k.status.status : 'submitted';
    const rels = Array.isArray(k.releases) ? k.releases : [];
    if (!rels.length) continue;
    let ri = 0;
    if (!rels.every(r => r && typeof r === 'object')) continue;
    rels.forEach((r, i) => { if (String(r.date) >= String(rels[ri].date)) ri = i; });
    const rel = rels[ri];
    if (!SAFE.test(rel.tag || '') || !SAFE.test(rel.version || '')) continue;
    const matches = [];
    (Array.isArray(k.hardware) ? k.hardware : []).filter(h => h && typeof h === 'object').forEach(h => ['pci', 'usb'].forEach(bus =>
      (Array.isArray(h[bus + '_ids']) ? h[bus + '_ids'] : []).forEach(id => {
        if ((bus + ' ' + id) in hw) matches.push(clean(h.description, 60) + ' (' + clean(id, 9) + ')');
      })));
    const bids = (Array.isArray(k.bundle_ids) ? k.bundle_ids : []).filter(b => BID.test(b));
    let iv = '';
    bids.forEach(b => { if (!iv && inst[b]) iv = clean(inst[b], 30); });
    const lo = clean((k.macos || {}).min, 8), hi = clean((k.macos || {}).max, 8);
    const inRange = !!(lo && hi && vcmp(macos, lo) >= 0 &&
      vcmp(macos.split('.').slice(0, hi.split('.').length).join('.'), hi) <= 0);
    const assets = (Array.isArray(rel.assets) ? rel.assets : []).filter(a => a && SAFE.test(a.name || '') && SHA.test(a.sha256 || ''))
      .map(a => { const m = clean(a.macos, 20).replace(/[,;]/g, ''); const fit = !m || (macos + '.').startsWith(m + '.');
        // debug builds are never selected by default
        return [a.name, a.sha256, m, fit ? 1 : 0, fit && !/debug/i.test(a.name) ? 1 : 0].join(','); });
    if (!assets.length) continue;
    const anyFit = assets.some(a => a.split(',')[3] === '1');
    const same = !!iv && iv.replace(/^v/i, '') === String(rel.version).replace(/^v/i, '');
    const state = !bids.length ? 'nobundle' : !anyFit ? 'noasset' : same ? 'current' : iv ? 'update' : 'new';
    const group = matches.length ? 'match' : iv ? 'installed' : 'other';
    const rec = group !== 'other' && inRange && anyFit && bids.length && !same && (st === 'community-verified' || st === 'author-tested') ? 1 : 0;
    const why = matches.length ? 'matches ' + [...new Set(matches)].join(', ') : iv ? 'installed on this machine' : '';
    rows.push({ rec, group, st, name: clean(k.name, 80), line: [k.id, clean(k.name, 80), st, rel.version, state, rec, why, iv,
      k.source, rel.tag, assets.join(';'), clean(k.summary, 280), clean(k.license, 40),
      (Array.isArray(k.maintainers) ? k.maintainers : []).map(x => clean(x, 39)).join(' '), clean(k.ai_disclosure, 280),
      lo + ' to ' + hi, inRange ? 1 : 0, clean(rel.notes, 500), group, bids.join(' ')].join(US) });
  } catch (e) { /* one malformed entry must not break the tool for everyone */ } }
  rows.sort((a, b) => (b.rec - a.rec) || (GROUP[a.group] - GROUP[b.group]) || (RANK[a.st] - RANK[b.st]) || a.name.localeCompare(b.name));
  return rows.map(r => r.line).join('\n');
}
JS
}

# one 0/1 per asset: 1 when it is built for this macOS
default_flags() { local a flags=""; for a in "${(@s:;:)1}"; do [[ -n $a ]] && flags+=${a##*,}; done; print -rn -- "$flags" }

load_catalog() {
  local cat=$WORK/catalog.json
  curl -fsSL --proto '=https,file' --max-time 60 --retry 2 "$API/catalog.json" -o "$cat" \
    || die "could not download the catalog from $API/catalog.json"
  write_engine
  local out
  out=$(osascript -l JavaScript "$WORK/engine.js" "$cat" "$WORK/hw.tsv" "$WORK/installed.tsv" "$MACOS" 2>"$WORK/engine.err") \
    || die "could not read the catalog: $(<"$WORK/engine.err")"
  [[ $out == ERROR${US}* ]] && die "${out#ERROR$US}"
  local line; local -a f
  for line in "${(@f)out}"; do
    [[ -n $line ]] || continue
    f=("${(@ps:\x1f:)line}")
    (( ${#f} == 20 )) || continue
    K_ID+=("$f[1]") K_NAME+=("$f[2]") K_STATUS+=("$f[3]") K_VER+=("$f[4]") K_STATE+=("$f[5]") K_REC+=("$f[6]")
    K_WHY+=("$f[7]") K_IVER+=("$f[8]") K_SRC+=("$f[9]") K_TAG+=("$f[10]") K_ASSETS+=("$f[11]") K_SUMMARY+=("$f[12]")
    K_LIC+=("$f[13]") K_MAINT+=("$f[14]") K_AI+=("$f[15]") K_RANGE+=("$f[16]") K_INRANGE+=("$f[17]") K_NOTES+=("$f[18]")
    K_GROUP+=("$f[19]") K_BUNDLES+=("$f[20]")
    SEL+=("$f[6]")
    # default asset choice: every asset built for this macOS
    ASEL+=("$(default_flags "$f[11]")")
  done
}

# --------------------------------------------------------------------------------------------
# text UI

typeset -gi TUI_ON=0 TUI_FAKE=0 KFD=0 ROWS=24 COLS=80 REPLY_IDX=0
typeset -g STTY_SAVED="" KEY=""

tui_open() {
  (( TUI_ON )) && return 0
  if [[ -n ${OPENKEXT_KEYS:-} ]]; then
    exec {KFD}<"$OPENKEXT_KEYS"; TUI_FAKE=1; TUI_ON=1; return 0
  fi
  [[ -r /dev/tty && -w /dev/tty ]] || die "no terminal available. Run it from Terminal, or use --list or --yes."
  exec {KFD}</dev/tty
  STTY_SAVED=$(stty -g </dev/tty)
  stty -echo -icanon min 1 time 0 </dev/tty
  print -rn -- "${E}?1049h${E}?25l"
  TUI_ON=1
}

tui_close() {
  (( TUI_ON )) || return 0
  TUI_ON=0
  (( TUI_FAKE )) && return 0
  print -rn -- "${E}?25h${E}?1049l"
  [[ -n $STTY_SAVED ]] && stty "$STTY_SAVED" </dev/tty 2>/dev/null
}

term_size() {
  if (( TUI_FAKE )); then ROWS=40 COLS=100; return; fi
  local s; s=$(stty size </dev/tty 2>/dev/null)
  ROWS=${s% *} COLS=${s#* }
  [[ $ROWS == <-> && $ROWS -gt 0 ]] || ROWS=24
  [[ $COLS == <-> && $COLS -gt 0 ]] || COLS=80
}

read_key() {
  local k="" rest=""
  if ! read -r -k 1 -u $KFD k; then KEY=quit; return; fi
  if [[ $k == $'\e' ]]; then
    read -r -t 0.05 -k 2 -u $KFD rest
    case $rest in
      '[A'|'OA') KEY=up ;; '[B'|'OB') KEY=down ;; '[C'|'OC') KEY=right ;; '[D'|'OD') KEY=left ;;
      '') KEY=esc ;; *) KEY=other ;;
    esac
  else
    case $k in
      $'\n'|$'\r') KEY=enter ;; ' ') KEY=space ;; k) KEY=up ;; j) KEY=down ;; l) KEY=right ;; h) KEY=left ;;
      *) KEY=$k ;;
    esac
  fi
}

# fit text into a width, cutting with an ellipsis, then pad with spaces
fit() { local s=$1 w=$2; (( w < 1 )) && return; (( ${#s} > w )) && s="${s[1,w-1]}…"; print -rn -- "${(r:w:)s}" }

typeset -g SCREEN=""
hr() { local s=""; print -rn -- "${(l:COLS::─:)s}" }
add() { SCREEN+="$1${E}K"$'\n' }
flush_screen() { print -rn -- "${E}H${SCREEN}${E}J"; SCREEN="" }

header() {
  local t=" OpenKext $VERSION " info="  macOS $MACOS · OpenCore ${OCVER:-not detected} · EFI ${EFI_LABEL}"
  add "${C_INV}${C_B}${t}${C_R}${C_D}$(fit "$info" $(( COLS - ${#t} )))${C_R}"
  add ""
}

status_badge() {
  case $1 in
    community-verified) print -rn -- "${C_G}$(fit 'community-verified' 18)${C_R}" ;;
    author-tested) print -rn -- "${C_C}$(fit 'author-tested' 18)${C_R}" ;;
    reported-broken) print -rn -- "${C_RED}$(fit 'reported-broken' 18)${C_R}" ;;
    *) print -rn -- "${C_Y}$(fit "${1:-submitted}" 18)${C_R}" ;;
  esac
}

action_text() {
  local i=$1
  case $K_STATE[i] in
    new) print -rn -- "install $K_VER[i]" ;;
    update) print -rn -- "update $K_IVER[i] → $K_VER[i]" ;;
    current) print -rn -- "up to date ($K_VER[i])" ;;
    noasset) print -rn -- "no build for macOS ${MACOS%%.*}" ;;
    nobundle) print -rn -- "not installable (no bundle_ids)" ;;
  esac
}

# generic single-choice menu. Sets REPLY_IDX; returns 1 when the user quits.
tui_menu() {
  local title=$1 sub=$2; shift 2
  local -a opts; opts=("$@")
  local cur=1 i
  tui_open
  while true; do
    term_size; header
    add " ${C_B}${title}${C_R}"; add " ${C_D}${sub}${C_R}"; add ""
    for (( i = 1; i <= ${#opts}; i++ )); do
      if (( i == cur )); then add " ${C_INV} ▸ $(fit "$opts[i]" $(( COLS - 6 ))) ${C_R}"
      else add "   $(fit "$opts[i]" $(( COLS - 6 )))"; fi
    done
    add ""; add " ${C_D}↑↓ move · enter choose · q quit${C_R}"
    flush_screen; read_key
    case $KEY in
      up) (( cur > 1 )) && (( cur-- )) ;; down) (( cur < ${#opts} )) && (( cur++ )) ;;
      enter|right) REPLY_IDX=$cur; return 0 ;;
      q|quit|esc) REPLY_IDX=0; return 1 ;;
    esac
  done
}

typeset -ga VIS
build_visible() {
  VIS=()
  local i
  for (( i = 1; i <= ${#K_ID}; i++ )); do
    if (( O_ALL )) || [[ $K_GROUP[i] != other ]]; then VIS+=($i); fi
  done
}

# asset picker for one project
tui_assets() {
  local i=$1 cur=1 j
  local -a as; as=("${(@s:;:)K_ASSETS[i]}")
  local flags=$ASEL[i]
  while true; do
    term_size; header
    add " ${C_B}$(fit "Files to install from ${K_NAME[i]} ${K_VER[i]}" $(( COLS - 2 )))${C_R}"
    add " ${C_D}Each file is a release download; its SHA-256 is checked against the catalog.${C_R}"
    add ""
    for (( j = 1; j <= ${#as}; j++ )); do
      local -a p; p=("${(@s:,:)as[j]}")
      local box="[ ]"; [[ ${flags[j]} == 1 ]] && box="[x]"
      local note=""; [[ -n $p[3] ]] && note="for macOS $p[3]"; [[ $p[4] == 0 ]] && note="$note, not this macOS"
      local row="$box $(fit "$p[1]" $(( COLS - 42 ))) ${note}"
      if (( j == cur )); then add " ${C_INV}▸ $(fit "$row" $(( COLS - 4 )))${C_R}"
      elif [[ $p[4] == 0 ]]; then add "   ${C_D}$(fit "$row" $(( COLS - 4 )))${C_R}"
      else add "   $(fit "$row" $(( COLS - 4 )))"; fi
    done
    add ""; add " ${C_D}↑↓ move · space select · enter or ← done${C_R}"
    flush_screen; read_key
    case $KEY in
      up) (( cur > 1 )) && (( cur-- )) ;; down) (( cur < ${#as} )) && (( cur++ )) ;;
      space|x) if [[ ${flags[cur]} == 1 ]]; then flags[cur]=0; else flags[cur]=1; fi ;;
      enter|left|esc|q|quit) break ;;
    esac
  done
  ASEL[i]=$flags
  [[ $flags == *1* ]] || SEL[i]=0
}

# main list. Returns 0 to continue, 1 to quit.
tui_select() {
  local cur=1 top=1 msg="" i n
  build_visible
  if (( ${#VIS} == 0 )) && (( ${#K_ID} )); then O_ALL=1; build_visible
    msg="No catalog driver matches this hardware yet, so the whole catalog is shown."; fi
  (( ${#VIS} )) || { tui_close; say "The catalog has no kexts yet."; return 1 }
  tui_open
  while true; do
    term_size; header
    n=0; for i in $VIS; do (( SEL[i] )) && (( n++ )); done
    local title="Drivers for this machine"; (( O_ALL )) && title="Whole catalog"
    add " ${C_B}${title}${C_R}  ${C_D}${n} selected · recommended ones start selected${C_R}"
    add ""
    local listh=$(( ROWS - 15 )); (( listh < 4 )) && listh=4
    local per=$(( listh / 2 ))
    (( cur < top )) && top=$cur
    (( cur >= top + per )) && top=$(( cur - per + 1 ))
    local vi
    for (( vi = top; vi < top + per && vi <= ${#VIS}; vi++ )); do
      i=$VIS[vi]
      local box="[ ]"; (( SEL[i] )) && box="[x]"
      local namew=$(( COLS - 52 )); (( namew < 16 )) && namew=16
      local rec=""; (( K_REC[i] )) && rec="${C_G}★${C_R}" || rec=" "
      local body="$(fit "$K_NAME[i]" $namew)  $(status_badge $K_STATUS[i])  $(fit "$(action_text $i)" 26)"
      if (( vi == cur )); then add " ${C_B}▸${C_R}${rec}${C_B}${box}${C_R} ${body}"
      else add "  ${rec}${box} ${body}"; fi
      add "       ${C_D}$(fit "${K_WHY[i]:-not matched to your hardware}" $(( COLS - 8 )))${C_R}"
    done
    (( ${#VIS} > per )) && add " ${C_D}$(( top ))–$(( top + per - 1 > ${#VIS} ? ${#VIS} : top + per - 1 )) of ${#VIS}${C_R}" || add ""
    # details of the highlighted project
    i=$VIS[cur]
    add "${C_D}$(hr)${C_R}"
    add " ${C_B}$(fit "$K_NAME[i]" $(( COLS - 2 )))${C_R}"
    add " $(fit "$K_SUMMARY[i]" $(( COLS - 2 )))"
    local range="tested on macOS $K_RANGE[i]"; (( K_INRANGE[i] )) || range="${C_Y}tested on macOS $K_RANGE[i], not $MACOS${C_R}"
    add " ${C_D}$(fit "license $K_LIC[i] · by $K_MAINT[i] · $K_SRC[i]" $(( COLS - 2 )))${C_R}"
    add " ${range}"
    add " ${C_D}$(fit "AI: $K_AI[i]" $(( COLS - 2 )))${C_R}"
    add "${C_D}$(hr)${C_R}"
    add " ${C_Y}$(fit "$msg" $(( COLS - 2 )))${C_R}"; msg=""
    local allkey="a show all"; (( O_ALL )) && allkey="a only matches"
    add " ${C_D}↑↓ move · space select · → files · ${allkey} · enter continue · q quit${C_R}"
    flush_screen; read_key
    case $KEY in
      up) (( cur > 1 )) && (( cur-- )) ;;
      down) (( cur < ${#VIS} )) && (( cur++ )) ;;
      space|x)
        if [[ $K_STATE[i] == noasset ]]; then msg="$K_NAME[i] has no file built for macOS ${MACOS%%.*}."
        elif [[ $K_STATE[i] == nobundle ]]; then msg="$K_NAME[i] does not list its bundle_ids in the catalog, so this tool can't install it safely."
        elif (( SEL[i] )); then SEL[i]=0
        else SEL[i]=1; [[ $ASEL[i] == *1* ]] || ASEL[i]=$(default_flags "$K_ASSETS[i]")
          [[ $K_STATUS[i] == reported-broken ]] && msg="Careful: testers report $K_NAME[i] as broken on its newest release."
        fi ;;
      right|o) tui_assets $i ;;
      a) O_ALL=$(( !O_ALL )); build_visible; cur=1; top=1
         (( ${#VIS} )) || { O_ALL=1; build_visible; msg="Nothing matches this hardware; showing the whole catalog." } ;;
      enter)
        n=0; for i in {1..${#K_ID}}; do (( SEL[i] )) && (( n++ )); done
        if (( n )); then return 0; else msg="Select at least one driver with space, or press q to quit."; fi ;;
      q|quit) return 1 ;;
    esac
  done
}

# review screen. Sets REVIEW to install|dry|back|quit
typeset -g REVIEW=""
tui_review() {
  local cur=1 i j
  (( O_DRY )) && cur=2
  local -a btn; btn=("Install" "Dry run" "Back" "Quit")
  while true; do
    term_size; header
    add " ${C_B}Review${C_R}"
    add ""
    add " $(fit "Target: $OC" $(( COLS - 2 )))"
    add " ${C_D}$(fit "First, EFI/OC is copied to $STATE/backups so you can undo with --restore." $(( COLS - 2 )))${C_R}"
    add ""
    local -a warns; warns=()
    for (( i = 1; i <= ${#K_ID}; i++ )); do
      (( SEL[i] )) || continue
      add " ${C_B}•${C_R} $(fit "$K_NAME[i]  $(action_text $i)" $(( COLS - 4 )))"
      local -a as; as=("${(@s:;:)K_ASSETS[i]}")
      for (( j = 1; j <= ${#as}; j++ )); do
        [[ ${ASEL[i][j]} == 1 ]] || continue
        local -a p; p=("${(@s:,:)as[j]}")
        add "     ${C_D}$(fit "$p[1]   sha256 ${p[2][1,12]}…" $(( COLS - 6 )))${C_R}"
      done
      [[ $K_STATUS[i] == submitted ]] && warns+=("$K_NAME[i] has no test reports yet.")
      [[ $K_STATUS[i] == reported-broken ]] && warns+=("$K_NAME[i] is reported broken by testers.")
      (( K_INRANGE[i] )) || warns+=("$K_NAME[i] was tested on macOS $K_RANGE[i], not $MACOS.")
    done
    add ""
    for j in $warns; do add " ${C_Y}! $(fit "$j" $(( COLS - 4 )))${C_R}"; done
    (( ${#warns} )) && add ""
    local row=" "
    for (( j = 1; j <= 4; j++ )); do
      if (( j == cur )); then row+="${C_INV}${C_B}  $btn[j]  ${C_R}  "; else row+="[ $btn[j] ]  "; fi
    done
    add "$row"
    add ""
    add " ${C_D}←→ choose · enter confirm · Dry run downloads and checks everything but leaves the EFI alone${C_R}"
    flush_screen; read_key
    case $KEY in
      left|up) (( cur > 1 )) && (( cur-- )) ;; right|down) (( cur < 4 )) && (( cur++ )) ;;
      i) cur=1 ;; d) cur=2 ;; b|esc) REVIEW=back; return ;; q|quit) REVIEW=quit; return ;;
      enter) case $cur in 1) REVIEW=install ;; 2) REVIEW=dry ;; 3) REVIEW=back ;; 4) REVIEW=quit ;; esac; return ;;
    esac
  done
}

# --------------------------------------------------------------------------------------------
# install

# The install is a transaction. Phase 1 downloads, checks and stages every kext in $WORK and edits
# a copy of config.plist; the EFI is not touched, and any problem stops here with nothing changed.
# Phase 2 makes a complete backup, then swaps the staged kexts and the new config.plist in. While
# phase 2 runs, DIRTY=1, and an interruption or failure puts the backup back (see cleanup).

typeset -gi DIRTY=0
typeset -g BACKUP=""
typeset -gA PLAN_OLD EFI_BID
typeset -ga KX
typeset -g BID_RE='^[A-Za-z0-9][A-Za-z0-9._-]{2,119}$'
typeset -g KEXT_RE='^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}\.kext$'
typeset -g EXE_RE='^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$'

# Copies EFI/OC to the state folder; $1 = pre-install or pre-restore. Prints the backup path.
backup_oc() {
  local kind=$1 ts=$(date +%Y%m%d-%H%M%S) dst n=1
  dst="$STATE/backups/$ts"
  while [[ -e $dst ]]; do dst="$STATE/backups/$ts-$(( ++n ))"; done
  mkdir -p "$dst" || return 1
  if ! { ditto "$OC" "$dst/OC" 2>/dev/null || w ditto "$OC" "$dst/OC" }; then
    rm -rf "$dst" 2>/dev/null; return 1
  fi
  {
    print -r -- "date=$ts"; print -r -- "kind=$kind"; print -r -- "efi=$EFI_LABEL"; print -r -- "oc=$OC"
    print -r -- "macos=$MACOS"; print -r -- "opencore=$OCVER"; print -r -- "openkext=$VERSION"
    print -r -- "complete=1"   # written last: a backup without it was interrupted
  } >"$dst/manifest.txt" || return 1
  print -r -- "$dst"
}

manifest() { sed -n "s/^$2=//p" "$1/manifest.txt" 2>/dev/null | head -1 }
backup_ok() { [[ $(manifest "$1" complete) == 1 && -f $1/OC/config.plist ]] }

# Replaces $OC with the OC folder of backup $1 without ever leaving the EFI without an OC folder.
restore_into() {
  local src=$1/OC
  w rm -rf "$OC.openkext-restore" "$OC.openkext-old" 2>/dev/null
  w ditto "$src" "$OC.openkext-restore" || { w rm -rf "$OC.openkext-restore"; return 1 }
  w mv "$OC" "$OC.openkext-old" || return 1
  if ! w mv "$OC.openkext-restore" "$OC"; then w mv "$OC.openkext-old" "$OC"; return 1; fi
  w rm -rf "$OC.openkext-old"
}

# called from cleanup when phase 2 was interrupted or failed
rollback() {
  trap '' INT TERM
  DIRTY=0
  print -r -- "" >&2
  print -r -- "${C_Y}The install did not finish; putting EFI/OC back from $BACKUP...${C_R}" >&2
  if restore_into "$BACKUP"; then
    print -r -- "  ${C_G}✓${C_R} EFI/OC is back to how it was. Nothing was changed." >&2; log "rolled back from $BACKUP"
  else
    print -r -- "${C_RED}Could not put the backup back.${C_R} Copy $BACKUP/OC over $OC by hand before rebooting." >&2
    log "rollback FAILED from $BACKUP"
  fi
}

download_asset() { # url sha dest
  local url=$1 sha=$2 dest=$3 got
  curl -fL --proto '=https,file' --max-time 300 --retry 2 -sS "$url" -o "$dest" || return 1
  got=$(shasum -a 256 "$dest" | awk '{print $1}')
  if [[ $got != $sha ]]; then
    warn "checksum mismatch for ${dest:t}: expected $sha, got $got"
    return 2
  fi
}

# kext bundles in an extracted release, skipping debug symbols, nested kexts and odd paths. Sets KX.
collect_kexts() {
  local root=${1:A} k
  KX=()
  for k in "$root"/**/*.kext(/N); do
    [[ $k == *.dSYM/* || $k == *.kext/*.kext || $k == *[[:cntrl:]]* ]] && continue
    [[ ${k:A} == "$root"/* ]] || continue
    KX+=("$k")
  done
}

kext_ok() { # sanity checks on a kext from a download
  local k=$1 name=${1:t} bid exe
  [[ $name =~ $KEXT_RE ]] || { warn "skipping a kext with an unexpected folder name"; return 1 }
  [[ -f $k/Contents/Info.plist ]] || { warn "skipping $name: no Contents/Info.plist"; return 1 }
  [[ -z $(find "$k" -type l -print -quit) ]] || { warn "skipping $name: contains symbolic links"; return 1 }
  bid=$(plist_get "$k/Contents/Info.plist" CFBundleIdentifier)
  [[ $bid =~ $BID_RE ]] || { warn "skipping $name: missing or invalid bundle identifier"; return 1 }
  exe=$(plist_get "$k/Contents/Info.plist" CFBundleExecutable)
  [[ -z $exe || $exe =~ $EXE_RE ]] || { warn "skipping $name: invalid CFBundleExecutable"; return 1 }
}

# Info.plist of a kext as it will be after the install: staged copy first, then the EFI
kext_info() { [[ -f $WORK/staged/$1/Contents/Info.plist ]] && print -r -- "$WORK/staged/$1/Contents/Info.plist" || print -r -- "$OC/Kexts/$1/Contents/Info.plist" }

cfg_set() { plutil -replace "Kernel.Add.${1}.${2}" "-$3" "$4" "$CFG" 2>/dev/null }

# Stages one kext folder and records its config.plist change in $CFG. $4 = the project's bundle ids.
stage_kext() {
  local k=$1 kid=$2 kver=$3 allowed=" $4 " dry=$5
  local name=${k:t} bid exe old="" f idx bp en
  bid=$(plist_get "$k/Contents/Info.plist" CFBundleIdentifier)
  if [[ $allowed != *" $bid "* ]]; then say "  - $name is not one of this project's kexts ($bid); left out"; return 0; fi
  exe=$(plist_get "$k/Contents/Info.plist" CFBundleExecutable)
  [[ -n $exe && -f $k/Contents/MacOS/$exe ]] && exe="Contents/MacOS/$exe" || exe=""
  local -a olds; olds=()
  for f in ${(k)EFI_BID}; do [[ $EFI_BID[$f] == "$bid" ]] && olds+=("$f"); done
  if (( ${#olds} > 1 )); then
    warn "your EFI has ${#olds} kexts with bundle id $bid (${(j:, :)olds}). Keep one of them and run again."; return 1
  fi
  old=${olds[1]:-}
  if [[ -z $old && -n ${EFI_BID[$name]:-} ]]; then
    warn "Kexts/$name already exists with another bundle id (${EFI_BID[$name]}); not replacing it"; return 1
  fi
  rm -rf "$WORK/staged/$name"
  ditto "$k" "$WORK/staged/$name" || return 1
  PLAN_OLD[$name]=$old
  local verb="will"; (( dry )) && verb="would"
  local v=$(plist_get "$k/Contents/Info.plist" CFBundleShortVersionString)
  if [[ -n $old && $old != $name ]]; then ok "$verb replace Kexts/$old with $name ${v}"
  elif [[ -n $old ]]; then ok "$verb update Kexts/$name to ${v}"
  else ok "$verb add Kexts/$name ${v} ($bid)"; fi
  # config.plist entry: reuse the one for this folder or the folder it replaces
  local found=-1
  while IFS=$TAB read -r idx bp en; do
    [[ $bp == "$name" || ( -n $old && $bp == "$old" ) ]] && { found=$idx; break }
  done < <(cfg_entries "$CFG")
  if (( found >= 0 )); then
    cfg_set $found BundlePath string "$name" && cfg_set $found Enabled bool true \
      && cfg_set $found ExecutablePath string "$exe" || return 1
    ok "$verb update its config.plist entry and enable it"
  else
    # insert before any kext that depends on this one, otherwise at the end
    local n; n=$(plutil -extract Kernel.Add raw -o - "$CFG" 2>/dev/null); [[ $n == <-> ]] || n=0
    local pos=$n dep
    while IFS=$TAB read -r idx bp en; do
      [[ -n $bp && $bp != */* ]] || continue
      for dep in ${(f)"$(plist_get "$(kext_info "$bp")" OSBundleLibraries)"}; do
        [[ $dep == "$bid" ]] && { (( idx < pos )) && pos=$idx; break }
      done
    done < <(cfg_entries "$CFG")
    # every value was checked against a strict pattern, so it is safe inside JSON quotes
    plutil -insert "Kernel.Add.${pos}" -json "{\"Arch\":\"Any\",\"BundlePath\":\"$name\",\"Comment\":\"OpenKext $kid $kver\",\
\"Enabled\":true,\"ExecutablePath\":\"$exe\",\"MaxKernel\":\"\",\"MinKernel\":\"\",\"PlistPath\":\"Contents/Info.plist\"}" \
      "$CFG" 2>/dev/null || return 1
    ok "$verb add a config.plist entry at position $pos"
  fi
  [[ $(plist_get "$CFG" "Kernel.Add.$(( found >= 0 ? found : pos )).BundlePath") == "$name" ]] || return 1
  print -r -- "${name}${TAB}${bid}" >>"$WORK/new-kexts"
}

# warns about dependencies that are neither in macOS nor in the EFI after the install
check_deps() {
  local name bid dep f
  local -A present
  for f in ${(k)EFI_BID}; do
    present[$EFI_BID[$f]]=1
  done
  [[ -f $WORK/new-kexts ]] || return 0
  while IFS=$TAB read -r name bid; do present[$bid]=1; done <"$WORK/new-kexts"
  while IFS=$TAB read -r name bid; do
    for dep in ${(f)"$(plist_get "$WORK/staged/$name/Contents/Info.plist" OSBundleLibraries)"}; do
      [[ $dep =~ $BID_RE ]] || continue
      [[ $dep == com.apple.* || -n ${present[$dep]:-} ]] && continue
      warn "$name needs $dep, which is not in your EFI. Add the kext that provides it before rebooting."
    done
  done <"$WORK/new-kexts"
}

prepare() { # phase 1; returns 1 when anything failed
  local dry=$1 i j failed=0 k f bid
  CFG=$WORK/config.plist
  cp "$OC/config.plist" "$CFG" || die "could not read $OC/config.plist"
  plutil -lint -s "$CFG" || die "your config.plist does not validate as it is; fix it before installing anything"
  rm -rf "$WORK/dl" "$WORK/staged" "$WORK/x"; mkdir -p "$WORK/dl" "$WORK/staged"
  : >"$WORK/new-kexts"
  PLAN_OLD=() EFI_BID=()
  for f in "$OC"/Kexts/*.kext; do
    bid=$(plist_get "$f/Contents/Info.plist" CFBundleIdentifier) && [[ -n $bid ]] && EFI_BID[${f:t}]=$bid
  done
  for (( i = 1; i <= ${#K_ID}; i++ )); do
    (( SEL[i] )) || continue
    say ""; say "${C_B}$K_NAME[i]${C_R} $K_VER[i]"
    local -a as; as=("${(@s:;:)K_ASSETS[i]}")
    for (( j = 1; j <= ${#as}; j++ )); do
      [[ ${ASEL[i][j]} == 1 ]] || continue
      local -a p; p=("${(@s:,:)as[j]}")
      [[ $p[1] == *.zip ]] || { warn "$p[1] is not a zip; skipping it"; failed=1; continue }
      local url="$K_SRC[i]/releases/download/$K_TAG[i]/$p[1]"
      [[ -n ${OPENKEXT_ASSET_BASE:-} ]] && url="$OPENKEXT_ASSET_BASE/$K_ID[i]/$p[1]"
      local dest="$WORK/dl/$K_ID[i]-$p[1]"
      if ! download_asset "$url" "$p[2]" "$dest"; then
        warn "$p[1]: download failed or did not match the catalog"; failed=1; continue
      fi
      ok "downloaded $p[1], SHA-256 matches the catalog"
      local x="$WORK/x/$K_ID[i]-$j"
      mkdir -p "$x"
      ditto -x -k "$dest" "$x" 2>/dev/null || { warn "could not unpack $p[1]"; failed=1; continue }
      collect_kexts "$x"
      local staged=0
      for k in $KX; do
        kext_ok "$k" || continue
        stage_kext "$k" "$K_ID[i]" "$K_VER[i]" "$K_BUNDLES[i]" "$dry" || { warn "could not prepare ${k:t}"; failed=1; continue }
        [[ -d $WORK/staged/${k:t} ]] && staged=1
      done
      (( staged )) || { warn "$p[1] holds none of this project's kexts"; failed=1 }
    done
  done
  check_deps
  plutil -lint -s "$CFG" || { warn "the edited config.plist does not validate"; failed=1 }
  return $failed
}

commit() { # phase 2
  local name old
  (( NEED_SUDO )) && { sudo -v || die "sudo was not granted; nothing was changed" }
  BACKUP=$(backup_oc pre-install) || die "the backup failed; nothing was changed"
  ok "backup of EFI/OC in $BACKUP"
  DIRTY=1
  for name in ${(k)PLAN_OLD}; do
    w rm -rf "$OC/Kexts/.openkext-new-$name"
    w ditto "$WORK/staged/$name" "$OC/Kexts/.openkext-new-$name" || { warn "could not copy $name to the EFI"; exit 1 }
  done
  for name in ${(k)PLAN_OLD}; do
    old=$PLAN_OLD[$name]
    [[ -n $old ]] && { w rm -rf "$OC/Kexts/$old" || exit 1 }
    w rm -rf "$OC/Kexts/$name" || exit 1
    w mv "$OC/Kexts/.openkext-new-$name" "$OC/Kexts/$name" || exit 1
  done
  [[ -n ${OPENKEXT_TEST_FAIL_COMMIT:-} ]] && exit 1   # tests: fail halfway through phase 2
  w cp "$CFG" "$OC/config.plist.openkext-tmp" || exit 1
  plutil -lint -s "$OC/config.plist.openkext-tmp" || exit 1
  w mv "$OC/config.plist.openkext-tmp" "$OC/config.plist" || exit 1
  DIRTY=0
  ok "kexts copied and config.plist written"
}

do_install() {
  local dry=$1 i
  print -r -- ""
  if (( dry )); then say "${C_B}Dry run${C_R}: downloads and checks everything; the EFI is not changed."
  else say "${C_B}Preparing${C_R} (the EFI is not touched until everything is ready)"; fi
  local failed=0
  prepare $dry || failed=1
  if (( dry )); then
    cp "$CFG" "$STATE/dry-run-config.plist" 2>/dev/null
    say ""
    (( failed )) && warn "a real install would stop here, because of the problems above"
    ok "dry run finished; the config.plist it would write is in $STATE/dry-run-config.plist"
    return $failed
  fi
  (( failed )) && die "stopped because of the problems above; nothing was changed"
  (( ${#PLAN_OLD} )) || { say "Nothing to install."; return 0 }
  say ""; say "${C_B}Installing${C_R} into $OC"
  commit
  say ""
  say "${C_B}Done.${C_R} Reboot to load the new drivers."
  say "If the machine does not boot: start it from your USB installer, mount this EFI and copy"
  say "  $BACKUP/OC"
  say "over EFI/OC (the backup is on your macOS disk). Once back in macOS, 'openkext --restore' does the same."
  for (( i = 1; i <= ${#K_ID}; i++ )); do
    (( SEL[i] )) && say "After testing, tell others how it went: $API/kext/$K_ID[i]/"
  done
  return 0
}

do_restore() {
  locate_efi 1 || die "could not find the EFI. Mount it and pass --efi /Volumes/EFI"
  tui_close
  local -a backups labels cand; local b kind oc
  for b in "$STATE"/backups/*(/On); do
    backup_ok "$b" || continue
    kind=$(manifest "$b" kind); oc=$(manifest "$b" oc)
    [[ $oc == "$OC" ]] || continue
    [[ $kind == pre-restore ]] && continue
    backups+=("$b"); labels+=("${b:t}  before an install")
  done
  # backups taken before a restore come last: picking one undoes a restore
  for b in "$STATE"/backups/*(/On); do
    backup_ok "$b" && [[ $(manifest "$b" oc) == "$OC" && $(manifest "$b" kind) == pre-restore ]] || continue
    backups+=("$b"); labels+=("${b:t}  before a restore (undoes that restore)")
  done
  (( ${#backups} )) || die "no complete backups of $OC in $STATE/backups"
  if (( O_YES )); then REPLY_IDX=1
  else tui_menu "Restore which backup into $OC?" "The current EFI/OC is backed up first." $labels || exit 0; tui_close; fi
  b=$backups[REPLY_IDX]
  (( NEED_SUDO )) && { say "Writing to the EFI needs administrator rights."; sudo -v || exit 1 }
  local pre; pre=$(backup_oc pre-restore) || die "could not back up the current EFI/OC; nothing was changed"
  ok "current EFI/OC saved in $pre"
  restore_into "$b" || die "restore failed; $OC is unchanged or still in $OC.openkext-old"
  ok "restored ${b:t} into $OC"
}

print_list() {
  local i
  print -r -- "macOS $MACOS · OpenCore ${OCVER:-not detected} · EFI $EFI_LABEL"
  print -r -- "$(wc -l <"$WORK/hw.tsv" | tr -d ' ') PCI/USB devices detected"
  print -r -- ""
  local shown=0
  for (( i = 1; i <= ${#K_ID}; i++ )); do
    (( O_ALL )) || [[ $K_GROUP[i] != other ]] || continue
    shown=1
    local mark=" "; (( K_REC[i] )) && mark="*"
    print -r -- "$mark $K_ID[i]  [$K_STATUS[i]]  $(action_text $i)"
    [[ -n $K_WHY[i] ]] && print -r -- "    $K_WHY[i]"
  done
  (( shown )) || print -r -- "No catalog driver matches this hardware. --all lists the whole catalog."
  print -r -- ""
  print -r -- "* = recommended (matches, tested on this macOS, has test reports)"
}

main() {
  parse_args "$@"
  mkdir -p "$STATE" 2>/dev/null
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/openkext.XXXXXX") || die "mktemp failed"
  log "start $VERSION args: $*"
  detect_system
  if (( O_RESTORE )); then do_restore; return; fi
  if [[ -z $OCVER && -z $O_EFI ]] && (( ! O_LIST )); then
    die "OpenCore was not detected (no opencore-version in NVRAM). If you boot with OpenCore, pass --efi /Volumes/EFI."
  fi
  print -r -- "${C_D}Looking at this machine...${C_R}"
  detect_hw
  if ! locate_efi $(( ! O_LIST )); then
    (( O_LIST )) || die "could not find the OpenCore EFI. Mount it (sudo diskutil mount disk0s1) and pass --efi /Volumes/EFI"
  fi
  detect_installed
  print -r -- "${C_D}Reading the catalog from $API...${C_R}"
  load_catalog
  if (( O_LIST )); then print_list; return; fi
  if (( O_YES )); then
    local i n=0; for i in $SEL; do (( i )) && (( n++ )); done
    (( n )) || { say "Nothing recommended to install. Run without --yes to pick by hand, or --list to see why."; return 0 }
    do_install $O_DRY; return
  fi
  while true; do
    tui_select || { tui_close; say "Nothing was changed."; return 0 }
    tui_review
    case $REVIEW in
      back) continue ;;
      quit) tui_close; say "Nothing was changed."; return 0 ;;
      dry) tui_close; do_install 1; return ;;
      install) tui_close; do_install 0; return ;;
    esac
  done
}

trap cleanup EXIT
trap 'exit 130' INT TERM
main "$@"
