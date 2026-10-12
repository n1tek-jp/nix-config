#!/bin/sh
# switch のバックアップ・自動復元・switch restore を確かめる。
#   sh tests/switch-backup.sh [シェル]      例: sh tests/switch-backup.sh /bin/dash
# switch を一時ディレクトリに写し、HOME・一覧・uname・nix・sudo・darwin-rebuild・nixos-rebuild・systemctl・systemd-escape を
# 差し替えて動かす。本物のホーム、/etc、Nix には触れない。
# NixOS の経路は /etc/NIXOS がある Linux（使い捨てのコンテナなど）でだけ確かめ、それ以外では飛ばす。
# root では書き込めない場所の扱い（sudo）を確かめられないので、root 以外で動かす。
# 確かめる式は check が eval するので、わざと単一引用符で書く（SC2016。式の中の変数を shellcheck は追えない: SC2034）。
# バックアップの名前は switch が付けた ID なので ls で数える（SC2012）。誤りの例として ~ を文字のまま書く（SC2088）。
# shellcheck disable=SC2016,SC2034,SC2012,SC2088
set -u

if [ "$(id -u)" -eq 0 ]; then
  echo "root 以外で動かしてください（root には書き込めない場所が無く、sudo の扱いを確かめられない）" >&2
  exit 2
fi
shell_under_test=${1:-/bin/sh}
source_switch=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/switch
[ -f "$source_switch" ] || {
  echo "switch が見つかりません: $source_switch" >&2
  exit 2
}
base=$(mktemp -d "${TMPDIR:-/tmp}/switch-backup-test.XXXXXX")
pass=0
fail=0

ok() {
  pass=$((pass + 1))
  printf '  ok   %s\n' "$1"
}
ng() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
}
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

# $1: シナリオ名、$2: darwin か nixos
setup() {
  T=$base/$1
  os=$2
  mkdir -p "$T/cfg" "$T/home" "$T/bin" "$T/sys/sw/bin" "$T/etc" "$T/dotfiles/linkdir"
  cp "$source_switch" "$T/cfg/switch"
  mkdir "$T/cfg/scripts"
  cp "${source_switch%/*}/scripts/sync-secrets.sh" "$T/cfg/scripts/"
  cat >"$T/cfg/backup-targets.txt" <<EOF
# comment

~/.zshrc
~/.zshenv
~/Library/Application Support/Code/User/settings.json
~/.missing
~/dir/
~/.linkdir
$T/etc/zshrc
EOF
  echo old-zshrc >"$T/dotfiles/zshrc"
  ln -s "$T/dotfiles/zshrc" "$T/home/.zshrc"
  echo old-zshenv >"$T/home/.zshenv"
  mkdir -p "$T/home/Library/Application Support/Code/User" "$T/home/dir"
  ln -s "$T/dotfiles/settings" "$T/home/Library/Application Support/Code/User/settings.json"
  ln -s "$T/dotfiles/linkdir" "$T/home/.linkdir"
  if [ "$os" = darwin ]; then
    echo old-etc >"$T/etc/zshrc"
  else
    ln -s /etc/static/zshrc "$T/etc/zshrc"
  fi
  chmod 555 "$T/etc"
  echo ok >"$T/mode"

  if [ "$os" = darwin ]; then
    printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' >"$T/bin/uname"
  else
    printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac\n' >"$T/bin/uname"
  fi
  cat >"$T/bin/nix" <<EOF
#!/bin/sh
echo "\$*" >>"$T/nix.log"
case " \$* " in *" build "*) echo "$T/sys" ;; esac
EOF
  # sudo: 呼ばれたことを記録し、書き込めない /etc の代わりの場所だけ一時的に開けて実行する
  cat >"$T/bin/sudo" <<EOF
#!/bin/sh
echo "\$*" >>"$T/sudo.log"
[ ! -e "$T/sudo-refuse" ] || exit 1
chmod 755 "$T/etc"; "\$@"; rc=\$?; chmod 555 "$T/etc"; exit \$rc
EOF
  # 適用の差し替え。mode に応じて Home Manager と nix-darwin のようにリンクを置き、終わり方を変える
  cat >"$T/apply" <<EOF
