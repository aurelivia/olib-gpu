
OS=('linux' 'windows' 'macos')
ARCH=('aarch64' 'x86_64')
MODE=('debug' 'release')
VERSION='v27.0.2.0'

for os in ${OS[@]}; do
  for arch in ${ARCH[@]}; do
    ABI_IN=('')
    ABI_OUT=('')
    if [ "$os" == 'windows' ]; then
      if [ "$arch" == 'x86_64' ]; then
        ABI_IN=('-msvc' '-gnu')
        ABI_OUT=('_msvc' '_gnu')
      else
        ABI_IN=('-msvc')
        ABI_OUT=('_msvc')
      fi
    fi
    for abi in ${!ABI_IN[@]}; do
      abi_in="${ABI_IN[$abi]}"
      abi_out="${ABI_OUT[$abi]}"
      for mode in ${MODE[@]}; do
        dest="https://github.com/gfx-rs/wgpu-native/releases/download/${VERSION}/wgpu-${os}-${arch}${abi_in}-${mode}.zip"
        echo "        .wgpu_${os}_${arch}${abi_out}_${mode} = .{"
        echo "            .url = \"$dest\","
        echo "            .hash = \"$(zig fetch --debug-hash "$dest" | tail -1)\","
        echo "            .lazy = true"
        echo "        },"
      done
    done
  done
done
