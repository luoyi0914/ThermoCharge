#!/usr/bin/env sh
# 真安装脚本的隔离迁移回归：不需要 root，不接触真实 /data 或充电节点。
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/tc-migrate.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$3], got [$2]"; fi; }
value() { grep "^$2=" "$T/$1/data/config.conf" | cut -d= -f2-; }
clean() {
  if grep -Eq '^[[:space:]]*(power_mode|kp|ki|kd|deadband|tdot_tau_s|min_regulate_ma|soft_landing|soft_margin|soft_band|soft_[a-z_0-9]+|pred_[a-z_0-9]+)[[:space:]]*=' "$T/$1/data/config.conf"; then
    bad "$1 has retired parameters"
  else
    ok "$1 has no retired parameters"
  fi
}
mkcase() {
  d=$T/$1
  mkdir -p "$d/mod/bin" "$d/data/log"
  cp "$ROOT/module/customize.sh" "$ROOT/module/config.conf" "$d/mod/"
  if [ "${2:-}" = profiles ]; then cp -R "$ROOT/module/profiles" "$d/mod/profiles"; fi
  printf '#!/system/bin/sh\nprintf "fixture-version\\n"\n' > "$d/mod/bin/thermocharge"
  chmod 0755 "$d/mod/bin/thermocharge"
  sed -i "s#^DATA=/data/adb/thermocharge#DATA=$d/data#" "$d/mod/customize.sh"
  cat > "$d/stubs.sh" <<EOF
ui_print() { printf '%s\n' "\$*"; }
set_perm() { :; }
set_perm_recursive() { :; }
abort() { printf 'ABORT: %s\n' "\$*" >&2; exit 1; }
getprop() { case "\$1" in
  ro.product.cpu.abi) printf 'arm64-v8a\n' ;;
  ro.product.marketname) cat "$d/model" 2>/dev/null ;;
esac; }
MODPATH=$d/mod
EOF
}
runinstall() {
  (cd "$T/$1" && sh -c '. ./stubs.sh; . ./mod/customize.sh') > "$T/$1/out.txt" 2>&1
}

# 每个旧版本都必须转为同一控制器，不恢复模型，不提高用户选定的上限。
for version in 0 1 4 5 6 7 5.0 abc 99; do
  name=v$version
  mkcase "$name"
  cat > "$T/$name/data/config.conf" <<EOF