#!/bin/sh
link() { ln -s "/nix/store/xxx-home-manager-files/\$(basename "\$1")" "\$1"; }
link_all() {
  link "$T/home/.zshrc"; link "$T/home/.zshenv"; link "$T/home/Library/Application Support/Code/User/settings.json"
  if [ "$os" = darwin ]; then chmod 755 "$T/etc"; ln -s /etc/static/zshrc "$T/etc/zshrc"; chmod 555 "$T/etc"; fi
}
case "\$(cat "$T/mode")" in
  ok) link_all; exit 0 ;;
  unchanged) exit 0 ;;
  fail-before) exit 1 ;;
  fail-after-link) link "$T/home/.zshrc"; exit 1 ;;
  all-then-4) link_all; exit 4 ;;
  reboot) exit 100 ;;
  INT | TERM | HUP) link "$T/home/.zshrc"; kill -"\$(cat "$T/mode")" "\$(cat "$T/pid")"; sleep 1; exit 1 ;;
  INT-then-ok) link_all; kill -INT "\$(cat "$T/pid")"; sleep 1; exit 0 ;;
esac
EOF
  cp "$T/apply" "$T/sys/sw/bin/darwin-rebuild"
  cp "$T/apply" "$T/bin/nixos-rebuild"
  cat >"$T/bin/systemctl" <<EOF
#!/bin/sh
echo "\$*" >>"$T/systemctl.log"
[ ! -e "$T/systemctl-fail" ] || exit 1
link() { [ -e "\$1" ] || [ -L "\$1" ] || ln -s "/nix/store/xxx-home-manager-files/\$(basename "\$1")" "\$1"; }
link "$T/home/.zshrc"; link "$T/home/.zshenv"; link "$T/home/Library/Application Support/Code/User/settings.json"
EOF
  printf '#!/bin/sh\n[ "$1" = --path ] && shift; [ "$1" = -- ] && shift; echo "$1"\n' >"$T/bin/systemd-escape"
  chmod +x "$T/cfg/switch" "$T/apply" "$T/sys/sw/bin/darwin-rebuild" "$T/bin/"*
}

