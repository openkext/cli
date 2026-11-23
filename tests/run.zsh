#!/bin/zsh
# SPDX-License-Identifier: MIT
# Tests for openkext.zsh. Everything runs against a fake EFI, a local catalog and fake
# ioreg output in a temporary folder; nothing on the machine is read or changed.
emulate -R zsh
setopt null_glob typeset_silent

HERE=${0:A:h}
TOOL=$HERE/../openkext.zsh
T=$(mktemp -d "${TMPDIR:-/tmp}/openkext-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
PB=/usr/libexec/PlistBuddy
typeset -i PASS=0 FAIL=0

ok() { (( PASS++ )); print -r -- "ok   $1" }
bad() { (( FAIL++ )); print -r -- "FAIL $1"; [[ -n ${2:-} ]] && print -r -- "$2" | sed 's/^/     /' | head -40 }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "${OUT:-}"; fi }
has() { [[ $OUT == *"$1"* ]] }
hasnt() { [[ $OUT != *"$1"* ]] }

# --- fixtures -------------------------------------------------------------------------------

mkkext() { # dir name bundleid version [dep...]
  local dir=$1 name=$2 bid=$3 ver=$4; shift 4
  local k=$dir/$name.kext
  mkdir -p "$k/Contents/MacOS"
  print -r -- "binary $bid $ver" >"$k/Contents/MacOS/$name"
  local libs="" d
  for d in "$@"; do libs+="<key>$d</key><string>1.0</string>"; done
  cat >"$k/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bid</string>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleShortVersionString</key><string>$ver</string>
<key>OSBundleLibraries</key><dict>$libs<key>com.apple.kpi.iokit</key><string>8.0</string></dict>
</dict></plist>
EOF
}

zipdir() { (cd "$1" && ditto -c -k --keepParent "${3:-.}" "$2") }

make_efi() {
  rm -rf "$T/efi"
  mkdir -p "$T/efi/EFI/OC/Kexts"
  mkkext "$T/efi/EFI/OC/Kexts" Lilu as.vit9696.Lilu 1.7.0
  mkkext "$T/efi/EFI/OC/Kexts" WifiPlugin com.other.WifiPlugin 1.0 com.demo.Wifi
  cat >"$T/efi/EFI/OC/config.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DeviceProperties</key><dict><key>Add</key><dict><key>PciRoot(0x0)/Pci(0x2,0x0)</key><dict>
    <key>AAPL,ig-platform-id</key><data>BwCbPg==</data></dict></dict></dict>
  <key>Kernel</key>
  <dict>
    <key>Add</key>
    <array>
      <dict><key>Arch</key><string>Any</string><key>BundlePath</key><string>Lilu.kext</string>
        <key>Comment</key><string></string><key>Enabled</key><true/>
        <key>ExecutablePath</key><string>Contents/MacOS/Lilu</string><key>MaxKernel</key><string></string>
        <key>MinKernel</key><string></string><key>PlistPath</key><string>Contents/Info.plist</string></dict>
      <dict><key>Arch</key><string>Any</string><key>BundlePath</key><string>WifiPlugin.kext</string>
        <key>Comment</key><string></string><key>Enabled</key><true/>
        <key>ExecutablePath</key><string>Contents/MacOS/WifiPlugin</string><key>MaxKernel</key><string></string>
        <key>MinKernel</key><string></string><key>PlistPath</key><string>Contents/Info.plist</string></dict>
    </array>
  </dict>
  <key>Misc</key><dict><key>Security</key><dict><key>Vault</key><string>Optional</string></dict></dict>
</dict>
</plist>
EOF
}

