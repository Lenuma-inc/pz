pkgname=pz
pkgver=0.8.0
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
source=("pz::git+${url}.git#tag=v${pkgver}")
sha256sums=('SKIP')

prepare() {
  cd "$srcdir/pz"
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
