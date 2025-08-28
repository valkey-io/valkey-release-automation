import sys
import logging
import re
from typing import Dict, Tuple

logging.basicConfig(level=logging.ERROR, format="%(asctime)s - %(levelname)s - %(message)s")

def parse_version(version: str) -> Tuple[int, int]:
    parts = version.split('.')
    return int(parts[0]), int(parts[1])
    
def update_aliases_dict(new_version: str, aliases: Dict[str, str]) -> Dict[str, str]:
    # Never update aliases for RC versions
    if "-rc" in new_version:
        return aliases
        
    new_major, new_minor = parse_version(new_version)
    new_key = f"{new_major}.{new_minor}"
        
    # When we release a patch version
    if new_key in aliases:
        return aliases
        
    most_recent_version = max(aliases.keys(), key=parse_version)        
    curr_major, curr_minor = parse_version(most_recent_version)
        
    # When we release a minor version
    if new_major == curr_major and new_minor > curr_minor:            
        most_recent_value = aliases[most_recent_version]
        del aliases[most_recent_version]
        aliases[new_key] = most_recent_value
            
    elif new_major > curr_major:
        # When we release a new major version           
        if 'latest' in aliases[most_recent_version]:
            aliases[most_recent_version] = aliases[most_recent_version].replace(' latest', '').strip()
            
        aliases[new_key] = f"{new_major} latest"
            
    else:
        # When we backport versions
        print(f"Version {new_key} is not newer than the last version. No changes will be made")
        
    return aliases


def update_container_aliases(generate_stackbrew_library_file: str, new_version: str) -> None:
    with open(generate_stackbrew_library_file, 'r') as f:
        content = f.read()
        
    match = re.search(r'declare -A aliases=\(\s*(.*?)\s*\)', content, re.DOTALL)
    alias_content = match.group(1)
    current_aliases = {}
        
    for individual_alias in re.finditer(r'\[([^\]]+)\]=\'([^\']*)\'', alias_content):
        current_key = individual_alias.group(1)
        value = individual_alias.group(2)
        current_aliases[current_key] = value

    updated_aliases = update_aliases_dict(new_version, current_aliases)
                
    alias_lines = [
        f"\t[{key}]='{updated_aliases[key]}'" for key in sorted(updated_aliases.keys(), key=parse_version)
    ]
    new_aliases_block = "declare -A aliases=(\n" + "\n".join(alias_lines) + "\n)"

    # Replace the old aliases declaration
    aliases_pattern = r'declare -A aliases=\(\s*.*?\s*\)'
    new_content = re.sub(aliases_pattern, new_aliases_block, content, flags=re.DOTALL)

    with open(generate_stackbrew_library_file, 'w') as f:
        f.write(new_content) 

if __name__ == "__main__":
    if len(sys.argv) != 3:
        logging.error("Invalid number of arguments.")
        logging.error("Usage: python update_container_aliases.py <script_path> <version>")
        sys.exit(1)
    
    update_container_aliases(sys.argv[1], sys.argv[2])