# Shared pieces of the omarchy-zfs.com repo publish flow. Sourced by
# dist/publish.sh (the package itself) and dist/mirror.sh (AUR-only deps).

# Release signing key. The public half is embedded in bin/omarchy-bootstrap-zfs
# (so an offline ISO install can trust the repo) and served from the site.
key_fpr=A38BB6838242C1A193FF7D481360E72C018F296D
repo_name=omarchy-zfs

# repo_init SITE_DIR: resolve repo paths and check the signing key is usable.
repo_init() {
  site=$1
  repo_dir="$site/repo/any"
  key_file="$site/repo/$repo_name.gpg"
  [[ -d $repo_dir ]] || { echo "error: $repo_dir not found; pass --site" >&2; exit 1; }
  gpg --list-secret-keys "$key_fpr" >/dev/null 2>&1 || {
    echo "error: release key $key_fpr not in the keyring" >&2; exit 1; }
}

# repo_add_packages FILE...: sign each package, add it to the database, and
# leave the directory in the shape GitHub Pages can serve.
repo_add_packages() {
  local f
  for f in "$@"; do
    [[ -f $f.sig ]] || gpg --detach-sign --use-agent -u "$key_fpr" "$f"
    cp "$f" "$f.sig" "$repo_dir/"
  done
  # --remove drops the superseded package files so each name has one version.
  ( cd "$repo_dir" && repo-add --sign --key "$key_fpr" --remove "$repo_name.db.tar.gz" "${@##*/}" )

  # repo-add writes the .db/.files names as symlinks. GitHub Pages serves a
  # symlink as a 404, so replace each with a copy of its target. It also leaves
  # .old backups of the previous databases, which git already keeps.
  local target
  for f in "$repo_dir/$repo_name".{db,files}{,.sig}; do
    [[ -L $f ]] || continue
    target=$(readlink -f "$f")
    rm "$f" && cp "$target" "$f"
  done
  rm -f "$repo_dir"/*.old "$repo_dir"/*.old.sig

  gpg --armor --export "$key_fpr" > "$key_file"
}

# repo_commit MESSAGE: commit the repo directory in the site checkout.
repo_commit() {
  git -C "$site" add repo
  git -C "$site" commit -S -m "$1"
}
