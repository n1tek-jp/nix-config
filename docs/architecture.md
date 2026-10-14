# アーキテクチャ

## 目的

macOSとNixOSの開発環境を、共有範囲に応じたレイヤーから再現する。操作の入口は `switch`。利用者向けの導入・編集・更新・復元手順はREADMEに置き、この文書には現在の構成とその理由を記す。

安定性、再現性、クロスプラットフォーム性、操作の一貫性、最新性の順に重視する。依存の系列は `flake.nix`、リビジョンは `flake.lock` で固定する。

## 全体構成

```text
switch                         導入・適用・更新・復号・復元の入口
flake.nix / flake.lock         依存の系列・リビジョンと出力
bootstrap/
  layers.nix                   レイヤーの探索、優先順位、コンテキストと復号先の受け渡し
  shared.nix                   Home ManagerとFlakesの共通設定、基盤の退避対象
  home-options.nix             実行時の秘密利用とリポジトリルートの共通オプション
  darwin-bootstrap.nix         nix-darwinとHome Managerの統合
  linux-bootstrap.nix          NixOSとHome Managerの統合
layers/
  common/                      開発者に共通のツールと環境の土台
  user/                        個人の好み・使い方
    .env.d/                    個人用リポジトリの暗号文・公開鍵設定・ひな形
  organizations/<組織名>/      組織の設定（現在は場所のみ）
  local/                       端末固有のコンテキスト
    .env.d/                    レイヤー順・鍵の選択・公開してよい個人値（Git管理外）
scripts/
  sync-secrets.sh               ストア外での復号・キャッシュ・不要な復号先の削除
  render-secret-templates.py    実行時に秘密を読み、通常ファイルへテンプレートを生成
tests/
  switch-backup.sh              差し替えたコマンドによる退避・復元の試験
  switch-secrets.py             本物のsops、ソフトウェア鍵、偽YubiKeyの復号試験
  secret-templates.py           テンプレート生成・権限・失敗時の保持の試験
  layers.py                     集約とmacOS/LinuxのHome Manager評価の試験
docs/
  architecture.md              この文書
```

## レイヤーとコンテキスト

既定の優先順位は強い順に `local > user > organizations/<名前順> > common`。`layers/local/.env.d/override-layer-priorities.nix` が返す文字列リストで順序を変更できる。重複や存在しないレイヤーを指定すると評価が止まる。

`common` は合理的に共通化できるツール、`user` はエディタ・フォント・キーバインドなどの好み、`organizations` は組織の設定、`local` は端末固有の設定を持つ。秘密はレイヤーのNixコードに書かず、`layers/user/.env.d/*.sops` に置く。暗号文・公開鍵情報・ひな形はGit管理する。公開版ではlocal・organizations・userの各ディレクトリに `.gitignore` を置き、`.gitignore` と `.gitkeep` 以外を除外する。個人用privateリポジトリはuser・organizationsの `.gitignore` を削除して内容を追跡し、localの `.gitignore` は残す。ルートの `.gitignore` は両リポジトリで共通とする。

1つのツール・目的につき1つのコンテキストとし、そのインストールと設定をまとめる。Homebrewや `.zshrc` 全体の単位にまとめない。同じツールでも、本体が共通ならcommon、個人の設定はuserに分ける。例はVS CodeとAWS CLI。

コンテキストはattrset、または `{ layer, ... }:` を受け取る関数。キーは `home`、`system`、`darwin`、`nixos` と退避対象の文字列リスト `backupTargets`。pkgs・libなどは各適用先のモジュールで受け取る。ディレクトリ内の `default.nix` もコンテキストとして探索する。

複数の層で定義する単一値は、すべての定義を `layer.override` で包む。優先度は `100 - (レイヤー数 - 1 - 順位)`。リストや属性集合は合成するため、モジュール全体をoverrideしない。シェル初期化など出力順に意味がある箇所は `lib.mkOrder` で指定する。

## OSの土台

macOSは `darwinSystem` にHome Managerを統合する。nix-darwinがNix本体・デーモンを管理するため、Determinate Nixとは併用しない。macOSのzsh固有の動作（LANGの補完、COMBINING_CHARS、log組み込みの無効化、端末のセッション処理）はcommonのzshで引き継ぐ。