make_assets() {
  rm -rf "$T/assets" "$T/src"
  mkdir -p "$T/assets/demo-wifi" "$T/assets/broken-bt" "$T/assets/other-kext" "$T/src/tahoe" "$T/src/sequoia" "$T/src/bt" "$T/src/other"
  mkkext "$T/src/tahoe" DemoWifi com.demo.Wifi 2.0 as.vit9696.Lilu
  mkdir -p "$T/src/tahoe/DemoWifi.kext.dSYM/Contents"
  mkkext "$T/src/sequoia" DemoWifi com.demo.Wifi 2.0-seq
  mkkext "$T/src/bt" DemoBT com.demo.BT 2.0 com.missing.Dependency
  mkkext "$T/src/other" Other com.other.Thing 0.1
  zipdir "$T/src/tahoe" "$T/assets/demo-wifi/DemoWifi-Tahoe.zip"
  zipdir "$T/src/sequoia" "$T/assets/demo-wifi/DemoWifi-Sequoia.zip"
  zipdir "$T/src/bt" "$T/assets/demo-wifi/DemoBT.zip"
  zipdir "$T/src/bt" "$T/assets/broken-bt/BrokenBT.zip"
  zipdir "$T/src/other" "$T/assets/other-kext/Other.zip"
}

sha() { shasum -a 256 "$1" | awk '{print $1}' }

# $1: sha for DemoBT.zip (defaults to the real one); $2: extra name text
make_catalog() {
  local btsha=${1:-$(sha "$T/assets/demo-wifi/DemoBT.zip")} extra=${2:-}
  mkdir -p "$T/api"
  cat >"$T/api/catalog.json" <<EOF
{"schema": 1, "kexts": [
 {"id": "demo-wifi", "name": "Demo Wifi$extra", "summary": "A demo wifi driver.", "kind": "kext",
  "categories": ["wifi"], "source": "https://github.com/alice/demo-wifi", "license": "MIT",
  "maintainers": ["alice"], "ai_disclosure": "none", "bundle_ids": ["com.demo.Wifi", "com.demo.BT"],
  "hardware": [{"vendor": "intel", "description": "Intel AX210", "pci_ids": ["8086:2725"], "usb_ids": ["8087:0032"]}],
  "macos": {"min": "15.8", "max": "26.7"},
  "releases": [
   {"version": "1.0", "tag": "v1.0", "date": "2026-10-01", "assets": [{"name": "Old.zip", "sha256": "$(printf 'a%.0s' {1..64})"}]},
   {"version": "2.0", "tag": "v2.0", "date": "2026-11-01", "notes": "new", "assets": [
     {"name": "DemoWifi-Tahoe.zip", "sha256": "$(sha "$T/assets/demo-wifi/DemoWifi-Tahoe.zip")", "macos": "26"},
     {"name": "DemoWifi-Sequoia.zip", "sha256": "$(sha "$T/assets/demo-wifi/DemoWifi-Sequoia.zip")", "macos": "15"},
     {"name": "DemoBT.zip", "sha256": "$btsha"}]}],
  "status": {"status": "author-tested", "release": "2.0"}},
 {"id": "broken-bt", "name": "Broken BT", "summary": "Reported broken.", "kind": "kext", "categories": ["bluetooth"],
  "source": "https://github.com/bob/broken-bt", "license": "MIT", "maintainers": ["bob"], "ai_disclosure": "none",
  "hardware": [{"vendor": "intel", "description": "Intel BT", "usb_ids": ["8087:0032"]}],
  "macos": {"min": "15.0", "max": "26.7"},
  "releases": [{"version": "0.3", "tag": "v0.3", "date": "2026-11-02", "assets": [
     {"name": "BrokenBT.zip", "sha256": "$(sha "$T/assets/broken-bt/BrokenBT.zip")"}]}],
  "status": {"status": "reported-broken"}},
 {"id": "other-kext", "name": "Other \u001b[2Jkext", "summary": "Not for this hardware.", "kind": "kext", "categories": ["other"],
  "source": "https://github.com/carol/other", "license": "MIT", "maintainers": ["carol"], "ai_disclosure": "none",
  "macos": {"min": "14.0", "max": "26.7"},
  "releases": [{"version": "0.1", "tag": "v0.1", "date": "2026-11-03", "assets": [
     {"name": "Other.zip", "sha256": "$(sha "$T/assets/other-kext/Other.zip")"}]}],
  "status": {"status": "submitted"}},
 {"id": "bad-path", "name": "Bad", "summary": "x", "kind": "kext", "categories": ["other"],
  "source": "https://github.com/eve/bad", "license": "MIT", "maintainers": ["eve"], "ai_disclosure": "none",
  "macos": {"min": "14.0", "max": "26.7"},
  "releases": [{"version": "1", "tag": "v1", "date": "2026-11-03", "assets": [
     {"name": "../../etc/x.zip", "sha256": "$(printf 'b%.0s' {1..64})"}]}],
  "status": {"status": "community-verified"}},
 {"id": "seq-only", "name": "Sequoia only", "summary": "x", "kind": "kext", "categories": ["other"],
  "source": "https://github.com/dan/seq", "license": "MIT", "maintainers": ["dan"], "ai_disclosure": "none",
  "macos": {"min": "15.0", "max": "15.7"},
  "releases": [{"version": "1", "tag": "v1", "date": "2026-11-03", "assets": [
     {"name": "Seq.zip", "sha256": "$(printf 'd%.0s' {1..64})", "macos": "15"}]}],
  "status": {"status": "submitted"}},
 {"id": "a-doc", "name": "Docs", "summary": "x", "kind": "docs", "categories": ["other"],
  "source": "https://github.com/eve/docs", "license": "MIT", "maintainers": ["eve"], "ai_disclosure": "none",
  "macos": {"min": "14.0", "max": "26.7"}, "releases": [], "status": {"status": "submitted"}}
]}
EOF
}

