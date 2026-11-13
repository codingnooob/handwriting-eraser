#!/bin/sh
set -eu

tag=${1:?Usage: Scripts/publish-release.sh TAG DMG CHECKSUM NOTES}
image=${2:?Usage: Scripts/publish-release.sh TAG DMG CHECKSUM NOTES}
checksum=${3:?Usage: Scripts/publish-release.sh TAG DMG CHECKSUM NOTES}
notes=${4:?Usage: Scripts/publish-release.sh TAG DMG CHECKSUM NOTES}
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
commit=${GITHUB_SHA:?GITHUB_SHA is required}
if ! printf '%s\n' "$tag" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    echo "Invalid release tag: $tag" >&2
    exit 1
fi
[ -f "$image" ] && [ -f "$checksum" ] && [ -f "$notes" ]

# A failed asset upload may leave a draft and tag. Resume only when that tag
# points to the exact commit being released; never rewrite a published tag.
git fetch --quiet --tags origin
has_tag=false
if git show-ref --verify --quiet "refs/tags/$tag"; then
    has_tag=true
    tagged_commit=$(git rev-parse "$tag^{commit}")
    if [ "$tagged_commit" != "$commit" ]; then
        echo "Existing tag $tag points to $tagged_commit, not $commit. Refusing to overwrite it." >&2
        exit 1
    fi
fi
releases=$(gh release list --repo "$repository" --limit 100 --json tagName,isDraft)
status=$(printf '%s' "$releases" | python3 -c '
import json, sys
tag = sys.argv[1]
items = [item for item in json.load(sys.stdin) if item["tagName"] == tag]
print("none" if not items else "draft" if items[0]["isDraft"] else "published")
' "$tag")
case "$status" in
    draft)
        if [ "$has_tag" != true ]; then
            echo "Draft release $tag has no corresponding tag; refusing to publish." >&2
            exit 1
        fi
        gh release upload "$tag" "$image" "$checksum" --repo "$repository" --clobber
        gh release edit "$tag" --repo "$repository" --draft=false --latest \
            --title "Handwriting Eraser $tag" --notes-file "$notes"
        ;;
    none)
        gh release create "$tag" "$image" "$checksum" --repo "$repository" \
            --target "$commit" --title "Handwriting Eraser $tag" --latest \
            --generate-notes --notes-file "$notes"
        ;;
    *)
        echo "Release $tag is already published; refusing to replace its assets." >&2
        exit 1
        ;;
esac