LinuxはNixOSのみ。端末の `/etc/nixos/configuration.nix` を取り込み、ハードウェア・起動・ユーザー定義はそちらで管理する。汎用Linux向けのNode.js・Pythonなどを使うためnix-ldを有効にする。YubiKeyとの通信にはpcscdを有効にする。

`switch` は実行ユーザー・HOME・OS・CPUを求め、`NIX_CONFIG_USER`、`NIX_CONFIG_HOME`、`NIX_CONFIG_SYSTEM` をflakeへ渡す。環境変数とNixOS端末の構成を読むため `--impure` が必要。出力名は `default`。sudoの前に端末情報を取得するので、Home Managerの対象はrootにならない。

## switchの処理

1. root実行を拒否し、OS・CPUを判定する。NixOS以外のLinuxは拒否する
2. user の `.env.d` に平文・リンク・ディレクトリが無いか検査する。macOSでNixが無ければ、固定した版・ハッシュの公式インストーラーで入れる
3. `switchConfig` から local の鍵設定と各 context の退避対象を評価する。シェルコードとして eval せず文字列として読む
4. `scripts/sync-secrets.sh sync` を利用者の権限で実行する。更新が必要なら、ロックした `packages.<system>.secret-tools` を先にビルドする
5. システムを利用者の権限でビルドする。ファイルの退避はビルドの成功後に行う
6. 既存の管理外ファイルを退避し、macOSはビルドしたnix-darwin、NixOSは `nixos-rebuild switch --sudo` で適用する
7. NixOSでは成功後にHome Managerユニットを再起動する。構成が同一でも復号先・外部ツールの状態を反映するため
8. 適用が成功したら、削除された暗号文に対応する古い復号先をpruneする

NixOSの終了コード100は再起動が必要な状態。ファイルを置く前なので、退避したものを戻し、再起動後の再実行を案内する。適用失敗・中断では空いた場所だけを復元し、適用済みのNixリンクは巻き戻さない。

`switch update` はlockの退避と更新のみ。`switch restore [ID]` はファイルの復元のみ。`switch secrets` は復号のみで、システム適用・pruneは行わない。

## バックアップと復元

対象は各コンテキストの `backupTargets`。bootstrapが有効なレイヤーの分を集約・重複除去し、flakeの `switchConfig.backupTargets` へ出す。switchはこのリストを改行区切りの文字列として読む。絶対パスか `~/` で始まるパスを使い、改行・行内コメント・行末の空白は拒否する。実ディレクトリは対象外。macOSの基盤の対象は `bootstrap/shared.nix` が持つ。旧一覧のうち公開版にcontextが無いツールの対象は持ち越さない。

存在する管理外のファイル・リンクを `~/.local/state/nix-config/backups/<UTC-ID>/files/<元の絶対パス>` へ移す。manifestに先に記録してから移動する。ホーム内の操作にsudoは使わない。Nixストア・ `/etc/static` へのリンクは管理済みとして退避しない。

自動復元は空いた場所のみ。手動restoreはNixリンクを外して元のファイルを戻す。別の管理外ファイルは上書きしない。復元後の片付けは空ディレクトリだけを消し、未復元のファイルを残す。復元処理のパス加工ではコマンド置換を避ける。macOSのbash 3.2では壊れた出力先の後に結果が汚染されるため。

バックアップをリポジトリ内に置かない。 `path:` flakeはGit管理外も含めてコピーするため、平文バックアップを誰でも読めるストアに入れてしまう。restoreはファイルだけを戻す操作で、システム世代のロールバックとは別。

## 暗号化した設定

`layers/user/.env.d/<設定名>.sops` はsopsのbinary形式。Gitはgitconfigの断片、AWSはconfig全体を暗号化する。復号後の内容はファイル全体、シェル代入、JSONオブジェクトのいずれも扱える。レイヤー順は `layers/local/.env.d/override-layer-priorities.nix` に別置きし、userの `.env.d` ではNix形式の平文を認めない。

bootstrapは暗号文の名前から `envSecrets.<設定名>` に復号先の文字列を渡す。平文をimport・readFileしない。Gitはinclude、AWSは `mkOutOfStoreSymlink` で `~/.local/state/nix-config/secrets/<設定名>` を参照する。暗号文が無ければ設定のinclude・リンクを生成しない。AWS configが無い場合はSSO確認も省く。

