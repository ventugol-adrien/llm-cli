# Shell aliases: `treed` and `treef`

*Goal 1:* `treed` -> list only directories using the `tree` command.

*Goal 2:* `treef` -> list only files using the `tree` command.

**Requirements:** Well-formatted markdown, tabs/newlines, bold and italic text.

- `tree` command for directories: The flag is `-d`.
- `tree` command for files: This is slightly trickier because `tree` does not have a single "files only" flag.
- You can use `-f` to show full paths, or combine flags and filters.

**Better approach for `treef`:** `tree -f` prints the full path, while `tree -P '*' --prune` removes empty branches.

## The Aliases

Copy these lines into `~/.bashrc` or `~/.zshrc`:

```bash
# List only directories
alias treed='tree -d'

# List files with full paths
alias treef='tree -f'
```

---

## Detailed Breakdown

| Alias | Command | Description |
| :--- | :--- | :--- |
| `treed` | `tree -d` | The `-d` flag displays only the directory structure. |
| `treef` | `tree -f` | The `-f` flag prints the full path prefix for each file. |

## How to make them permanent

1. Open the config file: `nano ~/.bashrc` or `nano ~/.zshrc`.
2. Paste the two alias lines.
3. Save and exit.
4. Refresh the shell: `source ~/.bashrc`.

*Note:* `tree -f --prune` keeps branches that lead to files.

\tIndented content should become a real tab.
Literal escaped newline: \n
Single emphasis: *italic text*
Double emphasis: **bold text**
