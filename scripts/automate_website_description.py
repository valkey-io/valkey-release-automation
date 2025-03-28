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
        major_minor = '.'.join(base_version.split('.')[:2]) 
        
        for entry in data["matrix"]["include"]:
            version_to_match = major_minor if is_rc else base_version
            
            if version_to_match in entry["name"]:  
                meta_entries = entry.get("meta", {}).get("entries", [])
                if meta_entries:
                    for tag in meta_entries[0].get("tags", []):
                        clean_tag = tag.split(":")[-1]  
                        if is_rc:
                            if major_minor in clean_tag and "-rc" not in clean_tag:
                                target_tags.append(clean_tag)
                        else:
                            if base_version in clean_tag:
                                target_tags.append(clean_tag)
        
        return target_tags
    except Exception as e:
        logging.error(f"Error getting tags from bashbrew: {e}")
        raise

def update_website_release(version: str, template_file: str, bashbrew_file: str, output_path: str) -> None:
    try:
        with open(template_file, 'r') as f:
            template = f.read()

        tags = get_tags_from_bashbrew(bashbrew_file, version)
        tags_section = "\n".join(f"                - \"{tag}\"" for tag in tags)

        is_rc = "-rc" in version
        if is_rc:
            base_version = version.split("-rc")[0]
            base_version_dashed = base_version.replace(".", "-")
            file_path = f"{output_path}/v{base_version_dashed}.md"
        else:
            version_dashed = version.replace(".", "-")
            file_path = f"{output_path}/v{version_dashed}.md"

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
        logging.error("Usage: python automate_website_release.py <version> <template_file> <bashbrew_json> <output_path>")
        sys.exit(1)
    
    try:
        update_website_release(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
    except Exception as e:
        logging.error(f"An unexpected error occurred: {e}")
        sys.exit(1)