import json
import unittest

from scripts.automate_website_description import get_tags_from_bashbrew


def entry(tags: list) -> dict:
    # Shape of docker-library/bashbrew's github-actions/generate.sh matrix:
    # the entry name is its first tag; tags carry the image repo prefix.
    return {
        "name": tags[0],
        "meta": {"entries": [{"tags": [f"valkey-release-automation:{t}" for t in tags]}]},
    }


# Tags as valkey-container's generate-stackbrew-library.sh emits them.
BASHBREW = json.dumps({"matrix": {"include": [
    entry(["unstable", "unstable-trixie"]),
    entry(["9.2.0-rc2", "9.2-rc", "9.2.0-rc2-trixie", "9.2-rc-trixie"]),
    entry(["9.2.0-rc2-alpine", "9.2-rc-alpine", "9.2.0-rc2-alpine3.24", "9.2-rc-alpine3.24"]),
    entry(["9.1.3", "9.1", "9", "latest", "9.1.3-trixie", "9.1-trixie", "9-trixie", "trixie"]),
    entry(["9.1.3-alpine", "9.1-alpine", "9-alpine", "alpine",
           "9.1.3-alpine3.24", "9.1-alpine3.24", "9-alpine3.24", "alpine3.24"]),
]}})


class WebsiteTagsTest(unittest.TestCase):
    def test_rc_page_lists_only_its_own_tags(self) -> None:
        self.assertEqual(
            get_tags_from_bashbrew(BASHBREW, "9.2.0-rc2"),
            ["9.2.0-rc2", "9.2.0-rc2-trixie", "9.2.0-rc2-alpine", "9.2.0-rc2-alpine3.24"],
        )

    def test_ga_page_lists_only_its_own_tags(self) -> None:
        self.assertEqual(
            get_tags_from_bashbrew(BASHBREW, "9.1.3"),
            ["9.1.3", "9.1.3-trixie", "9.1.3-alpine", "9.1.3-alpine3.24"],
        )

    def test_missing_version_fails(self) -> None:
        with self.assertRaises(ValueError):
            get_tags_from_bashbrew(BASHBREW, "9.0.7")


if __name__ == "__main__":
    unittest.main()
