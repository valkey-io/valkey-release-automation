import json
import sys
import logging
from datetime import datetime

logging.basicConfig(level=logging.ERROR, format="%(asctime)s - %(levelname)s - %(message)s")

def get_tags_from_bashbrew(json_file: str, version: str) -> list:
    try:
        with open(json_file, 'r') as f:
            data = json.load(f)
            
        target_tags = []
        is_rc = "-rc" in version
        base_version = version.split('-rc')[0] if is_rc else version
        
        for entry in data["matrix"]["include"]:
            # Match exact version (for both regular and alpine variants)
            if entry["name"] == base_version or entry["name"] == f"{base_version}-alpine":
                meta_entries = entry.get("meta", {}).get("entries", [])
                if meta_entries:
                    # For RC versions, get the major.minor tags
                    # For regular versions, get only the exact version tags
                    tags = [
                        tag.split(":")[-1]  # Remove prefix
                        for tag in meta_entries[0].get("tags", [])
                        if (is_rc and not "-rc" in tag and ".".join(base_version.split(".")[:2]) in tag) or  # RC case
                           (not is_rc and base_version in tag)  # Regular version case
                    ]
                    target_tags.extend(tags)
        
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