cat >"$T/pci.txt" <<'EOF'
+-o PXSX@0  <class IOPCIDevice, id 0x100000300, registered, matched, active, busy 0 (5 ms), retain 12>
    {
      "IOName" = "pci8086,2725"
      "vendor-id" = <86800000>
      "device-id" = <25270000>
      "class-code" = <00800200>
    }
+-o GFX0@2  <class IOPCIDevice, id 0x100000301, registered, matched, active, busy 0 (5 ms), retain 12>
      "vendor-id" = <86800000>
      "device-id" = <9b3e0000>
EOF
cat >"$T/usb.txt" <<'EOF'
+-o AX210 Bluetooth@14100000  <class IOUSBHostDevice, id 0x100000400, registered, matched, active, busy 0 (5 ms), retain 20>
      "idProduct" = 50
      "idVendor" = 32903
EOF
cat >"$T/kmutil.txt" <<'EOF'
  101    0 0xffffff7f9 0x5000     0x5000     as.vit9696.Lilu (1.7.0) 11111111-2222-3333-4444-555555555555 <8 6 5 3 2 1>
  102    0 0xffffff7f9 0x5000     0x5000     com.apple.driver.Foo (1.0) 11111111-2222-3333-4444-555555555556 <1>
EOF

export NO_COLOR=1 OPENKEXT_API="file://$T/api" OPENKEXT_ASSET_BASE="file://$T/assets" OPENKEXT_STATE="$T/state" \
  OPENKEXT_MACOS=26.7.2 OPENKEXT_ARCH=x86_64 OPENKEXT_OCVER=1.0.4 OPENKEXT_IOREG_PCI="$T/pci.txt" \
  OPENKEXT_IOREG_USB="$T/usb.txt" OPENKEXT_KMUTIL="$T/kmutil.txt" OPENKEXT_NO_SUDO=1
unset OPENKEXT_KEYS

run() { OUT=$(zsh "$TOOL" "$@" 2>&1); RC=$? }
cfg() { $PB -c "Print :Kernel:Add:${1}:${2}" "$T/efi/EFI/OC/config.plist" 2>/dev/null }
efihash() { find "$T/efi" -type f -exec shasum {} + | sort | shasum | awk '{print $1}' }

make_efi; make_assets; make_catalog

# --- list -----------------------------------------------------------------------------------