# 用户注释保留
cfg_version=$version
enabled=0
dry_run=1
target_temp=42.3
hard_temp=44.1
max_ma=8000
min_ma=700
startup_grace_ms=12345
ctl_mode=2
power_max_w=37
mca_tag=my tag
mca_type=all
power_mode=0
kp=5
ki=120
kd=80 # 旧参数注释保留
# pred_alpha=0.9 是历史说明，不应执行或删除
deadband=0.2
tdot_tau_s=8
pred_enable=1
pred_alpha=0.178
pred_tau_s=220
pred_ambient=25
pred_future_key=1
min_regulate_ma=9000
soft_landing=1
soft_margin=0.8
soft_band=0.7
soft_future=1
unknown_user_key=keep
EOF
  chmod 0600 "$T/$name/data/config.conf"
  runinstall "$name"
  clean "$name"
  if [ "$version" = 99 ]; then want_version=99; else want_version=7; fi
  check "$name schema version" "$(value "$name" cfg_version)" "$want_version"
  for pair in 'enabled 0' 'dry_run 1' 'target_temp 42.3' 'hard_temp 44.1' 'max_ma 8000' 'min_ma 700' 'startup_grace_ms 12345' 'ctl_mode 2' 'power_max_w 37' 'unknown_user_key keep'; do
    key=${pair%% *}; want=${pair#* }
    check "$name preserves $key" "$(value "$name" "$key")" "$want"
  done
  check "$name preserves identity whitespace" "$(value "$name" mca_tag)" 'my tag'
  check "$name preserves comments" "$(grep -c '^# 用户注释保留$' "$T/$name/data/config.conf")" 1
  check "$name preserves retired inline comment" "$(grep -c '^# 旧参数注释保留$' "$T/$name/data/config.conf")" 1
  check "$name preserves full comment with equals" "$(grep -c '^# pred_alpha=0.9 是历史说明，不应执行或删除$' "$T/$name/data/config.conf")" 1
  check "$name private permissions" "$(stat -c %a "$T/$name/data/config.conf")" 600
  check "$name backup retains old model for inspection" "$(grep -c '^pred_alpha=' "$T/$name/data/config.conf.bak")" 1
  before=$(sha256sum "$T/$name/data/config.conf" | cut -d' ' -f1)
  runinstall "$name"
  check "$name repeated install is idempotent" "$(sha256sum "$T/$name/data/config.conf" | cut -d' ' -f1)" "$before"
done

mkcase fresh
runinstall fresh
check 'fresh schema version' "$(value fresh cfg_version)" 7
check 'fresh automatic power ceiling' "$(value fresh power_max_w)" 0
clean fresh
check 'fresh config permissions' "$(stat -c %a "$T/fresh/data/config.conf")" 600

mkcase nonl
printf 'cfg_version=6\npred_ambient=50\npred_ambient=12\n kd = 15\nmca_type=all' > "$T/nonl/data/config.conf"
runinstall nonl
clean nonl
check 'no newline preserves last live key' "$(value nonl mca_type)" all
check 'no newline appends power ceiling independently' "$(value nonl power_max_w)" 0
check 'no newline schema version' "$(value nonl cfg_version)" 7

for model in ultra pro unknown; do
  mkcase "$model" profiles
  case "$model" in
    ultra) text='REDMI K90 Ultra'; profile=k90-ultra ;;
    pro) text='REDMI K90 Pro Max'; profile=k90-pro-max ;;
    *) text='Unknown Phone'; profile=k90-ultra ;;
  esac
  printf '%s\n' "$text" > "$T/$model/model"
  # 即使旧档案残留模型字段，白名单也不能让它们重新进入配置。
  printf '\npred_alpha=0.2\nki=99\npower_mode=0\n' >> "$T/$model/mod/profiles/$profile.conf"
  runinstall "$model"
  clean "$model"
  check "$model profile target" "$(value "$model" target_temp)" 44.6
  check "$model profile hard limit" "$(value "$model" hard_temp)" 46.0
  check "$model profile current boundary" "$(value "$model" max_ma)" 12000
  check "$model profile slew" "$(value "$model" slew_ma_s)" 750
  check "$model profile identity" "$(grep '^profile=' "$T/$model/data/device.profile" | cut -d= -f2)" "$profile"
done

# 失败不能标记成功，也不能留下半份新配置。
mkcase failed
printf 'cfg_version=6\ntarget_temp=42\npred_alpha=0.178\n' > "$T/failed/data/config.conf"
chmod 0600 "$T/failed/data/config.conf"
before=$(sha256sum "$T/failed/data/config.conf" | cut -d' ' -f1)
printf '\nmv() { return 1; }\n' >> "$T/failed/stubs.sh"
if runinstall failed; then bad 'failed migration must abort'; else ok 'failed migration aborts'; fi
check 'failed migration rolls back bytes' "$(sha256sum "$T/failed/data/config.conf" | cut -d' ' -f1)" "$before"
check 'failed migration retains private permissions' "$(stat -c %a "$T/failed/data/config.conf")" 600

# 最后写版本号才失败，不能漏过统一回滚检查。
mkcase version_failed
printf 'cfg_version=6\ntarget_temp=42\npower_max_w=0\npred_alpha=0.178\n' > "$T/version_failed/data/config.conf"
chmod 0600 "$T/version_failed/data/config.conf"
before=$(sha256sum "$T/version_failed/data/config.conf" | cut -d' ' -f1)
cat >> "$T/version_failed/stubs.sh" <<'EOF'
mv() {
  if grep -q '^cfg_version=7$' "$2"; then return 1; fi
  command mv "$@"
}
EOF
if runinstall version_failed; then bad 'version-only write failure must abort'; else ok 'version-only write failure aborts'; fi
check 'version-only failure rolls back bytes' "$(sha256sum "$T/version_failed/data/config.conf" | cut -d' ' -f1)" "$before"
check 'version-only failure retains private permissions' "$(stat -c %a "$T/version_failed/data/config.conf")" 600

