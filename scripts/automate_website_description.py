import json
import sys
import logging
from datetime import datetime

logging.basicConfig(level=logging.ERROR, format="%(asctime)s - %(levelname)s - %(message)s")

def get_tags_from_bashbrew(json_file: str, version: str) -> list:
    try:
        with open(json_file, 'r') as f:
            data = json.load(f)
            
        tags = []
        for entry in data["matrix"]["include"]:
            if entry["name"] == version or entry["name"] == f"{version}-alpine":
                tags.extend([
                    tag.replace("valkey-container:", "") 
                    for tag in entry["meta"]["entries"][0]["tags"]
                ])
        return tags
    except Exception as e:
        logging.error(f"Error getting tags from bashbrew: {e}")
        raise

def update_website_release(version: str, template_file: str, bashbrew_file: str, output_path: str) -> None:
    try:
        release_date = datetime.now().strftime("%Y-%m-%d")
        
        tags = get_tags_from_bashbrew(bashbrew_file, version)
        
        is_rc = "-rc" in version
        if is_rc:
            base_version = version.split("-rc")[0]
            base_version_dashed = base_version.replace(".", "-")
            file_path = f"{output_path}/v{base_version_dashed}.md"
        else:
            version_dashed = version.replace(".", "-")
            file_path = f"{output_path}/v{version_dashed}.md"

        with open(template_file, 'r') as f:
            template = f.read()

        if is_rc and os.path.exists(file_path):
            # Update existing file for RC
            with open(file_path, 'r') as f:
                content = f.read()
            
            # Update the fields
            content = (
                content
                .replace(f'title: "..."', f'title: "{version}"')
                .replace(f'date: ...', f'date: {release_date}')
                .replace(f'tag: "..."', f'tag: "{version}"')
            )
            
            # Update tags section
            tags_section = "\n".join(f"                - \"{tag}\"" for tag in tags)
            content = re.sub(
                r'tags:.*?packages:',
                f'tags:\n{tags_section}\n            packages:',
                content,
                flags=re.DOTALL
            )
            
            with open(file_path, 'w') as f:
                f.write(content)
        else:
            # Create new file using template
            tags_section = "\n".join(f"                - \"{tag}\"" for tag in tags)
            content = template.format(
                version=version,
                date=release_date,
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
        logging.error(f"An error occurred: {e}")
        sys.exit(1)
