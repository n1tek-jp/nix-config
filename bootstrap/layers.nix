# layers/ 配下のコンテキストを読み込み、適用先（home / system / darwin / nixos）ごとのモジュール一覧にする。
{ lib, root }:
let
  layersDir = root + "/layers";
  envDir = layersDir + "/user/.env.d";
  contextKeys = targets ++ [ "backupTargets" ];
  homeDirectory = builtins.getEnv "NIX_CONFIG_HOME";
  localEnvDir = layersDir + "/local/.env.d";
  readLocal =
    name: fallback:
    let
      file = localEnvDir + "/${name}.nix";
    in
    if builtins.pathExists file then import file else fallback;
  localValues = readLocal "values" { };
  secretSettings = readLocal "secrets" { };
  secretKeyType = secretSettings.keyType or "yubikey";
  identityFile =
    secretSettings.identityFile or "${homeDirectory}/.config/sops/age/nix-config-yubikeys.txt";
  secrets =
    if
      !builtins.isAttrs secretSettings
      || lib.subtractLists [ "keyType" "identityFile" ] (builtins.attrNames secretSettings) != [ ]
    then
      throw "layers/local/.env.d/secrets.nix: keyType と identityFile の設定だけを書いてください"
    else if
      !builtins.elem secretKeyType [
        "yubikey"
        "age"
      ]
    then
      throw "layers/local/.env.d/secrets.nix: keyType は yubikey か age にしてください"
    else if secretKeyType == "age" && !(secretSettings ? identityFile) then
      throw "layers/local/.env.d/secrets.nix: age を選ぶ場合は identityFile を指定してください"
    else if
      !builtins.isString identityFile
      || !(lib.hasPrefix "/" identityFile || lib.hasPrefix "~/" identityFile)
      || lib.hasInfix "\n" identityFile
    then
      throw "layers/local/.env.d/secrets.nix: identityFile は絶対パスか ~/ で始まる文字列にしてください（鍵本体は書かない）"
    else
      {
        keyType = secretKeyType;
        identityFile =
          if lib.hasPrefix "~/" identityFile then
            "${homeDirectory}/${lib.removePrefix "~/" identityFile}"
          else
            identityFile;
      };

  targets = [
    "home"
    "system"
    "darwin"
    "nixos"
  ];

  isVisible = name: !(lib.hasPrefix "." name);

  # 値を評価せず、復号先の文字列だけを各コンテキストへ渡す。
  envEntries = if builtins.pathExists envDir then builtins.readDir envDir else { };
  plaintextFiles = builtins.attrNames (
    lib.filterAttrs (
      name: type:
      type != "regular"
      || !(lib.hasSuffix ".sops" name || lib.hasSuffix ".example" name || name == ".sops.yaml")
    ) envEntries
  );
  secretNames = map (name: lib.removeSuffix ".sops" name) (
    builtins.attrNames (
      lib.filterAttrs (
        name: type: type == "regular" && isVisible name && lib.hasSuffix ".sops" name
      ) envEntries
    )
  );
  envSecrets =
    if plaintextFiles != [ ] then
      throw "layers/user/.env.d に平文の設定があります。README の『自分の情報を登録する』に従い、nix-config 全体の外へ退避してください"
    else
      lib.genAttrs secretNames (name: "${homeDirectory}/.local/state/nix-config/secrets/${name}");

  organizationLayers =
    let
      dir = layersDir + "/organizations";
      entries = lib.filterAttrs (name: type: type == "directory" && isVisible name) (
        builtins.readDir dir
      );
    in
    lib.optionals (builtins.pathExists dir) (
      map (name: "organizations/${name}") (builtins.attrNames entries)
    );

  # 強い順。
  defaultPriorities = [
    "local"
    "user"
  ]
  ++ organizationLayers
  ++ [ "common" ];

  overrideFile = layersDir + "/local/.env.d/override-layer-priorities.nix";
  priorities =
    let
      value = if builtins.pathExists overrideFile then import overrideFile else defaultPriorities;
    in
    if !(builtins.isList value && builtins.all builtins.isString value) then
      throw "${toString overrideFile}: レイヤー名の文字列リストを返してください"
    else if lib.length (lib.unique value) != lib.length value then
      throw "${toString overrideFile}: 同じレイヤーが複数回書かれています"
    else
      value;

  layerDir = name: layersDir + "/${name}";

  mkLayer =
    rank: name:
    let
      # 強い層ほど小さい値（＝優先）になる。最も弱い層は通常の定義と同じ 100。
      priority = 100 - (lib.length priorities - 1 - rank);
    in
    {
      inherit name priority;
      override = lib.mkOverride priority;
    };

  contextPaths =
    name:
    let
      dir = layerDir name;
      entries = lib.filterAttrs (entry: _: isVisible entry) (builtins.readDir dir);
      toPaths =
        entry: type:
        if type == "regular" && lib.hasSuffix ".nix" entry then
          [ (dir + "/${entry}") ]
        else if type == "directory" && builtins.pathExists (dir + "/${entry}/default.nix") then
          [ (dir + "/${entry}") ]
        else
          [ ];
    in
    if builtins.pathExists dir then
      lib.concatLists (lib.mapAttrsToList toPaths entries)
    else if name == "local" then
      [ ]
    else
      throw "レイヤー ${name} が見つかりません（${toString dir}）";

  loadContext =
    layer: path:
    let
      raw = import path;
      extraArgs = lib.subtractLists [ "layer" ] (builtins.attrNames (builtins.functionArgs raw));
      value = if builtins.isFunction raw then raw { inherit layer; } else raw;
      unknown = lib.subtractLists contextKeys (builtins.attrNames value);
      backups = value.backupTargets or [ ];
    in
    if builtins.isFunction raw && extraArgs != [ ] then
      throw "${toString path}: コンテキストの関数が受け取れるのは layer だけです。${lib.concatStringsSep ", " extraArgs} は home = { pkgs, ... }: { ... }; のように各適用先のモジュールで受け取ってください"
    else if !builtins.isAttrs value then
      throw "${toString path}: コンテキストは attrset か、{ layer, ... } を受け取る関数にしてください"
    else if unknown != [ ] then
      throw "${toString path}: 未知のキー ${lib.concatStringsSep ", " unknown}（使えるのは ${lib.concatStringsSep ", " contextKeys}）"
    else if
      !(
        builtins.isList backups
        && builtins.all (
          target:
          builtins.isString target
          && !(lib.hasInfix "\n" target)
          && !(lib.hasInfix "\r" target)
          && (lib.hasPrefix "/" target || lib.hasPrefix "~/" target)
        ) backups
      )
    then
      throw "${toString path}: backupTargets は絶対パスか ~/ で始まる文字列リストにしてください（改行は使えません）"
    else
      {
        backupTargets = backups;
      }
      // lib.mapAttrs (target: module: {
        _file = "${toString path}#${target}";
        imports = [ module ];
      }) (builtins.removeAttrs value [ "backupTargets" ]);

  # 弱い層から順に読み込む。ただし、リスト型の設定（シェルの初期化行など）が出力される順序は
  # モジュールシステムの実装に依存する。順序が意味を持つ箇所では lib.mkOrder で明示する。
  contextsOf = rank: name: map (loadContext (mkLayer rank name)) (contextPaths name);
  applied = lib.concatLists (lib.reverseList (lib.imap0 contextsOf priorities));

  modulesFor =
    target: lib.concatMap (context: lib.optional (context ? ${target}) context.${target}) applied;
in
{
  inherit priorities envSecrets secrets;
  localValues =
    if builtins.isAttrs localValues then
      localValues
    else
      throw "layers/local/.env.d/values.nix: 属性集合を書いてください";
  backupTargets = lib.unique (lib.concatMap (context: context.backupTargets) applied);
}
// lib.genAttrs targets modulesFor
