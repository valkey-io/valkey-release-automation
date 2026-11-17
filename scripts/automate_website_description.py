import json
import sys
import logging
from datetime import datetime

logging.basicConfig(level=logging.DEBUG, format="%(asctime)s - %(levelname)s - %(message)s")

def get_tags_from_bashbrew(json_str: str, version: str) -> list:
    try:
        data = json.loads(json_str)
            
        # A release page lists the tags pinned to its own version, never the
        # line's moving aliases ("9.2", "9.2-rc"), which later releases take
        # over. valkey-container tags an rc as "9.2.0-rc2", "9.2.0-rc2-trixie",
        # ..., so an rc and a GA match the same way.
        target_tags = []
        for entry in data["matrix"]["include"]:
            if version in entry["name"]:
                meta_entries = entry.get("meta", {}).get("entries", [])
                if meta_entries:
                    for tag in meta_entries[0].get("tags", []):
                        clean_tag = tag.split(":")[-1]
                        if version in clean_tag:
                            target_tags.append(clean_tag)

        if not target_tags:
            raise ValueError(f"no container tags for {version} in the bashbrew output")
        return target_tags
    except Exception as e:
        logging.error(f"Error getting tags from bashbrew: {e}")
        raise

def update_website_release(version: str, template_file: str, bashbrew_json: str, output_path: str) -> None:
    try:
        with open(template_file, 'r') as f:
            template = f.read()

        tags = get_tags_from_bashbrew(bashbrew_json, version)
        tags_section = "\n".join(f"                - \"{tag}\"" for tag in tags)

        file_path = f"{output_path}/v{version.replace('.', '-')}.md"

        content = template.format(
            version=version,
            date=datetime.now().strftime("%Y-%m-%d"),
            tags=tags_section
        )

        with open(file_path, 'w') as f:
            f.write(content)

    except Exception as e:
        logging.error(f"Error updating website release: {e}")
        raise

if __name__ == "__main__":
    if len(sys.argv) != 5:
        logging.error("Usage: python automate_website_release.py <version> <template_file> <bashbrew_json_string> <output_path>")
        sys.exit(1)
    
    try:
        update_website_release(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
    except Exception as e:
        logging.error(f"An unexpected error occurred: {e}")
        sys.exit(1)