# 他の home context は config.nixConfig.reposRootDir からパスを組み立てられる。
{ layer, ... }:
{
  home = { config, homeDirectory, ... }: {
    nixConfig.reposRootDir = layer.override "${homeDirectory}/repos";
    home.sessionVariables.REPOS_ROOT_DIR = config.nixConfig.reposRootDir;
  };
}
