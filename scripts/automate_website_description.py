import json
import sys
import logging
from datetime import datetime

logging.basicConfig(level=logging.ERROR, format="%(asctime)s - %(levelname)s - %(message)s")

def get_tags_from_bashbrew(json_file: str, version: str) -> list:
    try:
        with open(json_file, 'r') as f:
            data = json.load(f)

        logging.info(f"Processing version: {version}")

        target_tags = []
        base_version = version.split('-rc')[0] 

        for entry in data["matrix"]["include"]:
            logging.info(f"Checking entry: {entry['name']}")
            # If this entry matches our version (more flexible matching)
            if base_version in entry["name"] or version in entry["name"]:
                meta_entries = entry.get("meta", {}).get("entries", [])
                if meta_entries:
                    all_tags = meta_entries[0].get("tags", [])
                    logging.info(f"All tags for {entry['name']}: {all_tags}")

                    # Get all tags and filter out RC-specific ones if it's an RC version
                    tags = [
                        tag.replace("valkey-container:", "").split(":")[-1]
                        for tag in all_tags
                        if ("-rc" not in version) or ("-rc" not in tag and base_version in tag)
                    ]
                    logging.info(f"Filtered tags: {tags}")
                    target_tags.extend(tags)

        logging.info(f"Final tags: {target_tags}")
        return target_tags
    except Exception as e:
        logging.error(f"Error getting tags from bashbrew: {e}")
        raise

        return target_tags
    except Exception as e:
        logging.error(f"Error getting tags from bashbrew: {e}")
        raise

def update_website_release(version: str, template_file: str, bashbrew_file: str, output_path: str) -> None:
    try:
        with open(template_file, 'r') as f:
            template = f.read()

        # Get and format tags
        tags = get_tags_from_bashbrew(bashbrew_file, version)
        tags_section = "\n".join(f"                - \"{tag}\"" for tag in tags)

        # Handle RC versions for file path
        is_rc = "-rc" in version
        if is_rc:
            base_version = version.split("-rc")[0]
            base_version_dashed = base_version.replace(".", "-")
            file_path = f"{output_path}/v{base_version_dashed}.md"
        else:
            version_dashed = version.replace(".", "-")
            file_path = f"{output_path}/v{version_dashed}.md"

        # Create content using template
        content = template.format(
            version=version,
            date=datetime.now().strftime("%Y-%m-%d"),
            tags=tags_section
        )

        # Write the file
        with open(file_path, 'w') as f:
            f.write(content)

    except Exception as e:
        logging.error(f"Error updating website release: {e}")
        raise

if __name__ == "__main__":
    if len(sys.argv) != 5:
        logging.error("Usage: python automate_website_release.py <version> <template_file> <bashbrew_json> <output_path>")
        sys.exit(1)
    
    try:
        update_website_release(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
    except Exception as e:
        logging.error(f"An unexpected error occurred: {e}")
        sys.exit(1)
