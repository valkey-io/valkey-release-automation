import json
import sys
import logging
from datetime import datetime

logging.basicConfig(level=logging.DEBUG, format="%(asctime)s - %(levelname)s - %(message)s")

def get_tags_from_bashbrew(json_file: str, version: str) -> list:
    try:
        with open(json_file, 'r') as f:
            data = json.load(f)
            
        target_tags = []
        is_rc = "-rc" in version
        base_version = version.split('-rc')[0] 
        
        logging.debug(f"Processing version: {version}")
        logging.debug(f"Is RC: {is_rc}")
        logging.debug(f"Base version: {base_version}")
        
        for entry in data["matrix"]["include"]:
            logging.debug(f"Checking entry name: {entry['name']}")
            if base_version in entry["name"]:
                logging.debug(f"Found matching entry: {entry['name']}")
                meta_entries = entry.get("meta", {}).get("entries", [])
                if meta_entries:
                    all_tags = meta_entries[0].get("tags", [])
                    logging.debug(f"All tags found: {all_tags}")
                    
                    # Get all tags and filter out RC-specific ones
                    tags = []
                    for tag in all_tags:
                        clean_tag = tag.split(":")[-1]
                        if "-rc" not in clean_tag:
                            tags.append(clean_tag)
                            logging.debug(f"Adding tag: {clean_tag}")
                    
                    target_tags.extend(tags)
        
        logging.debug(f"Final tags list: {target_tags}")
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