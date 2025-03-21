import json
import sys
import re

def clean_tag(tag: str) -> str:
    if ":" in tag:
        return tag.split(":", 1)[1]
    return tag

def format_tag_line(entry: dict) -> str:
    raw_tags = entry['meta']['entries'][0]['tags']
    
    formatted_tags = []
    for tag in raw_tags:
        clean = clean_tag(tag)
        formatted_tags.append(f'`{clean}`')
    
    tags = ', '.join(formatted_tags)
    directory = entry['meta']['entries'][0]['directory']
    
    return f"- [{tags}](https://github.com/valkey-io/valkey-container/blob/master/{directory}/Dockerfile)"

def update_section(content: str, section_header: str, new_content: str) -> str:
    # Find the section
    section_start = content.find(section_header)
    if section_start == -1:
        return content
    
    search_start = section_start + len(section_header)
    
    next_section = content.find("\n## ", search_start)
    what_is_section = content.find('\nWhat is [Valkey](https://github.com/valkey-io/valkey)?', search_start)
    next_header = content.find("\n# ", search_start)
    
    # Find the next closest section
    section_end = float('inf')
    for pos in [next_section, what_is_section, next_header]:
        if pos != -1 and pos < section_end:
            section_end = pos
    
    if section_end == float('inf'):
        section_end = len(content)

    # Get the content until the section header
    section_content_start = content.find("\n", section_start) + 1
    
    # Replace only the content between current section and next section
    return (content[:section_content_start] + "\n" + new_content + "\n\n" + content[section_end:])

def update_docker_description(json_file: str, docker_description_file: str) -> None:
    with open(json_file) as f:
        data = json.load(f)

    with open(docker_description_file, 'r') as f:
        content = f.read()

    # Generate all the content for each section
    official_lines = []
    for entry in data["matrix"]["include"]:
        if "rc" not in entry["name"] and "unstable" not in entry["name"]:
            line = format_tag_line(entry)
            official_lines.append(line)
    official_releases = "\n".join(official_lines)

    rc_lines = []
    for entry in data["matrix"]["include"]:
        if "rc" in entry["name"]:
            line = format_tag_line(entry)
            rc_lines.append(line)
    release_candidates = "\n".join(rc_lines)

    unstable_lines = []
    for entry in data["matrix"]["include"]:
        if "unstable" in entry["name"]:
            line = format_tag_line(entry)
            unstable_lines.append(line)
    latest_unstable = "\n".join(unstable_lines)

    # Update each section separately
    content = update_section(content, "## Official releases", official_releases)
    content = update_section(content, "## Release candidates", release_candidates)
    content = update_section(content, "## Latest unstable", latest_unstable)

    with open(docker_description_file, 'w') as f:
        f.write(content)

if __name__ == "__main__":
    update_docker_description(sys.argv[1], sys.argv[2])