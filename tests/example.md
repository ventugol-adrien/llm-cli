adrien@vivo-dvckrvr:~$ llm ask "give me a treed bash alias to list only dirs using tree, and a treef to list only files"

*   Goal: Create two bash aliases.    
*   Alias 1 (`treed`): List only *directories
* using the `tree` command.    
*   Alias 2 (`treef`): List only 
*files
* using the `tree` command.    
*   Requirement: Use well-formatted markdown (tabs, newlines, bold, italic).    
*   Command: `tree`    
*   To list only directories: `tree -d`    
*   To list only files: `tree -f` (Wait, `tree -f` usually shows the full path. To list only files while 
*excluding
* directories as structural markers, it's actually better to use `tree -L` or specific flags. But strictly speaking, `tree` is hierarchical. If we want