`path:` は `.gitignore` の対象もコピーするため、switchは評価前に `.env.d` の平文を拒否する。直接nixを実行するとこの検査を通らない。平文をソースの別の場所に置くことも避ける。

復号先はディレクトリ0700・平文0400。暗号文の比較用の写しは0600。写しと復号先が揃っていて暗号文が同一なら、ツールのビルド・YubiKey操作を省く。新しい平文は一時ディレクトリへ復号し、権限を設定してrenameする。比較用の写しは成功時だけ更新する。途中で失敗しても、次回の復号を誤って省略しない。

mkdirのロックで同時実行を拒否する。終了・中断時には一時ディレクトリとロックを消し、端末のsttyを戻す。SIGKILLや電源断では一時ファイルが残る場合があるので、実行中の処理が無いことを確認して片付ける。

既定はYubiKey。`layers/local/.env.d/secrets.nix` の `keyType` と `identityFile` で明示的に変更する。`age` のときはパスの指定を必須とし、そのファイルのソフトウェアage鍵だけを利用する。plugin・SSH鍵は拒否し、対話端末は不要。鍵のパスは文字列として渡し、鍵本体をNixは読まない。鍵本体はリポジトリ外へ置く。

YubiKeyの既定の専用識別子は `~/.config/sops/age/nix-config-yubikeys.txt`。メイン・予備の参照をまとめる。秘密鍵本体はYubiKeyのPIV内にあり、識別子から再生成できない。2本の公開鍵を同じ受信者グループに置くので、どちらか1本で復号できる。

接続した公開鍵と識別子のRecipientコメントを照合し、登録順で最初の1本・1スロットを選ぶ。SOPSの鍵関連環境変数を除去・上書きし、HOMEとXDG設定を隔離する。HOME内のSSH鍵の自動探索も遮断する。cwdの `.sops.yaml` に左右されないよう復号時は `--config /dev/null` を指定する。既存の別用途の `keys.txt` と全ターミナル共通の鍵設定は変更しない。

filestatusで読めない暗号文、受信者不一致、端末・識別子が無い場合は警告し、前回の平文を保持する。YubiKeyでの復号失敗後は残りのPIN試行を避ける。初回の復号ができない設定は利用できない。形式の異なるJSON暗号文はfilestatusを通って後から失敗し得るため、新規作成もbinaryに固定する。

ageとsopsはcommon、YubiKeyツールはuser。age-plugin-yubikey 0.5.1はAES管理鍵が未対応なので、管理鍵はPIN保護したTDESを使う。これは設定データの暗号化方式とは別。PINキャッシュはセッション単位、タッチキャッシュは15秒で、抜き挿し・他アプレットの利用などで終了する。

## 実行時の値と処理

`bootstrap/home-options.nix` はHome Managerの `nixConfig.secretEnvFiles`、`secretTemplates`、`reposRootDir` を宣言する。`secretEnvFiles` の指定順に zsh の対話シェルで source し、allexportをその間だけ有効にする。任意のシェルコードを実行できるため、信頼できるシェル代入形式に限る。秘密は `.zshrc` のストア内テキストへ埋め込まない。

`secretTemplates` は公開のテンプレート、生成先、秘密ファイル名、任意のJSONキーを宣言する。ストア内manifestに入るのは宣言と参照パスだけ。`home.activation.nixConfigSecretTemplates` がwriteBoundary後にPythonを実行し、秘密を実行時に読む。JSONは値のエスケープと完成後の構文検査を行う。置換は1回で、秘密に含まれるプレースホルダーを再解釈しない。新規ディレクトリ0700・通常ファイル0600でatomicに更新する。ホーム外の生成先やリンクは拒否する。未復号なら古い生成先を保持し、構文・キーなどの誤りでは値をログに出さず失敗する。生成先はHMのリンクと併用せず、宣言削除時のファイル削除は手動とする。

`layers/local/.env.d/values.nix` の属性集合を `localValues` として各適用先へ渡す。これは公開してよい値専用で、Git管理外でもNix storeへ入る。レイヤー順と鍵の選択も公開設定であり、秘密を含めない。userの `.env.d` の検査はこれらを許可するために緩めない。