# switch を差し替えた環境で動かす。終了コードは $T/rc、出力は $T/out に残す
require_stub_sudo() {
  if [ "$(PATH="$T/bin:$PATH" command -v sudo)" != "$T/bin/sudo" ]; then
    echo "sudo が差し替えられていないので中止します" >&2
    exit 2
  fi
}
sw() {
  require_stub_sudo
  (cd "$T" && umask 022 && HOME="$T/home" PATH="$T/bin:$PATH" \
    $shell_under_test -c 'echo $$ >"$1/pid"; shift; exec '"$shell_under_test"' "$@"' sh "$T" "$T/cfg/switch" "$@" \
    >"$T/out" 2>&1)
  echo $? >"$T/rc"
}
rc() { cat "$T/rc"; }
backups() { echo "$T/home/.local/state/nix-config/backups"; }
nbackups() { ls -1 "$(backups)" 2>/dev/null | wc -l | tr -d ' '; }
latest() { ls -1 "$(backups)" | tail -n 1; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
is_hm() { [ "$(readlink "$1")" = "/nix/store/xxx-home-manager-files/$(basename "$1")" ]; }
settings="Library/Application Support/Code/User/settings.json"
originals_back() {
  [ "$(readlink "$T/home/.zshrc")" = "$T/dotfiles/zshrc" ] &&
    [ ! -L "$T/home/.zshenv" ] && [ "$(cat "$T/home/.zshenv")" = old-zshenv ] &&
    [ "$(readlink "$T/home/$settings")" = "$T/dotfiles/settings" ] &&
    [ "$(readlink "$T/home/.linkdir")" = "$T/dotfiles/linkdir" ]
}
# sudo で動かした mv・rm・mkdir が、すべて /etc の代わりの場所に関わるものか（ホームの下に sudo を使っていないか）
sudo_only_for_etc() { ! grep -E '^(mv|rm|mkdir) ' "$T/sudo.log" 2>/dev/null | grep -qvF "$T/etc"; }
etc_back() { [ ! -L "$T/etc/zshrc" ] && [ "$(cat "$T/etc/zshrc")" = old-etc ]; }

echo "== D1 macOS 成功: 移してから適用する"
setup d1 darwin
sw
B=$(latest)
check "rc=0" '[ "$(rc)" = 0 ]'
check "Nix のリンクに置き換わる" 'is_hm "$T/home/.zshrc" && is_hm "$T/home/.zshenv" && [ "$(readlink "$T/etc/zshrc")" = /etc/static/zshrc ]'
check "バックアップは1回分" '[ "$(nbackups)" = 1 ]'
check "リンクはリンクのまま移す" '[ "$(readlink "$(backups)/$B/files$T/home/.zshrc")" = "$T/dotfiles/zshrc" ]'
check "空白を含むパスと壊れたリンクも移す" '[ -L "$(backups)/$B/files$T/home/$settings" ]'
check "ディレクトリを指すリンクはリンクとして移す" '[ "$(readlink "$(backups)/$B/files$T/home/.linkdir")" = "$T/dotfiles/linkdir" ]'
check "/etc は sudo で移す" 'grep -q "^mv -- $T/etc/zshrc" "$T/sudo.log"'
check "ホームの下では sudo を使わない" 'sudo_only_for_etc'
check "manifest は5件" '[ "$(wc -l <"$(backups)/$B/manifest" | tr -d " ")" = 5 ]'
check "本物のディレクトリは飛ばして警告する" 'grep -q "ディレクトリは置き換えの対象にしない" "$T/out" && [ -d "$T/home/dir" ]'
check "無いファイルは記録しない" '! grep -q missing "$(backups)/$B/manifest"'
check "バックアップの置き場所は 700" '[ "$(mode_of "$(backups)")" = 700 ] && [ "$(mode_of "$(backups)/$B")" = 700 ]'
check "戻し方を表示する" 'grep -q "restore $B" "$T/out"'

echo "== D2 macOS 2回目: Nix が管理済みのものは移さない"
sleep 1
sw
check "rc=0、バックアップは増えない" '[ "$(rc)" = 0 ] && [ "$(nbackups)" = 1 ]'

echo "== D3 switch restore（ID を省くと最新の回）"
sw restore
check "rc=0" '[ "$(rc)" = 0 ]'
check "元のファイルとリンクに戻る" 'originals_back && etc_back'
check "/etc の Nix のリンクは sudo で外す" 'grep -q "^rm -f -- $T/etc/zshrc" "$T/sudo.log"'
check "戻し終えた回は消える" '[ "$(nbackups)" = 0 ]'

echo "== D4 macOS 適用の前に失敗: すべて戻す"
setup d4 darwin
echo fail-before >"$T/mode"
sw
check "rc!=0" '[ "$(rc)" != 0 ]'
check "元に戻る" 'originals_back && etc_back'
check "バックアップは残らない" '[ "$(nbackups)" = 0 ]'

echo "== D5 macOS 一部を置き換えた後に失敗: 空いた場所だけ戻す"
setup d5 darwin
echo fail-after-link >"$T/mode"
sw
check "rc!=0" '[ "$(rc)" != 0 ]'
check "置き換え済みは Nix のまま" 'is_hm "$T/home/.zshrc"'
check "空いた場所は戻る" '[ "$(cat "$T/home/.zshenv")" = old-zshenv ] && etc_back'
check "置き換え済みの分はバックアップに残る" '[ "$(nbackups)" = 1 ] && [ -L "$(backups)/$(latest)/files$T/home/.zshrc" ]'
check "戻し方を表示する" 'grep -q "restore $(latest)" "$T/out"'
sw restore
check "残りも switch restore で戻る" '[ "$(rc)" = 0 ] && originals_back && [ "$(nbackups)" = 0 ]'

for signal in INT TERM HUP; do
  case $signal in INT) code=130 ;; TERM) code=143 ;; HUP) code=129 ;; esac
  echo "== D6 macOS 適用中の $signal: 空いた場所を戻す"
  setup "d6-$signal" darwin
  echo "$signal" >"$T/mode"
  sw
  check "rc=$code" '[ "$(rc)" = "$code" ]'
  check "空いた場所は戻り、置き換え済みは残る" 'is_hm "$T/home/.zshrc" && [ "$(cat "$T/home/.zshenv")" = old-zshenv ] && etc_back'
  check "バックアップに置き換え済みの分が残る" '[ "$(nbackups)" = 1 ]'
done

echo "== D7 stderr が閉じていても戻す"
setup d7 darwin
echo fail-before >"$T/mode"
require_stub_sudo
(cd "$T" && HOME="$T/home" PATH="$T/bin:$PATH" $shell_under_test "$T/cfg/switch" >/dev/null 2>&-)
check "元に戻る" 'originals_back && etc_back && [ "$(nbackups)" = 0 ]'

echo "== D8 戻し先に別のファイル: 上書きしない"
setup d8 darwin
sw
rm "$T/home/.zshenv"
echo new-user-file >"$T/home/.zshenv"
ln -sfn "$T/nowhere" "$T/home/$settings"
sw restore
check "rc!=0" '[ "$(rc)" != 0 ]'
check "別のファイルと壊れたリンクは残す" '[ "$(cat "$T/home/.zshenv")" = new-user-file ] && [ "$(readlink "$T/home/$settings")" = "$T/nowhere" ]'
check "他は戻る" '[ "$(readlink "$T/home/.zshrc")" = "$T/dotfiles/zshrc" ] && etc_back'
check "バックアップは残る" '[ "$(nbackups)" = 1 ]'
rm "$T/home/.zshenv" "$T/home/$settings"
sw restore
check "消してから再実行すると残りが戻る" '[ "$(rc)" = 0 ] && originals_back && [ "$(nbackups)" = 0 ]'