run --list --efi "$T/efi"
check "list exits 0" test $RC -eq 0
check "list recommends the matching tested driver" has "* demo-wifi  [author-tested]  install 2.0"
check "list explains the match" has "matches Intel AX210 (8086:2725)"
check "list shows broken driver without recommending it" has "  broken-bt  [reported-broken]"
check "list hides unmatched drivers" hasnt "other-kext"
check "list skips docs and unsafe asset names" eval 'hasnt "a-doc" && hasnt "bad-path"'
run --list --all --efi "$T/efi"
check "--all shows unmatched drivers" has "other-kext  [submitted]"
check "catalog control characters never reach the terminal" eval '[[ $OUT != *$'"'"'\e'"'"'* ]]'

# --- dry run ----------------------------------------------------------------------------------

before=$(efihash)
run --yes --dry-run --efi "$T/efi"
check "dry run exits 0" test $RC -eq 0
check "dry run leaves the EFI alone" test "$before" = "$(efihash)"
check "dry run verifies checksums" has "downloaded DemoWifi-Tahoe.zip, SHA-256 matches the catalog"
check "dry run skips the asset for another macOS" hasnt "DemoWifi-Sequoia.zip"
check "dry run reports the planned change" has "would add Kexts/DemoWifi.kext (com.demo.Wifi)"
check "dry run writes the config it would use" test -f "$T/state/dry-run-config.plist"
check "dry run makes no backup" test ! -d "$T/state/backups"

# --- install ----------------------------------------------------------------------------------

run --yes --efi "$T/efi"
check "install exits 0" test $RC -eq 0
check "kext copied" test -f "$T/efi/EFI/OC/Kexts/DemoWifi.kext/Contents/Info.plist"
check "dSYM not copied" test ! -e "$T/efi/EFI/OC/Kexts/DemoWifi.kext.dSYM"
check "second asset copied" test -d "$T/efi/EFI/OC/Kexts/DemoBT.kext"
check "Tahoe build chosen" grep -q "2.0<" "$T/efi/EFI/OC/Kexts/DemoWifi.kext/Contents/Info.plist"
check "new kext goes before the kext that depends on it" test "$(cfg 1 BundlePath)" = "DemoWifi.kext"
check "dependent kext moved after it" test "$(cfg 2 BundlePath)" = "WifiPlugin.kext"
check "Lilu stays first" test "$(cfg 0 BundlePath)" = "Lilu.kext"
check "entry is enabled with executable path" eval '[[ $(cfg 1 Enabled) == true && $(cfg 1 ExecutablePath) == Contents/MacOS/DemoWifi ]]'
check "entry has a comment" test "$(cfg 1 Comment)" = "OpenKext demo-wifi 2.0"
check "config.plist still valid" plutil -lint -s "$T/efi/EFI/OC/config.plist"
check "other config data preserved" eval '[[ $($PB -c "Print :Misc:Security:Vault" "$T/efi/EFI/OC/config.plist") == Optional ]]'
check "missing dependency is reported" has "DemoBT.kext needs com.missing.Dependency"
check "backup made" eval 'b=("$T"/state/backups/*/OC/config.plist); (( ${#b} == 1 ))'
check "unmatched driver not installed" test ! -d "$T/efi/EFI/OC/Kexts/Other.kext"

run --list --efi "$T/efi"
check "installed driver shows as up to date" has "demo-wifi  [author-tested]  up to date (2.0)"

# --- update replaces by bundle id -------------------------------------------------------------

make_efi
mkkext "$T/efi/EFI/OC/Kexts" OldWifiName com.demo.Wifi 1.0
$PB -c "Add :Kernel:Add:2 dict" -c "Add :Kernel:Add:2:BundlePath string OldWifiName.kext" \
    -c "Add :Kernel:Add:2:Enabled bool false" -c "Add :Kernel:Add:2:ExecutablePath string Contents/MacOS/OldWifiName" \
    "$T/efi/EFI/OC/config.plist" >/dev/null