contextの適用後処理は `home.activation` に書く。[Home Managerの規約](https://home-manager.dev/manual/unstable/options/home-manager/home.html) に従い、変更はwriteBoundary後、dry-runには `run` を使い、処理は冪等にする。秘密テンプレートを使う処理は `nixConfigSecretTemplates` の後に置く。

固定したHome Managerのnix-darwin統合は `sudo -u <user> --set-home`、NixOS統合はsystemdの `User=<user>` でactivationを呼ぶ。HOMEは対象ユーザー、作業ディレクトリはHOME。stateVersion 26.05のactivationは元のPATHを引き継がず、bash・coreutils・diffutils・findutils・gettext・grep・sed・jq・ncursesとNixのパスを用意する。追加ツールは `${pkgs.<name>}/bin/<command>` か `home.extraActivationPath` で指定する。zshの設定・sessionVariables・asdf shim・対話端末は前提にしない。NixOSではswitch成功後にも再実行し、構成変更時には同じ処理が複数回動き得る。起動時にも動く。システム全体の適用後の対話フックは設けない。

`config.nixConfig.reposRootDir` はhomeモジュール間で共有する絶対パス。commonのreposコンテキストが `${homeDirectory}/repos` をlayer.overrideで定義し、 `REPOS_ROOT_DIR` をそこから出力する。追加contextはこの値からリポジトリのパスを評価時に組み立てられる。

## パッケージとシェル

Nixpkgsを優先し、無いものはツールのコンテキストに取得元・版・ハッシュを記す。unfreeは各コンテキストからパッケージ名単位で許可する。HomebrewはMac App StoreのBitwarden・Yubico Authenticatorの導入に使う。

macOSのFirefox・Discordは配布元の署名を保持するため、配布物を中身を変更せず展開する。FirefoxのポリシーはmacOSではユーザー設定、Linuxではアプリのpolicies.jsonで渡す。

VS Codeの設定はNix管理で読み取り専用。拡張は版・OS別ハッシュ・依存先を明記する。Marketplaceからの追加や更新も許容するが、その結果はNixによる再現の対象に含まれない。

公開版はBun・uvなどの共通ツールを持ち、Node.js・pnpm・Rust・AWS SSO確認などの個人の使い方はuserのコンテキストとして追加する。

zshのviモードはuserの好み。対話・TTY・TERMを確認し、エージェント・IDEの環境収集を示す変数がある場合は無効化する。人間用のIDE端末にも付く `CLAUDECODE` だけでは判定しない。AWS SSO確認もVS Codeの環境収集では省略する。

## 検証

- switchと補助スクリプトの構文・shellcheck、Nixファイルのnixfmt
- macOSの評価・ビルド、NixOSのaarch64-linux・x86_64-linuxの評価
- `sh tests/switch-backup.sh /bin/sh` でバックアップ・復元を検証。本物のsudoやシステムに触れないよう差し替える。NixOSの判定ファイルも差し替え、両OSの経路を検証する
- `python3 tests/switch-secrets.py` で本物のsopsと偽YubiKeyを使う。HOMEと鍵の環境を隔離し、更新・キャッシュ・失敗・中断時の端末復元を検証する
- `python3 tests/secret-templates.py` でJSONのエスケープ・パス制限・失敗時の保持・権限を確認する
- `python3 tests/layers.py` で鍵選択・退避対象の集約・公開個人値・両OSのHome Manager設定・zshのexportを評価する
- 実機ではswitch成功後のGit設定、AWSの参照先、復号先の権限を確認する

Linux実機でのPIN・タッチ・適用は、その端末の利用者が初回switch後に確認する。NixOSの再起動要求後の再適用も、その端末でHome Managerユニットと設定ファイルを確認する。macOS更新後は `/etc` のリンク、SMB利用時は `smbutil statshares -a`、safe-chainのCA再生成後は鍵の権限を確認する。

## 安定系列の更新

Nixpkgs・nix-darwin・Home Managerの系列は同時に変更する。lockを更新して差分とリリースノートを確認し、switchのNixインストーラーの版・ハッシュも合わせる。stateVersionは互換性の基準であり、通常のパッケージ更新では変更しない。

## 非目標

- 理由のない最新版追従
- macOSとNixOSの適用方式の統一
- Homebrew本体の自動導入
- 同一アプリのNix・Homebrewによる重複管理
- ユーザー・ホストを列挙する端末台帳
- NixOS以外のLinuxへの対応
- パッケージのみを入れるエディタ・端末・Colimaの個別設定管理