# 备份失败时必须在任何配置写入之前停手。
mkcase backup_failed
printf 'cfg_version=6\ntarget_temp=42\npred_alpha=0.178\n' > "$T/backup_failed/data/config.conf"
chmod 0600 "$T/backup_failed/data/config.conf"
before=$(sha256sum "$T/backup_failed/data/config.conf" | cut -d' ' -f1)
printf '\ncp() { return 1; }\n' >> "$T/backup_failed/stubs.sh"
if runinstall backup_failed; then bad 'backup failure must abort'; else ok 'backup failure aborts'; fi
check 'backup failure leaves bytes untouched' "$(sha256sum "$T/backup_failed/data/config.conf" | cut -d' ' -f1)" "$before"
check 'backup failure retains private permissions' "$(stat -c %a "$T/backup_failed/data/config.conf")" 600

# 新装复制失败即中止，部分复制不能成为下一次的“已有配置”。
mkcase fresh_copy_failed
cat >> "$T/fresh_copy_failed/stubs.sh" <<'EOF'
cp() { printf 'partial\n' > "$2"; return 1; }
EOF
if runinstall fresh_copy_failed; then bad 'fresh copy failure must abort'; else ok 'fresh copy failure aborts'; fi
if [ -e "$T/fresh_copy_failed/data/config.conf" ]; then bad 'fresh copy failure published partial config'; else ok 'fresh copy failure leaves no config'; fi

# 档案先成功一项、再写失败，不能留下混合默认和档案的配置。
mkcase fresh_profile_failed profiles
cat >> "$T/fresh_profile_failed/stubs.sh" <<'EOF'
mv() {
  if grep -q '^hard_temp=46.0$' "$2"; then return 1; fi
  command mv "$@"
}
EOF
if runinstall fresh_profile_failed; then bad 'fresh profile failure must abort'; else ok 'fresh profile failure aborts'; fi
if [ -e "$T/fresh_profile_failed/data/config.conf" ]; then bad 'fresh profile failure published partial config'; else ok 'fresh profile failure leaves no config'; fi

# chmod 失败不能发布权限未知的新 inode；旧内容与权限都必须保留。
mkcase chmod_failed
printf 'cfg_version=6\ntarget_temp=42\npred_alpha=0.178\n' > "$T/chmod_failed/data/config.conf"
chmod 0600 "$T/chmod_failed/data/config.conf"
before=$(sha256sum "$T/chmod_failed/data/config.conf" | cut -d' ' -f1)
cat >> "$T/chmod_failed/stubs.sh" <<'EOF'
chmod() {
  case "$2" in *.tmp.*) return 1 ;; esac
  command chmod "$@"
}
EOF
if runinstall chmod_failed; then bad 'temporary chmod failure must abort'; else ok 'temporary chmod failure aborts'; fi
check 'temporary chmod failure rolls back bytes' "$(sha256sum "$T/chmod_failed/data/config.conf" | cut -d' ' -f1)" "$before"
check 'temporary chmod failure retains private permissions' "$(stat -c %a "$T/chmod_failed/data/config.conf")" 600

# 旧版本也不能提高用户已经选定的电流上限。
mkcase preserve_old_ceiling
printf 'cfg_version=0\nmax_ma=15000\n' > "$T/preserve_old_ceiling/data/config.conf"
runinstall preserve_old_ceiling
check 'old default current ceiling is not raised' "$(value preserve_old_ceiling max_ma)" 15000

check 'fresh default grace is 1.5 seconds' "$(value fresh startup_grace_ms)" 1500
mkcase old_grace
printf 'cfg_version=0\nstartup_grace_ms=1500\n' > "$T/old_grace/data/config.conf"
runinstall old_grace
check 'legacy upgrade does not undo 1.5 second grace' "$(value old_grace startup_grace_ms)" 1500

printf '\n通过 %s 项，失败 %s 项\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
