import json
import sys
import re

def clean_tag(tag: str) -> str:
    return tag.replace("valkey-container:", "")

def format_tag_line(entry: dict) -> str:
    raw_tags = entry['meta']['entries'][0]['tags']
    
    formatted_tags = []
    for tag in raw_tags:
        clean = clean_tag(tag)
        formatted_tags.append(f'`{clean}`')
    
    tags = ', '.join(formatted_tags)
    directory = entry['meta']['entries'][0]['directory']
    
    return f"- [{tags}](https://github.com/valkey-io/valkey-container/blob/master/{directory}/Dockerfile)"

def update_docker_description(json_file: str, docker_description_file: str) -> None:
    with open(json_file) as f:
        data = json.load(f)

    with open(docker_description_file, 'r') as f:
        content = f.read()

    # Generate sections content
    official_lines = []
    for entry in data["matrix"]["include"]:
        if "rc" not in entry["name"] and "unstable" not in entry["name"]:
            line = format_tag_line(entry) + "\n"
            official_lines.append(line)
    official_releases = "".join(official_lines)

    rc_lines = []
    for entry in data["matrix"]["include"]:
        if "rc" in entry["name"]:
            line = format_tag_line(entry) + "\n"
            rc_lines.append(line)
    release_candidates = "".join(rc_lines)

    unstable_lines = []
    for entry in data["matrix"]["include"]:
        if "unstable" in entry["name"]:
            line = format_tag_line(entry) + "\n"
            unstable_lines.append(line)
    latest_unstable = "".join(unstable_lines)

    # Replace sections with more flexible whitespace matching
    pattern = r'(## Official releases\s+).*?(##|$)'
    content = re.sub(
        pattern,
        f'\\1{official_releases}\\2',
        content,
        flags=re.DOTALL
    )
    
    pattern = r'(## Release candidates\s+).*?(##|$)'
    content = re.sub(
        pattern,
        f'\\1{release_candidates}\\2',
        content,
        flags=re.DOTALL
    )
    
    pattern = r'(## Latest unstable\s+).*?(##|$)'
    content = re.sub(
        pattern,
        f'\\1{latest_unstable}\\2',
        content,
        flags=re.DOTALL
    )

    with open(docker_description_file, 'w') as f:
        f.write(content)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(1)
    
    update_docker_description(sys.argv[1], sys.argv[2])