run --list --efi "$T/efi"
check "older install is offered as an update" has "update 1.0 → 2.0"
run --yes --efi "$T/efi"
check "update exits 0" test $RC -eq 0
check "old folder removed" test ! -d "$T/efi/EFI/OC/Kexts/OldWifiName.kext"
check "entry renamed in place, not duplicated" eval '[[ $(cfg 2 BundlePath) == DemoWifi.kext && $(cfg 2 Enabled) == true ]] && ! $PB -c "Print :Kernel:Add:4" "$T/efi/EFI/OC/config.plist" >/dev/null 2>&1'
check "executable path updated" test "$(cfg 2 ExecutablePath)" = "Contents/MacOS/DemoWifi"

# --- checksum mismatch ------------------------------------------------------------------------

make_efi; rm -rf "$T/state"
make_catalog "$(printf 'c%.0s' {1..64})"
run --yes --efi "$T/efi"
check "mismatch makes the run fail" test $RC -ne 0
check "mismatch is explained" has "checksum mismatch for demo-wifi-DemoBT.zip"
check "bad file not installed" test ! -d "$T/efi/EFI/OC/Kexts/DemoBT.kext"
check "good file still installed" test -d "$T/efi/EFI/OC/Kexts/DemoWifi.kext"
make_catalog

# --- restore ----------------------------------------------------------------------------------

run --restore --yes --efi "$T/efi"
check "restore exits 0" test $RC -eq 0
check "restore brings back the pre-install EFI" test ! -d "$T/efi/EFI/OC/Kexts/DemoWifi.kext"
check "restore keeps a backup of what it replaced" eval 'b=("$T"/state/backups/*); (( ${#b} == 2 ))'

# --- interactive ------------------------------------------------------------------------------

make_efi; rm -rf "$T/state"
keys() { print -rn -- "$1" >"$T/keys"; OPENKEXT_KEYS="$T/keys" run --efi "$T/efi"; }
keys "q"
check "quit changes nothing" eval 'has "Nothing was changed." && [[ ! -d $T/efi/EFI/OC/Kexts/DemoWifi.kext ]]'
# unselect demo-wifi, show all, go to other-kext, select it, continue, choose Dry run
keys " a"$'\e[B\e[B'" "$'\n'"d"$'\n'
check "interactive dry run" has "Dry run"
check "interactive selection is honoured" eval 'has "Other" && hasnt "DemoWifi-Tahoe.zip"'
check "interactive dry run changed nothing" test ! -d "$T/efi/EFI/OC/Kexts/Other.kext"
# accept the recommended selection and install
keys $'\n\n'
check "interactive install" eval 'has "Done." && [[ -d $T/efi/EFI/OC/Kexts/DemoWifi.kext ]]'
# the asset picker can drop the Bluetooth file
make_efi
keys $'\e[C\e[B\e[B \n\n\n'
check "asset picker drops a file" eval '[[ -d $T/efi/EFI/OC/Kexts/DemoWifi.kext && ! -d $T/efi/EFI/OC/Kexts/DemoBT.kext ]]'
# nothing selected: enter is refused with a hint, then quit
make_efi
keys " "$'\n'"q"
check "empty selection is refused" has "Select at least one driver"

# --- guards -----------------------------------------------------------------------------------

OPENKEXT_ARCH=arm64 run --list
check "Apple Silicon is refused" eval '(( RC != 0 )) && has "Apple Silicon"'
OPENKEXT_OCVER= run --yes
check "missing OpenCore is refused without --efi" eval '(( RC != 0 )) && has "OpenCore was not detected"'
OPENKEXT_MACOS=11.7 run --list
check "old macOS is refused" eval '(( RC != 0 )) && has "too old"'
run --bogus
check "unknown option is refused" eval '(( RC != 0 )) && has "unknown option"'
OPENKEXT_MACOS=14.6 run --list --efi "$T/efi"
check "driver outside its tested macOS range is not recommended" eval 'has "  demo-wifi  [author-tested]" && hasnt "* demo-wifi"'
OPENKEXT_MACOS=26.1 run --list --all --efi "$T/efi"
check "driver with only a build for another macOS says so" has "no build for macOS 26"
run --list --efi /nonexistent
check "bad --efi path is refused" eval '(( RC != 0 )) && has "does not contain EFI/OC/config.plist"'

print -r -- ""
print -r -- "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