echo "== D9 戻し先の親ディレクトリが無い: ホームの下は sudo を使わずに作る"
setup d9 darwin
sw
rm -rf "$T/home/Library/Application Support/Code"
: >"$T/sudo.log"
sw restore
check "親を作って戻す" '[ "$(rc)" = 0 ] && [ "$(readlink "$T/home/$settings")" = "$T/dotfiles/settings" ]'
check "sudo はホームの下に使わない" 'sudo_only_for_etc'

echo "== D10 一覧の書き方の誤り: ビルドの前に止まり、何も移さない"
for bad in "relative/path" "~/.zshrc # comment" "~/.zshrc "; do
  setup d10 darwin
  printf '%s\n' "$bad" >>"$T/cfg/backup-targets.txt"
  sw
  check "誤り「${bad}」で止まる" '[ "$(rc)" != 0 ] && grep -q "error: .*backup-targets.txt" "$T/out"'
  check "ビルドしない" '! grep -q build "$T/nix.log" 2>/dev/null'
  check "何も動かさない" 'originals_back && etc_back && [ "$(nbackups)" = 0 ]'
  chmod -R u+w "$T"
  rm -rf "$T"
done

echo "== D11 末尾の / と、改行の無い最終行"
setup d11 darwin
printf '~/.zshenv/\n~/.zshrc' >"$T/cfg/backup-targets.txt"
sw
check "どちらも移す" '[ "$(rc)" = 0 ] && grep -qxF "$T/home/.zshenv" "$(backups)/$(latest)/manifest" && grep -qxF "$T/home/.zshrc" "$(backups)/$(latest)/manifest"'

echo "== D12 最初の移動に失敗: 空のバックアップを残さない"
setup d12 darwin
printf '%s\n' "$T/etc/zshrc" >"$T/cfg/backup-targets.txt"
: >"$T/sudo-refuse"
sw
check "rc!=0" '[ "$(rc)" != 0 ]'
check "元のまま" 'etc_back'
check "バックアップを残さない" '[ "$(nbackups)" = 0 ]'

echo "== D13 回が2つ: ID を省くと新しい方、同じ秒なら名前をずらす"
setup d13 darwin
mkdir -p "$(backups)"
older=$(date -u +%Y%m%d-%H%M%SZ)
mkdir "$(backups)/$older"
printf '%s\n' "$T/home/.nothing" >"$(backups)/$older/manifest"
sw
B=$(latest)
check "同じ秒の名前を避ける" '[ "$(nbackups)" = 2 ] && [ "$B" != "$older" ]'
sw restore
check "新しい方を戻す" '[ "$(rc)" = 0 ] && grep -qF "バックアップ $B を" "$T/out" && originals_back'
check "古い方は残る" '[ "$(ls -1 "$(backups)")" = "$older" ]'

echo "== D14 restore と update の引数"
setup d14 darwin
sw restore
check "バックアップが無ければ誤り" '[ "$(rc)" != 0 ] && grep -q "戻せるバックアップがありません" "$T/out"'
sw restore ../x
check "/ を含む ID は誤り" '[ "$(rc)" != 0 ] && grep -q "書き方が違います" "$T/out"'
sw restore 20000101-000000
check "無い ID は誤り" '[ "$(rc)" != 0 ] && grep -q "ありません" "$T/out"'
sw restore a b
check "引数が多いと誤り" '[ "$(rc)" != 0 ] && grep -q "使い方" "$T/out"'
sw update x
check "update に引数は誤り" '[ "$(rc)" != 0 ] && grep -q "使い方" "$T/out"'

echo "== D16 適用の最中に INT を受けたが適用は成功: 巻き戻さない"
setup d16 darwin
echo INT-then-ok >"$T/mode"
sw
check "rc=130" '[ "$(rc)" = 130 ]'
check "置き換えたものは Nix のまま" 'is_hm "$T/home/.zshrc" && is_hm "$T/home/.zshenv" && [ "$(readlink "$T/etc/zshrc")" = /etc/static/zshrc ]'
check "Nix が何も置かないもの（上書き要因）も戻さない" '[ ! -e "$T/home/.linkdir" ] && [ ! -L "$T/home/.linkdir" ]'
check "バックアップは残る" '[ "$(nbackups)" = 1 ] && ! grep -q "適用が完了しませんでした" "$T/out"'

