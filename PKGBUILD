pkgname=pz
pkgver=0.5.4
pkgrel=1
pkgdesc='Coding agent with built-in sandboxing, policy enforcement, and auditing'
arch=('x86_64' 'aarch64')
url='https://github.com/Lenuma-inc/pz'
license=('MIT')
depends=('glibc' 'bash' 'bubblewrap' 'git' 'ripgrep' 'fd')
makedepends=('zig')
optdepends=(
  'ffmpeg: media tools and video attachments'
  'poppler: PDF attachments'
  'wl-clipboard: clipboard integration on Wayland'
  'xclip: clipboard integration on X11'
  'github-cli: sharing sessions as GitHub gists'
)
# The tagged Git checkout supplies the commit metadata required by build.zig.
source=(
  "pz::git+${url}.git#tag=v${pkgver}"
  "zig-0.17-compat.patch::${url}/commit/cc87a1b01488ca3ea846b6f2f3f60b25b9fe87e5.patch"
)
sha256sums=('acdeb2d4ad45f507486d6bcfca58b97e5f36030828142d26394b31faafb980d8'
            'a087a1b227c79ae18bce470a4cdbe717a431c1f4a7ca1a49330ba4afe77d7551')

prepare() {
  cd "$srcdir/pz"
  # Backport cc87a1b01488ca3ea846b6f2f3f60b25b9fe87e5 until the next release.
  patch -Np1 -i "$srcdir/zig-0.17-compat.patch"
  export ZIG_GLOBAL_CACHE_DIR="$srcdir/zig-cache"
  zig build --fetch
}

build() {
  cd "$srcdir/pz"
  export ZIG_GLOBAL_CACHE_DIR="$srcdir/zig-cache"
  zig build -Doptimize=ReleaseFast --prefix "$srcdir/install"
}

package() {
  cd "$srcdir/pz"
  install -Dm755 "$srcdir/install/bin/pz" "$pkgdir/usr/bin/pz"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
  install -Dm644 CHANGELOG.md "$pkgdir/usr/share/doc/$pkgname/CHANGELOG.md"
}
