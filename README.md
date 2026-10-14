# nix-config

macOS と NixOS の開発環境（パッケージ、シェル、エディタ、各種ツールの設定）を、このディレクトリでまとめて管理する。

設計と理由は [docs/architecture.md](docs/architecture.md) にある。

この公開リポジトリは共通の土台を管理する。`layers/local`・`layers/organizations`・`layers/user` は、それぞれの `.gitignore` で内容を除外し、`.gitignore` と `.gitkeep` だけを共有する。個人用の独立したprivateリポジトリでは、`layers/user/.gitignore` と `layers/organizations/.gitignore` を削除して設定をGit管理する。`layers/local/.gitignore` は残す。

## こんなときは

| こんなとき | 手順 |
| --- | --- |
| 新しい Mac や NixOS に環境を作る | [初めて導入する](#初めて導入する) |
| パッケージや設定を足す・変える | [設定を変える](#設定を変える) |
| Git の名前やメールアドレス、AWS のアカウントなどを登録する・変える | [自分の情報を登録する](#自分の情報を登録する) |
| GitHub にログインする | [GitHub にログインする](#github-にログインする) |
| パッケージを新しくする | [パッケージを更新する](#パッケージを更新する) |
| 更新したら調子が悪くなった | [更新を取り消す](#更新を取り消す) |
| `switch` が置き換えたファイルを元に戻す | [置き換えたファイルを元に戻す](#置き換えたファイルを元に戻す) |
| `switch` がエラーで止まった | [switch が止まったとき](#switch-が止まったとき) |

以下のコマンドは、このディレクトリを `~/nix-config` に置いた場合の例である。別の場所に置いた場合は読み替える。`switch` は `sudo` を付けずに実行する（必要なところで `switch` 自身が `sudo` を使う）。

## 初めて導入する

準備:

- macOS: [Homebrew](https://brew.sh/) を入れておく
- NixOS: 自分のユーザーを `/etc/nixos/configuration.nix` に定義しておく（NixOS 以外の Linux には対応していない）

手順:

1. このディレクトリを `~/nix-config` に置く
2. 必要な個人・組織・端末のコンテキストを各レイヤーへ追加する（共通設定のみでも導入できる）
3. 次を実行する。macOS で Nix が入っていなければ、先に Nix を自動で入れる。途中で `sudo` のパスワードを何度か聞かれる

   ```bash
   ~/nix-config/switch
   ```

4. 終わったら新しいターミナルを開く

既にある設定ファイルやコマンド（`~/.zshrc` など、各コンテキストの `backupTargets` に書いたもの）は、ビルドが済んでから `~/.local/state/nix-config/backups/<ID>/` に移して置き換える（ID はファイルを移した日時。終わりに表示される）。途中で失敗したり Ctrl-C で止めたりしたら、移したまま空いている場所には元のファイルが自動で戻る。Nix が置き換え終えたものは置き換わったまま残り、戻すためのコマンド（`switch restore <ID>`）が表示される。

macOS で sudo に Touch ID を使っている（`/etc/pam.d/sudo_local` に書いた）場合や、`/etc/nix/nix.conf` を編集している場合は、これらも移されて効かなくなる。使い続けるなら、先に `layers/user/` のファイルの `darwin` に `security.pam.services.sudo_local.touchIdAuth = true;` や `nix.settings` を書いてから `switch` する。

NixOS で「再起動してから、もう一度 switch を実行してください」と表示されたら、まだ適用されていない。再起動してから、同じコマンドをもう一度実行する。

macOSでは、Nixで管理するGUIアプリが `~/Applications/Home Manager Apps` に入る。公開版の共通設定はVS Codeを含む。

## 設定を変える

使う範囲でレイヤーを選び、ツールごとに1つのファイルを置く。1つのツールのインストールと設定は同じファイルに書く。

| 使う範囲 | 置き場所 |
| --- | --- |
| ほとんどの開発者が同じように使うツール（好みを含めない） | `layers/common/<ツール名>.nix` |
| 自分の好み・自分の使い方 | `layers/user/<ツール名>.nix` |
| 組織で決まっている設定 | `layers/organizations/<組織名>/<ツール名>.nix` |
| この端末だけの設定（共有しない） | `layers/local/<ツール名>.nix` |

ファイルを置くと自動で読み込まれる。編集したら次を実行する。

```bash
~/nix-config/switch
```

どのレイヤーの `.nix` に書いた値も、この端末の全ユーザーが読める場所（Nix ストア）にコピーされる。API キーなどの秘密は書かない。

例: 自分用に ripgrep を入れる（`layers/user/ripgrep.nix`）。

```nix
# ripgrep: 高速な grep。
{
  home =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.ripgrep ];
    };
}
```

パッケージの一覧のようなリストは、全レイヤーの分が合わさる。一方、文字列などの値を複数のレイヤーで決めるときは、強いレイヤーの値が使われる。強い順は local、user、organizations、common。この場合は、その値を書く**すべてのレイヤー**で `layer.override` で包む。包み忘れると `switch` が止まるか、弱いレイヤーの値が使われる。

```nix
# エディタ: この端末だけ、既定のエディタ（EDITOR）を変える。
{ layer, ... }:
{
  home.home.sessionVariables.EDITOR = layer.override "zed --wait";
}
```

レイヤーの順序を変えたいときは、`layers/local/.env.d/override-layer-priorities.nix` にレイヤー名の文字列リストを強い順に書く。存在しないレイヤー名を書くと `switch` が止まる。

VS Codeの設定・拡張機能をNixで管理するときは、個人用の `layers/user/vscode.nix` にまとめる。設定をNixで管理した場合は、設定画面から保存せずNixを編集してswitchする。

## 自分の情報を登録する

公開版は個人用の設定・ひな形を含まない。個人用リポジトリの `layers/user/.env.d/<設定名>.sops` にネイティブ形式の設定をsopsのbinary形式で暗号化して保存する。暗号文・公開鍵情報はGit管理できる。平文や鍵本体をNixコードに置かない。

各コンテキストには `envSecrets.<設定名>` が復号先のパスとして渡る。Gitは `programs.git.includes`、AWSは `home.file` と `mkOutOfStoreSymlink` などを使って、そのパスを参照する。

YubiKeyを使う場合、`layers/user/` のコンテキストに `pkgs.age-plugin-yubikey` と `pkgs.yubikey-manager` を追加し、NixOSには `services.pcscd.enable = true;` を指定する。識別子の登録と暗号化ルールは個人用リポジトリで管理する。復号の方式は [設計文書](docs/architecture.md#暗号化した設定) を参照する。

暗号文が変わった設定は `switch` で復号される。復号だけやり直すときは次を使う。

```sh
~/nix-config/switch secrets
```

## ソフトウェア age 鍵を選ぶ

既定は YubiKey。YubiKey を使わない端末では、初回の `switch` で age を入れた後、リポジトリの外に鍵を作る。

```sh
mkdir -p -m 700 ~/.config/sops/age
(umask 077; age-keygen -o ~/.config/sops/age/nix-config-software.txt)
```

`layers/local/.env.d/secrets.nix` に、鍵の種類とパスを**文字列**で指定する。鍵本体を Nix に書いたり、リポジトリ内に置いたりしない。この設定は Git 管理外だが、Nix store にコピーされる。

```nix
{
  keyType = "age";
  identityFile = "~/.config/sops/age/nix-config-software.txt";
}
```

`age-keygen -y ~/.config/sops/age/nix-config-software.txt` で公開鍵を取得し、暗号文の受信者にも登録する。既存の YubiKey 用暗号文は、ソフトウェア鍵を選ぶだけでは読めない。既存の鍵で復号できる端末で `.sops.yaml` の受信者を変更し、`sops updatekeys <名前>.sops` を行う。

編集時は選んだ鍵を明示する。

```sh
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/nix-config-software.txt"
```

`switch` と `switch secrets` は、この local 設定で選んだ鍵だけを使う。シェルの `SOPS_AGE_KEY*`、標準の `keys.txt`、SSH 鍵は自動で拾わない。ソフトウェア鍵なら対話端末・PIN・タッチは不要。設定を削除すれば既定の YubiKey に戻る。YubiKey の識別子パスも `keyType = "yubikey"; identityFile = "~/…";` で変更できる。

## 秘密を環境変数やテンプレートへ渡す

秘密は従来と同じ binary 形式の `.sops` に保存する。Nix に渡る `envSecrets.<名前>` は復号先のパスだけであり、`builtins.readFile` や `import` で平文を読むことはしない。

### zsh の環境変数

例えば `api.sops` の復号後の内容を次のシェル代入形式にする。平文の編集用ファイルはリポジトリ外へ置く。

```sh
API_TOKEN='your-token'
SERVICE_URL='https://example.com'
```

利用するコンテキストに次を加える。

```nix
{
  home.nixConfig.secretEnvFiles = [ "api" ];
}
```

新しい zsh の対話シェルで復号先を `source` し、変数を export する。ファイルが未復号なら読み込みを省く。設定順に読み、後のファイルが同じ変数を上書きする。`source` はシェルコードを実行するため、内容は信頼できる代入だけにする。これは dotenv パーサーではなく、空白・引用符・`$` は zsh の文法に従う。`switch secrets` の後は新しいシェルを開く。非対話プログラムには、この対話シェルから起動するか、対応する実行時処理で明示的に読み込ませる。

### ストア外のテンプレート

例えば `tool.sops` の平文を JSON オブジェクト `{"token":"your-token"}` にする。コンテキストの `home` に次を書く。

```nix
{
  home.nixConfig.secretTemplates.tool = {
    target = ".config/tool/config.json";
    content = ''
      { "token": @TOKEN@, "region": "ap-northeast-1" }
    '';
    values.TOKEN = { secret = "tool"; key = "token"; };
  };
}
```

`switch` の Home Manager activation で JSON の `token` だけを読み、`@TOKEN@` を JSON エスケープして埋め込む。プレースホルダーの周囲に引用符は書かない。完成後の JSON 構文も確認する。`key` を省略すると、復号ファイル全体を文字列として使う（末尾の改行も保持する）。`format = "text";` なら文字列をそのまま埋め込める。プレースホルダー名は英数字と `_`、先頭は英字か `_` にする。

生成先はホーム内の相対パスに限定し、リンクやホーム外を指す親ディレクトリは拒否する。新規ディレクトリは0700、ファイルは0600で、一時ファイルを rename して更新する。外部ツールは生成後の通常ファイルを編集できるが、次の `switch` はテンプレートで上書きする。秘密が未復号なら以前のファイルを保持し、構文・キーの誤りでは以前のファイルを保持して適用を失敗させる。秘密値やエラーの詳細はログに出さない。

生成先を `home.file` や `xdg.configFile` でも管理しない。オプションや生成先を削除したときのファイル削除は手動で行う。`switch secrets` は復号だけなので、テンプレートの再生成には `switch` を実行する。

## 秘密ではない個人の値

`layers/local/.env.d/values.nix` に公開してよい値を置く。ここは Git 管理外だが、値は Nix store に入り、端末のほかのユーザーも読める。

```nix
{ userName = "example"; }
```

各適用先のモジュールで `localValues` を受け取れる。

```nix
{ layer, ... }:
{
  home = { localValues, ... }: {
    home.sessionVariables.TOOL_USER = layer.override localValues.userName;
  };
}
```

API キーや認証情報はここへ書かず `.sops` に保存する。`layers/user/.env.d` は暗号文・公開鍵設定・ひな形専用のままにする。

## コンテキストの適用後処理と退避対象

書き換え可能なファイルのコピー、CLI による設定、ランタイムの導入などは、コンテキストの `home.activation` に書く。

```nix
{
  home = { lib, pkgs, ... }: {
    home.activation.toolConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.coreutils}/bin/install -d -m 700 "$HOME/.kiro"
      # 公開の初期ファイルをコピーする場合も run と絶対パスのコマンドを使う。
    '';
  };
}
```

macOS と NixOS の両方で対象ユーザーの権限・HOME で実行する。PATH は Home Manager が用意する基本ツールに限定されるため、`${pkgs.<パッケージ>}/bin/<コマンド>` を使うか `home.extraActivationPath = [ pkgs.<パッケージ> ];` を指定する。zsh の初期化、環境変数、asdf の shim、対話端末は前提にしない。ログイン・PIN 入力などは事前に済ませ、処理は非対話で完了させる。

変更する処理は `writeBoundary` の後に置き、`run` を使って dry-run に従う。テンプレート生成を待つなら `entryAfter [ "nixConfigSecretTemplates" ]` にする。NixOS では構成が同じでも `switch` 成功後に Home Manager を再実行する。構成変更時には同じ処理が複数回動くことがあり、起動時にも動くため、繰り返しても結果が変わらない処理にする。システム全体の適用が終わった後の対話処理を保証するフックではない。

退避対象は、置き換えるファイルを所有するコンテキストに宣言する。

```nix
{
  backupTargets = [ "~/.zshrc" ];
  home.programs.zsh.enable = true;
}
```

読み込まれるコンテキストの対象だけを集約し、重複を除いて `switch` へ渡す。絶対パスまたは `~/` で始まる文字列を使い、改行・末尾の空白・行内コメントを入れない。実ディレクトリは対象外。外部ツールが普段書き換えるファイルは宣言しない。`/etc` の共通基盤の対象は `bootstrap/shared.nix` が持つ。

旧 `backup-targets.txt` は廃止した。個人用リポジトリで追加していた asdf・rustup・dnsmasq・SMB などの対象は、対応するコンテキストの `backupTargets` へ移す。

リポジトリのルートは `config.nixConfig.reposRootDir` で評価時に参照できる。既定は `${homeDirectory}/repos`。変更するコンテキストでは `layer.override` を使う。

```nix
{ layer, ... }:
{
  home = { config, ... }: {
    nixConfig.reposRootDir = layer.override "/workspace";
    home.sessionVariables.TOOL_ROOT = "${config.nixConfig.reposRootDir}/some-tool";
  };
}
```

`REPOS_ROOT_DIR` も同じ値から出力される。

## GitHub にログインする

github.com への git の操作（https）は、GitHub CLI（gh）のトークンで認証する。キーチェーンを使わないよう、トークンをファイル（`~/.config/gh/hosts.yml`。自分だけが読める）に置く形でログインする。初回の `switch` の後に1回行う。

```bash
gh auth login --insecure-storage
```

以前にキーチェーンへ保存する形でログインしていた場合は、先に `gh auth logout` してから実行する。gh の設定（`~/.config/gh/config.yml`）は Nix が管理するので、`gh config set` は使えない。変えるときは `layers/common/gh.nix` を編集して `switch` する。

## パッケージを更新する

1. lock ファイルを更新する。更新前の lock は `flake.lock.backup` に残る

   ```bash
   ~/nix-config/switch update
   ```

2. 表示された `Updated input` や `diff -u ~/nix-config/flake.lock.backup ~/nix-config/flake.lock` で、何が新しくなるかを確かめる
3. 適用する

   ```bash
   ~/nix-config/switch
   ```

Git で管理している場合は、`switch` が成功したら `flake.lock` をコミットする。

Homebrew に残っているアプリは、別に `brew update && brew upgrade` で更新する。

26.05 系列のサポートは 2026 年末までである。新しい系列が出たら、[docs/architecture.md の「次の安定系列へ移る」](docs/architecture.md#次の安定系列へ移る)に従って移る。

## 更新を取り消す

```bash
cp ~/nix-config/flake.lock.backup ~/nix-config/flake.lock
~/nix-config/switch
```

Git で管理している場合は、`git restore flake.lock`（コミット前）か `git revert`（コミット後）で戻してから `switch` する。

## 置き換えたファイルを元に戻す

`switch` が移したファイルは、`~/.local/state/nix-config/backups/<ID>/files/` の下に元の絶対パスのまま置かれる（例: `~/.zshrc` は `…/<ID>/files/Users/<ユーザー名>/.zshrc`）。ID はファイルを移した日時（UTC。末尾に `Z` が付く）である。最新の回を元の場所に戻すには、次を実行する。

```bash
~/nix-config/switch restore
```

前の回を戻すときは、`ls ~/.local/state/nix-config/backups` で ID を確かめて指定する（例: `~/nix-config/switch restore 20261003-013653Z`）。

- 回が複数あるとき（`switch` が途中で失敗した回が残ったまま、直して `switch` し直したときなど）は、元のファイルが回ごとに分かれている。ID を省くと最新の回しか戻らないので、`ls` で確かめてそれぞれ戻す
- 戻るのはファイルだけで、入れたパッケージや Nix の世代は戻らない。次に `switch` すると、また置き換わる。再起動しただけでも、`/etc` のファイルや（NixOS では）ホームのファイルが置き換え直されたり、起動時の適用が失敗したりする。設定ごと元に戻すときは世代も戻す（macOS は `sudo darwin-rebuild --rollback`、NixOS は `nixos-rebuild switch --rollback --sudo`）
- 戻し先に別のファイルができていれば、上書きせずに表示する。中身を確かめて消してから、もう一度実行する
- 途中で止めても、もう一度同じコマンドを実行すれば残りが戻る
- 要らなくなった回は `rm -rf ~/.local/state/nix-config/backups/<ID>` で消す

## switch が止まったとき

| 表示 | 対処 |
| --- | --- |
| `layers/user/.env.d に平文の設定があります` | 表示された平文をnix-config全体の外へ移す。[自分の情報を登録する](#自分の情報を登録する)に従ってsopsで登録し、再実行する |
| `Unexpected files in /etc, aborting activation` | 表示されたファイルを対応するコンテキストの `backupTargets` に足して再実行する（`switch` がバックアップしてから置き換える）。表示されたものがディレクトリなら、中身を確かめて手で退避する |
| `Existing file '…' would be clobbered`（後ろに `by backing up` が無い） | 表示されたパスを対応するコンテキストの `backupTargets` に足して再実行する（`switch` がバックアップしてから置き換える） |
| `would be clobbered by backing up` | 前回の退避ファイル（`….before-nix-config`）が残っている。中身を確かめて消してから再実行する |
| `別のファイルがあるため戻しません` | 表示されたファイルの中身を確かめ、要らなければ消してから `switch restore <ID>` を再実行する |
| `戻せませんでした`、`Nix のリンクを外せませんでした`、`戻せなかったファイルがあります` | 表示されたバックアップのパスにファイルが残っている。`sudo` のパスワードなどを確かめてから、表示された `switch restore <ID>` を実行する |
| `context backupTargets: …`、`backupTargets は絶対パスか ~/ …` | 対応するコンテキストの `backupTargets` を直す。各要素を絶対パスか `~/` で始まる文字列にし、改行・行末の空白を入れない |
| `Home Manager の適用に失敗しました`、`the following units failed: home-manager-…`（NixOS） | `journalctl -u 'home-manager-*'` で原因を確かめる。`would be clobbered` なら、表示されたパスを対応するコンテキストの `backupTargets` に足して再実行する |
| `has conflicting definition values` | 複数のレイヤーが同じ項目に違う値を書いている。その値を書くすべてのレイヤーで `layer.override` で包む（[設定を変える](#設定を変える)）。エラーが勧める `lib.mkForce` は使わない |
| `permission denied when trying to update apps, aborting activation` | システム設定 > プライバシーとセキュリティ > アプリ管理で、`switch` を実行したターミナルアプリを許可してから再実行する |
| `permission denied when trying to update apps over SSH, aborting activation` | Mac の画面上で開いたターミナルから実行する |
| `Determinate detected, aborting activation` | Determinate Nix には対応していない。Determinate Nix を削除してから再実行する |
| `single‐user install detected, aborting activation` | Nix をアンインストールしてから再実行する（`switch` がマルチユーザー方式で入れ直す） |
| `Using the homebrew module requires homebrew installed, aborting activation` | Homebrew を入れてから再実行する |
| `switch は sudo を付けずに自分のユーザーで実行してください` | `sudo` を付けずに実行する |
| `Linux は NixOS のみ対応しています` | NixOS 以外の Linux には対応していない |