echo "== D17 片付けの find が失敗しても、戻していないファイルは消さない"
setup d17 darwin
echo fail-after-link >"$T/mode"
printf '#!/bin/sh\nexit 1\n' >"$T/bin/find"
chmod +x "$T/bin/find"
sw
check "Nix が置き換えた分のバックアップが残る" '[ -L "$(backups)/$(latest)/files$T/home/.zshrc" ] && [ -f "$(backups)/$(latest)/manifest" ]'

echo "== D18 出力先のパイプが先に閉じる: 止まらずに戻す"
setup d18 darwin
require_stub_sudo
(cd "$T" && HOME="$T/home" PATH="$T/bin:$PATH" \
  $shell_under_test -c 'echo $$ >"$1/pid"; shift; exec '"$shell_under_test"' "$@"' sh "$T" "$T/cfg/switch" 2>&1 | :) &
waiter=$!
i=0
while kill -0 "$waiter" 2>/dev/null && [ "$i" -lt 200 ]; do
  sleep 0.1
  i=$((i + 1))
done
if kill -0 "$waiter" 2>/dev/null; then
  kill -9 "$(cat "$T/pid")" 2>/dev/null
  ng "20 秒以内に終わる"
else
  ok "20 秒以内に終わる"
fi
wait "$waiter" 2>/dev/null
check "元に戻る" 'originals_back && etc_back && [ "$(nbackups)" = 0 ]'

echo "== D15 一覧が無い: 何も移さない"
setup d15 darwin
rm "$T/cfg/backup-targets.txt"
echo unchanged >"$T/mode"
sw
check "rc=0、バックアップ無し" '[ "$(rc)" = 0 ] && [ "$(nbackups)" = 0 ] && originals_back'

if [ -e /etc/NIXOS ]; then
  echo "== N1 NixOS 成功: Home Manager のユニットを動かし直す"
  setup n1 nixos
  sw
  check "rc=0" '[ "$(rc)" = 0 ]'
  check "/etc の Nix のリンクは移さない" '[ "$(readlink "$T/etc/zshrc")" = /etc/static/zshrc ] && ! grep -q etc "$(backups)/$(latest)/manifest"'
  check "Home Manager のユニットを動かし直す" 'grep -q "^systemctl restart home-manager-.*\.service" "$T/sudo.log"'

  echo "== N2 NixOS 構成が同じ（Home Manager が動かない）: 動かし直して置き換える"
  setup n2 nixos
  echo unchanged >"$T/mode"
  sw
  check "rc=0 で置き換わる" '[ "$(rc)" = 0 ] && is_hm "$T/home/.zshrc" && is_hm "$T/home/.zshenv"'

  echo "== N3 NixOS 終了コード 100（再起動が必要）: 移したものを戻して案内する"
  setup n3 nixos
  echo reboot >"$T/mode"
  sw
  check "rc=0" '[ "$(rc)" = 0 ]'
  check "再起動を案内する" 'grep -q "再起動してから" "$T/out"'
  check "元に戻る" 'originals_back && [ "$(nbackups)" = 0 ]'
  check "Home Manager は動かさない" '[ ! -e "$T/systemctl.log" ]'

  echo "== N4 NixOS 終了コード 4（適用は済み、別のユニットが失敗）: 置き換え済みは戻さない"
  setup n4 nixos
  echo all-then-4 >"$T/mode"
  sw
  check "rc!=0" '[ "$(rc)" != 0 ]'
  check "置き換え済みは Nix のまま" 'is_hm "$T/home/.zshrc" && is_hm "$T/home/.zshenv"'
  check "バックアップは残る" '[ "$(nbackups)" = 1 ]'

  echo "== N5 NixOS 適用の前に失敗: すべて戻す"
  setup n5 nixos
  echo fail-before >"$T/mode"
  sw
  check "rc!=0、元に戻る" '[ "$(rc)" != 0 ] && originals_back && [ "$(nbackups)" = 0 ]'

  echo "== N6 NixOS Home Manager のユニットが失敗: 戻す"
  setup n6 nixos
  echo unchanged >"$T/mode"
  : >"$T/systemctl-fail"
  sw
  check "rc!=0、元に戻る" '[ "$(rc)" != 0 ] && originals_back && [ "$(nbackups)" = 0 ]'
else
  echo "== NixOS の経路は飛ばした（/etc/NIXOS が無い）"
fi

printf '%s: %d passed, %d failed\n' "$shell_under_test" "$pass" "$fail"
chmod -R u+w "$base"
rm -rf "$base"
[ "$fail" -eq 0 ]
