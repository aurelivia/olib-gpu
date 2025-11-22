{ pkgs, lib, config, inputs, ... }: let
  pkgs-unstable = import inputs.unstable { system = pkgs.stdenv.system; };
in {
  languages.zig.enable = true;
  languages.zig.package = pkgs-unstable.zigPackages."0.14";
  languages.zig.zls.package = pkgs-unstable.zls_0_14;

  packages = with pkgs; [

    xorg.libX11
    libxkbcommon
    vulkan-headers
    vulkan-loader
    vulkan-validation-layers
    vulkan-tools
  ];
  env = {
    VULKAN_SDK = "${pkgs.vulkan-headers}";
    VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
    LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
      wayland
      vulkan-loader
      vulkan-validation-layers
    ]);
  };
}
